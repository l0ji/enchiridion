;;;; broker.cl --- The supervisor side of the privilege boundary.
;;;;
;;;; The supervisor holds the secrets and the model. Agent-authored code runs
;;;; in a child process as uid 1000. The only thing that crosses the line is a
;;;; length prefixed JSON request and its response. The supervisor never loads
;;;; the child's code and never sends a secret in a request.
;;;;
;;;; The socket path is the whole configuration. PRODUCTION spawns
;;;; broker-exec.cl; tests pass :IN-PROCESS T so the framing and dispatch can
;;;; be proved without a container. The in-process mode is not the security
;;;; boundary and is not used by the daemon.

(in-package #:enchiridion.tools.broker)

(defstruct (broker (:constructor %make-broker))
  (socket #p"/run/enchiridion/broker.sock" :type pathname)
  (uid 1000 :type (integer 0 *))
  (timeout 30 :type real)
  (stream nil :type t)
  (server nil :type t)
  (server-thread nil :type t)
  (child nil :type t)
  (running-p nil :type boolean))

(defun make-broker (&key (socket #p"/run/enchiridion/broker.sock")
                           (uid 1000) (timeout 30))
  "Return a BROKER descriptor. Nothing starts until BROKER-START."
  (%make-broker :socket (pathname socket) :uid uid :timeout timeout))

(defun json-object (&rest pairs)
  "Return PAIRS as the JSON object shape JZON writes."
  (let ((table (make-hash-table :test #'equal)))
    (loop for (key value) on pairs by #'cddr
          do (setf (gethash (string-downcase (string key)) table) value))
    table))

(declaim (ftype (function (stream string) null) write-frame))

(defun write-frame (stream text)
  "Write TEXT as a four byte big endian length and UTF-8 bytes."
  (let* ((octets (enchiridion.compat:encode-utf8 text))
         (length (length octets)))
    (write-byte (ldb (byte 8 24) length) stream)
    (write-byte (ldb (byte 8 16) length) stream)
    (write-byte (ldb (byte 8 8) length) stream)
    (write-byte (ldb (byte 8 0) length) stream)
    (write-sequence octets stream)
    (finish-output stream)
    nil))

(declaim (ftype (function (stream) (or null string)) read-frame))

(defun read-frame (stream)
  "Read one frame, or return NIL at a clean end of stream."
  (let ((header (make-array 4 :element-type '(unsigned-byte 8))))
    (let ((read (read-sequence header stream)))
      (cond
        ((zerop read) nil)
        ((< read 4) (error 'enchiridion.errors:transport-error
                           :detail "The broker closed during a frame header."))
        (t
         (let ((length (logior (ash (aref header 0) 24)
                               (ash (aref header 1) 16)
                               (ash (aref header 2) 8)
                               (aref header 3))))
           (when (> length (* 16 1024 1024))
             (error 'enchiridion.errors:transport-error
                    :detail "The broker frame is larger than 16 MiB."))
           (let ((octets (make-array length :element-type '(unsigned-byte 8))))
             (unless (= length (read-sequence octets stream))
               (error 'enchiridion.errors:transport-error
                      :detail "The broker closed during a frame body."))
             (enchiridion.compat:decode-utf8 octets))))))))

(defun scrub-value (value)
  "Return VALUE with every string scrubbed, including strings inside a hash
table. A tool result is the last place a secret can enter a transcript, so the
broker scrubs before it writes the response."
  (typecase value
    (string (enchiridion.llm.secrets:scrub value))
    (hash-table
     (let ((copy (make-hash-table :test #'equal)))
       (maphash (lambda (key item)
                  (setf (gethash key copy) (scrub-value item)))
                value)
       copy))
    (cons (enchiridion.llm.secrets:scrub-tree value))
    (vector (enchiridion.llm.secrets:scrub-tree value))
    (t value)))

(defun error-response (condition)
  (json-object "ok" nil
               "error" (enchiridion.llm.secrets:scrub
                        (princ-to-string condition))
               "detail" (enchiridion.llm.secrets:scrub
                         (or (enchiridion.errors:error-detail condition) ""))))

(defun serve-connection (stream)
  "Answer requests on STREAM until the peer closes it.

One connection carries every call the supervisor makes. Closing it after one
response would make each BROKER-CALL pay a reconnect and would turn a normal
second call into a race with the accept loop."
  (loop for frame = (read-frame stream)
        while frame
        do (let* ((request (com.inuoe.jzon:parse frame))
                  (op (gethash "op" request))
                  (arguments (gethash "arguments" request)))
             (handler-case
                 (let ((result (if (and (stringp op) (string= op "ping"))
                                   "ok"
                                   (enchiridion.tools:dispatch op arguments))))
                   (write-frame stream
                                (com.inuoe.jzon:stringify
                                 (json-object "ok" t "result" (scrub-value result)))))
               (enchiridion.errors:enchiridion-error (condition)
                 (write-frame stream
                              (com.inuoe.jzon:stringify
                               (error-response condition))))
               (error (condition)
                 (write-frame stream
                              (com.inuoe.jzon:stringify
                               (json-object "ok" nil
                                            "error" (enchiridion.llm.secrets:scrub
                                                     (princ-to-string condition))
                                            "detail" ""))))))))

(defun accept-loop (server)
  "Accept connections until SERVER is closed."
  (handler-case
      (loop
        (let ((connection (usocket:socket-accept server
                                                 :element-type '(unsigned-byte 8))))
          (unwind-protect
               (serve-connection (usocket:socket-stream connection))
            (usocket:socket-close connection))))
    (error () nil)))

(defun serve-broker (socket &key (uid nil))
  "Bind SOCKET and serve requests. This is the child entry point.

When UID is non-NIL and this process is root, drop to it before the socket is
bound and before any agent file is loaded by the caller. A non-root test process
stays where it is, because dropping to a uid it does not own would only fail."
  (when (and uid (plusp uid) (zerop (enchiridion.compat:process-uid)))
    (enchiridion.compat:set-process-uid uid))
  (let ((server (usocket:socket-listen socket nil :backlog 5 :reuse-address t)))
    (unwind-protect
         (accept-loop server)
      (usocket:socket-close server))))

(defun broker-exec-path ()
  "Return the child script path beside the installed source."
  (merge-pathnames "src/broker-exec.cl"
                   (asdf:system-source-directory "enchiridion")))

(defun child-environment ()
  "Return the minimal environment the child gets. Nothing is inherited: a
secret in the supervisor's environment must not be one of these strings."
  (let ((entries (list (format nil "PATH=~A" "/usr/local/bin:/usr/bin:/bin")
                       (format nil "HOME=~A" (or (uiop:getenv "ENCHIRIDION_HOME") "/tmp")))))
    (dolist (name '("SBCL_HOME" "CL_SOURCE_REGISTRY" "ENCHIRIDION_HOME"
                    "ENCHIRIDION_SOURCE" "ENCHIRIDION_SBCL"
                    "LD_LIBRARY_PATH" "XDG_CACHE_HOME" "XDG_CONFIG_HOME"))
      (let ((value (uiop:getenv name)))
        (when value
          (push (format nil "~A=~A" name value) entries))))
    entries))

(defun wait-for-connection (broker)
  "Try to connect to BROKER's socket until it answers or the timeout expires."
  (let ((deadline (+ (get-internal-real-time)
                     (* (broker-timeout broker) internal-time-units-per-second))))
    (loop
      (handler-case
          (return (usocket:socket-connect (broker-socket broker) nil
                                          :element-type '(unsigned-byte 8)
                                          :nodelay nil))
        (error ()
          (when (> (get-internal-real-time) deadline)
            (error 'enchiridion.errors:transport-error
                   :detail "The broker did not start before the timeout."))
          (sleep 0.05))))))

(defun start-local (broker)
  (ensure-directories-exist (broker-socket broker))
  (uiop:delete-file-if-exists (broker-socket broker))
  (let ((server (usocket:socket-listen (broker-socket broker) nil
                                       :backlog 5 :reuse-address t)))
    (setf (broker-server broker) server)
    (setf (broker-server-thread broker)
          (bordeaux-threads:make-thread
           (lambda () (accept-loop server))
           :name "enchiridion broker test server"))
    (let ((connection (wait-for-connection broker)))
      (setf (broker-stream broker) (usocket:socket-stream connection))
      (setf (broker-running-p broker) t))
    broker))

(defun start-child (broker)
  (ensure-directories-exist (broker-socket broker))
  (uiop:delete-file-if-exists (broker-socket broker))
  (let* ((program (or (uiop:getenv "ENCHIRIDION_SBCL") "sbcl"))
         (arguments (list "--script" (namestring (broker-exec-path))
                          "--socket" (namestring (broker-socket broker))
                          "--uid" (princ-to-string (broker-uid broker))))
         (child (enchiridion.compat:run-program program arguments
                                                :wait nil
                                                :environment (child-environment))))
    (setf (broker-child broker) child)
    (handler-case
        (let ((connection (wait-for-connection broker)))
          (setf (broker-stream broker) (usocket:socket-stream connection))
          (setf (broker-running-p broker) t)
          broker)
      (error (condition)
        (ignore-errors (sb-ext:process-kill child :sigterm))
        (error condition)))))

(defun broker-start (broker &key (in-process nil))
  "Start BROKER. IN-PROCESS is for tests only; production starts the child.
Return BROKER."
  (when (broker-running-p broker)
    (return-from broker-start broker))
  (if in-process
      (start-local broker)
      (start-child broker)))

(defun broker-stop (broker)
  "Close BROKER, stop its thread or child, and remove the socket."
  (when (broker-stream broker)
    (ignore-errors (close (broker-stream broker)))
    (setf (broker-stream broker) nil))
  (when (broker-server broker)
    (ignore-errors (usocket:socket-close (broker-server broker)))
    (setf (broker-server broker) nil))
  (when (broker-server-thread broker)
    (ignore-errors (bordeaux-threads:destroy-thread (broker-server-thread broker)))
    (setf (broker-server-thread broker) nil))
  (when (broker-child broker)
    (ignore-errors (sb-ext:process-kill (broker-child broker) :sigterm))
    (setf (broker-child broker) nil))
  (ignore-errors (delete-file (broker-socket broker)))
  (setf (broker-running-p broker) nil)
  broker)

(defun arguments-object (arguments)
  "Return ARGUMENTS as a hash table so JZON writes an object, not an array.
A plist reaches BROKER-CALL from Lisp callers; a hash table reaches it from a
parsed model call. Both become one object on the wire."
  (cond
    ((null arguments) (make-hash-table :test #'equal))
    ((hash-table-p arguments) arguments)
    ((listp arguments)
     (let ((table (make-hash-table :test #'equal)))
       (loop for (key value) on arguments by #'cddr
             do (setf (gethash (string-downcase (string key)) table) value))
       table))
    (t arguments)))

(defun broker-call (broker operation arguments &key timeout)
  "Send one operation to BROKER and return its result.

TIMEOUT is accepted for the protocol but not yet enforced on the socket read;
the caller can set the process deadline around it. The frame itself is capped
at 16 MiB by READ-FRAME."
  (declare (ignore timeout))
  (unless (broker-running-p broker)
    (error 'enchiridion.errors:configuration-error
           :key :broker
           :detail "The broker is not running."))
  (let ((stream (broker-stream broker)))
    (write-frame stream
                 (com.inuoe.jzon:stringify
                  (json-object "op" (string operation)
                               "arguments" (arguments-object arguments))))
    (let ((response (read-frame stream)))
      (unless response
        (error 'enchiridion.errors:transport-error
               :detail "The broker closed without a response."))
      (let ((data (com.inuoe.jzon:parse response)))
        (if (gethash "ok" data)
            (gethash "result" data)
            (error 'enchiridion.errors:tool-error
                   :tool operation
                   :detail (or (gethash "detail" data)
                               (gethash "error" data)
                               "The broker reported an error.")))))))

(defun broker-health (broker)
  "Return T when BROKER answers a ping."
  (handler-case
      (string= "ok" (broker-call broker "ping" nil))
    (error () nil)))
