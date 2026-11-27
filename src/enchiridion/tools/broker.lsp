;;;; broker.lsp --- Supervisor/child IPC over a length-prefixed JSON Unix socket.
;;;;
;;;; Production spawns broker-exec.lsp as an unprivileged child; tests use :IN-PROCESS T.

(in-package #:enchiridion.tools.broker)

;; Forward declaration for helpers defined before BROKER-CALL.
(declaim (ftype function broker-call))

(defparameter *load-generation-function* nil
  "Child loader hook of (directory generation) -> (values ok-p report digests live-generation).
Set by broker-exec to avoid a load-order cycle with the plugin module.
The supervisor's expected source digest is passed via *LOAD-SOURCE-DIGESTS*.")

(defparameter *load-source-digests* nil
  "Dynamically bound by LOAD-GENERATION-RESPONSE to the supervisor's expected source digest,
preserving the two-argument signature of *LOAD-GENERATION-FUNCTION*.")

(defvar *start-progress-function* nil
  "Optional (elapsed-seconds) callback invoked roughly once per second by WAIT-FOR-CONNECTION.")

(defstruct (broker (:constructor %make-broker))
  (socket #p"/run/enchiridion/broker.sock" :type pathname)
  (uid 1000 :type (integer 0 *))
  (gid 1000 :type (integer 0 *))
  (timeout 30 :type real)
  (log nil :type (or null pathname))
  (stream nil :type t)
  (server nil :type t)
  (server-thread nil :type t)
  (child nil :type t)
  (running-p nil :type boolean)
  (broken-p nil :type boolean)
  (call-timeout 660 :type (or null real))
  (last-load nil :type list)
  (call-lock nil :type t))

(defparameter +broker-call-timeout+ 660
  "Default per-call timeout in seconds before restarting a hung child; exceeds the shell tool ceiling.")

(defun make-broker (&key (socket #p"/run/enchiridion/broker.sock")
                           (uid 1000) (gid 1000) (timeout 30) (log nil)
                           (call-timeout +broker-call-timeout+))
  "Return a BROKER descriptor without starting it.
TIMEOUT is startup timeout in seconds; CALL-TIMEOUT is per-call timeout (or NIL); LOG redirects child stdout/stderr.
Uses a lock to serialize request/response framing across concurrent callers on the single socket."
  (%make-broker :socket (pathname socket) :uid uid :gid gid :timeout timeout
                :log (and log (pathname log))
                :call-timeout call-timeout
                :call-lock (bordeaux-threads:make-lock "enchiridion broker call")))

(defun json-object (&rest pairs)
  "Return PAIRS as the JSON object shape JZON writes."
  (let ((table (make-hash-table :test #'equal)))
    (loop for (key value) on pairs by #'cddr
          do (setf (gethash (string-downcase (string key)) table) value))
    table))

(defparameter +frame-limit+ (* 16 1024 1024)
  "Maximum frame payload size in bytes enforced symmetrically on reads and writes.")

(declaim (ftype (function (stream string) null) write-frame))

(defun write-frame (stream text)
  "Write TEXT as a 4-byte big-endian length prefix followed by UTF-8 bytes.
Signals TRANSPORT-ERROR before writing any bytes if the payload exceeds +FRAME-LIMIT+."
  (let* ((octets (enchiridion.compat:encode-utf8 text))
         (length (length octets)))
    (when (> length +frame-limit+)
      (error 'enchiridion.errors:transport-error
             :detail (format nil "A frame of ~D bytes is larger than the ~D byte limit."
                             length +frame-limit+)))
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
           (when (> length +frame-limit+)
             (error 'enchiridion.errors:transport-error
                    :detail (format nil "The broker frame is larger than ~D MiB."
                                    (floor +frame-limit+ (* 1024 1024)))))
           (let ((octets (make-array length :element-type '(unsigned-byte 8))))
             (unless (= length (read-sequence octets stream))
               (error 'enchiridion.errors:transport-error
                      :detail "The broker closed during a frame body."))
             (enchiridion.compat:decode-utf8 octets))))))))

(defun scrub-value (value)
  "Return VALUE with secret text and credential fields redacted."
  (enchiridion.llm.secrets:scrub-tree value))

(defun error-response (condition)
  ;; Scrub structured details as a tree so credential fields in plists are redacted.
  (json-object "ok" nil
               "error" (enchiridion.llm.secrets:scrub
                        (princ-to-string condition))
               "detail" (let ((detail (enchiridion.errors:error-detail condition)))
                          (cond ((null detail) "")
                                ((stringp detail)
                                 (enchiridion.llm.secrets:scrub detail))
                                (t (enchiridion.llm.secrets:scrub-tree detail))))))

(declaim (ftype (function (t t &optional t) t) request-value))

(defun request-value (request name &optional default)
  "Return lowercase key NAME from parsed JSON hash table REQUEST, or DEFAULT."
  (let ((value (and (hash-table-p request) (gethash name request))))
    (or value default)))

(declaim (ftype (function (t) t) load-generation-response))

(defun load-generation-response (arguments)
  "Handle a load-generation request in the child via *LOAD-GENERATION-FUNCTION*.
Binds *LOAD-SOURCE-DIGESTS* from the request and returns a JSON object with ok, report,
digests, and generation so the supervisor can verify the published snapshot."
  (let ((function *load-generation-function*)
        (directory (request-value arguments "directory"))
        (generation (request-value arguments "generation"))
        (digests (request-value arguments "digests")))
    (unless function
      (error 'enchiridion.errors:configuration-error
             :key :plugin
             :detail "This process has no plugin loader attached."))
    (unless (and (stringp directory) (plusp (length directory)))
      (error 'enchiridion.errors:tool-error
             :tool "load-generation"
             :detail "The request has no directory to load."))
    (unless (and (integerp generation) (plusp generation))
      (error 'enchiridion.errors:tool-error
             :tool "load-generation"
             :detail "The request has no usable generation number."))
    (multiple-value-bind (ok-p report source-digests live-generation)
        (let ((*load-source-digests* digests))
          (funcall function (pathname directory) generation))
      (json-object "ok" ok-p
                   "report" report
                   "digests" source-digests
                   "generation" live-generation))))

(defun serve-connection (stream)
  "Serve length-prefixed JSON requests on persistent STREAM until EOF."
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
  "Accept and serve connections until SERVER is closed.
Per-connection errors are swallowed so an interrupted client does not terminate the loop."
  (loop
    (let ((connection (handler-case
                          (usocket:socket-accept server
                                                 :element-type '(unsigned-byte 8))
                        (error () (return nil)))))
      (unwind-protect
           (handler-case (serve-connection (usocket:socket-stream connection))
             (error (condition)
               (enchiridion.log:log-warn :broker "child connection closed with error: ~A"
                                         condition)
               nil))
        (ignore-errors (usocket:socket-close connection))))))

(defun serve-broker (socket &key (uid nil) (gid nil))
  "Child entry point: drop root privileges (clear supplementary groups, setgid, then setuid)
when running as root with a positive UID, then bind SOCKET and run ACCEPT-LOOP.
Non-root processes skip privilege dropping."
  (when (and uid (plusp uid) (zerop (enchiridion.compat:process-uid)))
    (enchiridion.compat:clear-supplementary-groups)
    (when (and gid (plusp gid))
      (enchiridion.compat:set-process-gid gid))
    (enchiridion.compat:set-process-uid uid)
    (enchiridion.log:log-info :broker "dropped privileges to uid=~D gid=~D" uid (or gid 0)))
  (let ((server (usocket:socket-listen socket nil :backlog 5 :reuse-address t)))
    (enchiridion.log:log-info :broker "listening on ~A" socket)
    (unwind-protect
         (accept-loop server)
      (usocket:socket-close server))))

(defun broker-exec-path ()
  "Return the child script path beside the installed source."
  (merge-pathnames "src/broker-exec.lsp"
                   (asdf:system-source-directory "enchiridion")))

(defun child-environment ()
  "Return the allowlisted environment for child processes so supervisor secrets are not inherited."
  (let ((entries (list (format nil "PATH=~A" "/usr/local/bin:/usr/bin:/bin")
                       (format nil "HOME=~A" (or (uiop:getenv "ENCHIRIDION_HOME") "/tmp")))))
    ;; Pass ASDF_OUTPUT_TRANSLATIONS so the child reuses supervisor fasls instead of recompiling.
    (dolist (name '("SBCL_HOME" "CL_SOURCE_REGISTRY" "ASDF_OUTPUT_TRANSLATIONS"
                    "ENCHIRIDION_HOME"
                    "ENCHIRIDION_SOURCE" "ENCHIRIDION_SBCL" "ENCHIRIDION_GIT"
                    "ENCHIRIDION_LOG_LEVEL"
                    "LD_LIBRARY_PATH" "XDG_CACHE_HOME" "XDG_CONFIG_HOME"))
      (let ((value (uiop:getenv name)))
        (when value
          (push (format nil "~A=~A" name value) entries))))
    entries))

(declaim (ftype (function (pathname &key (:uid t) (:gid t) (:timeout t)
                                       (:digests t)) t)
                broker-verify-plugin))

(defun broker-verify-plugin (directory &key (uid 1000) (gid 1000) (timeout 120)
                                          (digests nil))
  "Verify DIRECTORY in an isolated one-shot child as UID/GID; return (values ok-p output).
Uses a separate process with CHILD-ENVIRONMENT so compiler failures cannot crash the live broker.
If DIGESTS is supplied, the child refuses a tree whose digest no longer matches."
  (let ((program (or (uiop:getenv "ENCHIRIDION_SBCL")
                      (enchiridion.compat:lisp-runtime-path)))
        (arguments (append (list "--script" (namestring (broker-exec-path))
                                 "--verify-plugin"
                                 (namestring (uiop:ensure-directory-pathname directory))
                                 "--uid" (princ-to-string uid)
                                 "--gid" (princ-to-string gid))
                           (when digests (list "--digests" digests)))))
    (multiple-value-bind (output status)
        (enchiridion.compat:run-program-capture program arguments
                                                :timeout timeout
                                                :environment (child-environment))
      (values (eql 0 status) output))))

(declaim (ftype (function (broker t &key (:generation integer) (:digests t)) t)
                broker-load-generation))

(defun broker-load-generation (broker directory &key generation (digests nil))
  "Request that BROKER's child load GENERATION from DIRECTORY, returning the reply hash table
(ok, report, digests, generation). If DIGESTS is given, the child verifies the tree matches."
  (let* ((arguments (list :directory (namestring
                                      (uiop:ensure-directory-pathname directory))
                          :generation generation))
         (request (if digests (append arguments (list :digests digests)) arguments))
         (reply (broker-call broker "load-generation" request)))
    ;; Cache directory/generation for replay after a child restart; omit digests so
    ;; later edits do not block reloading the live generation.
    (when (and (hash-table-p reply) (gethash "ok" reply))
      (setf (broker-last-load broker) arguments))
    reply))

(defun log-tail (broker &optional (lines 20))
  "Return the last LINES lines of BROKER's log, or NIL when there are none."
  (let ((log (broker-log broker)))
    (when (and log (probe-file log))
      (let ((text (ignore-errors (uiop:read-file-lines log))))
        (when text
          (format nil "~{~A~^~%~}" (last text lines)))))))

(defun wait-for-connection (broker &optional child)
  "Try to connect to BROKER's socket until it answers or the timeout expires.
When CHILD is given and exits first, stop at once: a dead child never binds."
  (let* ((start (get-internal-real-time))
         (deadline (+ start (* (broker-timeout broker)
                               internal-time-units-per-second)))
         (reported 0))
    (loop
      (handler-case
          (return (usocket:socket-connect (broker-socket broker) nil
                                          :element-type '(unsigned-byte 8)
                                          :nodelay nil))
        (error ()
          (let ((code (and child (enchiridion.compat:process-exit-code child))))
            (when code
              (error 'enchiridion.errors:transport-error
                     :detail (format nil "The broker exited with status ~A before it started.~@[~%~A~]"
                                     code (log-tail broker)))))
          (let ((now (get-internal-real-time)))
            (when (> now deadline)
              (error 'enchiridion.errors:transport-error
                     :detail (format nil "The broker did not start before the timeout.~@[~%~A~]"
                                     (log-tail broker))))
            (let ((elapsed (floor (- now start) internal-time-units-per-second)))
              (when (and *start-progress-function* (> elapsed reported))
                (setf reported elapsed)
                (funcall *start-progress-function* elapsed))))
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

(defparameter +child-stop-grace-seconds+ 0.5
  "Grace period in seconds between SIGTERM and SIGKILL when stopping a child.")

(declaim (ftype (function (t &key (:grace real)) t) stop-child))

(defun stop-child (child &key (grace +child-stop-grace-seconds+))
  "Terminate CHILD and its descendant tree (SIGTERM, grace wait, then SIGKILL) and reap it.
Descendants are enumerated before signalling so reparenting cannot hide them, and signalled
individually because tool subprocesses lead their own process groups."
  (let ((descendants (enchiridion.compat:process-descendants child)))
    (ignore-errors (enchiridion.compat:process-kill child :sigterm :process-group))
    (dolist (pid descendants)
      (enchiridion.compat:signal-process pid :sigterm))
    (loop repeat (ceiling (* grace 100))
          until (enchiridion.compat:process-exit-code child)
          do (sleep 0.01))
    (dolist (pid descendants)
      (enchiridion.compat:signal-process pid :sigkill))
    (ignore-errors (enchiridion.compat:process-kill child :sigkill :process-group))
    (enchiridion.compat:process-reap child)
    child))

(defun start-child (broker)
  (ensure-directories-exist (broker-socket broker))
  (uiop:delete-file-if-exists (broker-socket broker))
  (when (broker-log broker)
    (ensure-directories-exist (broker-log broker)))
  (let* ((program (or (uiop:getenv "ENCHIRIDION_SBCL")
                      (enchiridion.compat:lisp-runtime-path)))
         (arguments (list "--script" (namestring (broker-exec-path))
                          "--socket" (namestring (broker-socket broker))
                          "--uid" (princ-to-string (broker-uid broker))
                          "--gid" (princ-to-string (broker-gid broker))))
         ;; Redirect to file (or NIL), not a pipe, so an unread pipe cannot block startup.
         (child (enchiridion.compat:run-program program arguments
                                                :output (broker-log broker)
                                                :if-output-exists :supersede
                                                :error-output :output
                                                :wait nil
                                                :environment (child-environment))))
    (setf (broker-child broker) child)
    (handler-case
        (let ((connection (wait-for-connection broker child)))
          (setf (broker-stream broker) (usocket:socket-stream connection)
                (broker-running-p broker) t
                ;; Clear broken flag on fresh connection so the next call does not trigger recovery.
                (broker-broken-p broker) nil)
          (enchiridion.log:log-info :broker "child started (pid ~A) on ~A"
                                    (enchiridion.compat:process-pid child)
                                    (broker-socket broker))
          broker)
      (error (condition)
        ;; Reap the failed child and any helpers so SBCL does not retain the process object.
        (stop-child child)
        (when (eq child (broker-child broker))
          (setf (broker-child broker) nil))
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
  "Close BROKER, stop its thread or child, and remove the socket.
Clears BROKER-RUNNING-P first so an interrupted in-flight call will not respawn a child."
  (setf (broker-running-p broker) nil)
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
    ;; Tools can run in separate process groups
    (stop-child (broker-child broker))
    (setf (broker-child broker) nil))
  (ignore-errors (delete-file (broker-socket broker)))
  (setf (broker-running-p broker) nil
        (broker-broken-p broker) nil)
  broker)

(defun arguments-object (arguments)
  "Normalize ARGUMENTS (NIL, hash table, or plist) into a hash table with lowercase string keys."
  (cond
    ((null arguments) (make-hash-table :test #'equal))
    ((hash-table-p arguments) arguments)
    ((listp arguments)
     (let ((table (make-hash-table :test #'equal)))
       (loop for (key value) on arguments by #'cddr
             do (setf (gethash (string-downcase (string key)) table) value))
       table))
    (t arguments)))

(defun mark-broker-broken (broker)
  "Abort and discard BROKER's stream and mark it broken so the next call reconnects
instead of reading a stale or partial frame."
  (let ((stream (shiftf (broker-stream broker) nil)))
    (when stream
      (ignore-errors (close stream :abort t))))
  (unless (broker-broken-p broker)
    (enchiridion.log:log-warn :broker "marking broker stream broken (~A)" (broker-socket broker)))
  (setf (broker-broken-p broker) t)
  broker)

(defun reconnect-broker (broker)
  "Open a fresh connection to BROKER's socket and clear BROKER-BROKEN-P.
Blocks in the listen backlog until the child finishes any abandoned call; signals on child exit."
  (let ((connection (wait-for-connection broker (broker-child broker))))
    (setf (broker-stream broker) (usocket:socket-stream connection)
          (broker-broken-p broker) nil)
    broker))

(defun exchange (broker operation arguments limit)
  "Send one framed request on BROKER and return the parsed reply hash table, or :TIMEOUT.
Caller must hold BROKER-CALL-LOCK. Marks the broker broken on any non-local exit or timeout
before the full reply is read."
  (let ((request (com.inuoe.jzon:stringify
                  (json-object "op" (string operation)
                               "arguments" (arguments-object arguments))))
        (response nil)
        (exchanged nil)
        (outcome nil))
    (unwind-protect
         (setf outcome
               (enchiridion.compat:with-deadline (limit :on-timeout :timeout)
                 (let ((stream (broker-stream broker)))
                   (write-frame stream request)
                   (setf response (read-frame stream))
                   (when response
                     (setf exchanged t))
                   :done)))
      (unless exchanged
        (mark-broker-broken broker)))
    (cond
      (exchanged (com.inuoe.jzon:parse response))
      ((eq outcome :timeout) :timeout)
      (t (error 'enchiridion.errors:transport-error
                :detail "The broker closed without a response.")))))

(defun restart-child (broker)
  "Kill and replace BROKER's child process, then replay BROKER-LAST-LOAD if set.
Signals TRANSPORT-ERROR if BROKER-RUNNING-P is NIL so a stopping broker never respawns a child.
Logs a warning to *ERROR-OUTPUT* if reloading the last generation fails."
  (unless (broker-running-p broker)
    (error 'enchiridion.errors:transport-error
           :detail "The broker is not running, so no child was started."))
  (enchiridion.log:log-warn :broker "restarting broker child on ~A" (broker-socket broker))
  (let ((child (broker-child broker)))
    (when child
      (stop-child child :grace 0.2)
      (when (eq child (broker-child broker))
        (setf (broker-child broker) nil))))
  (mark-broker-broken broker)
  (setf (broker-running-p broker) nil)
  (start-child broker)
  (let ((load (broker-last-load broker)))
    (when load
      (let ((reply (ignore-errors
                    (exchange broker "load-generation" load (broker-call-timeout broker)))))
        (unless (and (hash-table-p reply) (gethash "ok" reply))
          (format *error-output*
                  "~&enchiridion: the restarted broker did not reload generation ~A.~%"
                  (getf load :generation))
          (finish-output *error-output*)))))
  broker)

(defun recover-broker (broker)
  "Recover a broken BROKER: reconnect in-process brokers, restart exited children,
or reconnect to a live child and fall back to RESTART-CHILD if it does not accept."
  (unless (broker-running-p broker)
    (error 'enchiridion.errors:transport-error
           :detail "The broker is not running, so there was nothing to recover."))
  (let ((child (broker-child broker)))
    (cond
      ((null child) (reconnect-broker broker))
      ((enchiridion.compat:process-exit-code child) (restart-child broker))
      (t (handler-case (reconnect-broker broker)
           (enchiridion.errors:transport-error ()
             (restart-child broker)))))))

(defun broker-call (broker operation arguments &key timeout)
  "Send OPERATION with ARGUMENTS to BROKER under BROKER-CALL-LOCK and return the result.
Defaults TIMEOUT to BROKER-CALL-TIMEOUT; on timeout, restarts the child (if any) and signals
TRANSPORT-ERROR. Signals TOOL-ERROR when the reply reports an error."
  (unless (broker-running-p broker)
    (error 'enchiridion.errors:configuration-error
           :key :broker
           :detail "The broker is not running."))
  (let ((lock (broker-call-lock broker))
        (limit (or timeout (broker-call-timeout broker))))
    (when lock
      (bordeaux-threads:acquire-lock lock))
    (unwind-protect
         (progn
           (when (broker-broken-p broker)
             (recover-broker broker))
           (let ((data (exchange broker operation arguments limit)))
             (when (eq data :timeout)
               (enchiridion.log:log-warn :broker "tool ~A timed out after ~As" operation limit)
               ;; Only child-backed brokers can restart; in-process test brokers reconnect on next call.
               (let ((restarted (and (broker-child broker)
                                     (handler-case (restart-child broker)
                                       (error (condition)
                                         (enchiridion.log:log-error :broker "child restart after timeout failed: ~A"
                                                                    condition)
                                         nil)))))
                 (error 'enchiridion.errors:transport-error
                        :detail (if restarted
                                    (format nil "The tool ~A did not answer within ~A seconds, so the broker was restarted."
                                            operation limit)
                                    (format nil "The tool ~A did not answer within ~A seconds."
                                            operation limit)))))
             (if (gethash "ok" data)
                 (gethash "result" data)
                 (error 'enchiridion.errors:tool-error
                        :tool operation
                        :detail (or (gethash "detail" data)
                                    (gethash "error" data)
                                    "The broker reported an error.")))))
      (when lock
        (bordeaux-threads:release-lock lock)))))

(defun broker-health (broker)
  "Return T when BROKER answers a ping."
  (handler-case
      (string= "ok" (broker-call broker "ping" nil))
    (error () nil)))
