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

;; BROKER-CALL is defined after the helpers that use it, and a forward
;; reference inside one file needs a declaration or the compiler warns, which
;; this tree makes fatal. The declaration is a bare FUNCTION, and it is the
;; only proclamation for that name anywhere.
(declaim (ftype function broker-call))

;; The child's loader hook. The broker loads before the plugin module, because
;; the plugin module registers the tools the broker dispatches, so a direct
;; call from here would be a cycle. The child sets this to the plugin loader;
;; a broker with no hook answers the op with a clear error instead of loading
;; something in the wrong process.
(defparameter *load-generation-function* nil
  "A function of (directory generation) returning (values ok-p report), or NIL.
BROKER-EXEC sets it to the plugin loader. The supervisor never calls it: the
load happens in the child, as the agent user.")

(defstruct (broker (:constructor %make-broker))
  (socket #p"/run/enchiridion/broker.sock" :type pathname)
  (uid 1000 :type (integer 0 *))
  (timeout 30 :type real)
  (stream nil :type t)
  (server nil :type t)
  (server-thread nil :type t)
  (child nil :type t)
  (running-p nil :type boolean)
  (call-lock nil :type t))

(defun make-broker (&key (socket #p"/run/enchiridion/broker.sock")
                           (uid 1000) (timeout 30))
  "Return a BROKER descriptor. Nothing starts until BROKER-START.

The descriptor carries a lock because it carries one socket. A request is a
frame out and a frame back on the same stream, and two threads doing that at
once interleave the writes and one of them reads the other's answer. The REPL
and the reload poll could already collide; a second channel and the heartbeat
make it certain."
  (%make-broker :socket (pathname socket) :uid uid :timeout timeout
                :call-lock (bordeaux-threads:make-lock "enchiridion broker call")))

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

(declaim (ftype (function (t t &optional t) t) request-value))

(defun request-value (request name &optional default)
  "Return NAME from REQUEST, a parsed JSON object, or DEFAULT. JZON keys an
object by the string as it was written, so the two sides agree on lowercase."
  (let ((value (and (hash-table-p request) (gethash name request))))
    (or value default)))

(declaim (ftype (function (t) t) load-generation-response))

(defun load-generation-response (arguments)
  "Load a generation in this process from ARGUMENTS and return the report.

This runs in the child, as the agent user, and it is the only place agent code
is loaded for real. The supervisor asks for it over the socket, so the process
that holds the secrets never compiles what the agent wrote. The loader itself
arrives through *LOAD-GENERATION-FUNCTION*, which keeps this file free of the
plugin module it would otherwise have to load before."
  (let ((function *load-generation-function*)
        (directory (request-value arguments "directory"))
        (generation (request-value arguments "generation")))
    (unless function
      (error 'enchiridion.errors:configuration-error
             :key :plugin
             :detail "This process has no plugin loader attached."))
    (multiple-value-bind (ok-p report)
        (funcall function (pathname directory) generation)
      (json-object "ok" ok-p "report" report))))

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
                 (let ((result (cond ((and (stringp op) (string= op "ping")) "ok")
                                     ((and (stringp op) (string= op "load-generation"))
                                      (load-generation-response arguments))
                                     (t (enchiridion.tools:dispatch op arguments)))))
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

(declaim (ftype (function (pathname &key (:uid t) (:timeout t)) t)
                broker-verify-plugin))

(defun broker-verify-plugin (directory &key (uid 1000) (timeout 120))
  "Verify DIRECTORY in a one-shot child that runs as UID, and return two
values: whether the child exited zero, and the child's combined output.

A separate process, and not the serving child, because a file that kills the
compiler must not take the agent's running generation with it. The child gets
the same minimal environment as the broker, so nothing this process holds
crosses the boundary in either direction."
  (let ((program (or (uiop:getenv "ENCHIRIDION_SBCL") "sbcl"))
        (arguments (list "--script" (namestring (broker-exec-path))
                         "--verify-plugin"
                         (namestring (uiop:ensure-directory-pathname directory))
                         "--uid" (princ-to-string uid))))
    (multiple-value-bind (output status)
        (enchiridion.compat:run-program-capture program arguments
                                                :timeout timeout
                                                :environment (child-environment))
      (values (eql 0 status) output))))

(declaim (ftype (function (broker t &key (:generation integer)) t)
                broker-load-generation))

(defun broker-load-generation (broker directory &key generation)
  "Ask BROKER's child to load GENERATION from DIRECTORY and return the child's
report, a hash table with the keys ok, generation and report."
  (broker-call broker "load-generation"
               (list :directory (namestring
                                 (uiop:ensure-directory-pathname directory))
                     :generation generation)))

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
        (ignore-errors (enchiridion.compat:process-kill child :sigterm))
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
    (ignore-errors (enchiridion.compat:process-kill (broker-child broker) :sigterm))
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
at 16 MiB by READ-FRAME.

The whole call holds the broker's lock. A request is one frame written and one
frame read on one stream, so two callers at once would interleave their writes
and one would read the other's answer, which is a wrong answer and not a
visible error."
  (declare (ignore timeout))
  (unless (broker-running-p broker)
    (error 'enchiridion.errors:configuration-error
           :key :broker
           :detail "The broker is not running."))
  (let ((lock (broker-call-lock broker)))
    (when lock
      (bordeaux-threads:acquire-lock lock))
    (unwind-protect
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
                                      "The broker reported an error."))))))
      (when lock
        (bordeaux-threads:release-lock lock)))))

(defun broker-health (broker)
  "Return T when BROKER answers a ping."
  (handler-case
      (string= "ok" (broker-call broker "ping" nil))
    (error () nil)))
