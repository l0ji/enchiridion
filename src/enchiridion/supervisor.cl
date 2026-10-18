;;;; supervisor.cl --- The process that owns the channels and the run/ files.
;;;;
;;;; A shell command is an ordinary program invocation. It starts, it does one
;;;; thing, it prints, it exits. It is not a submode of a running agent. The
;;;; two cases that need a live process go through one small file the
;;;; supervisor polls once a second, and the answer comes back in a second
;;;; file the shell reads. That is the whole mechanism, and it is a file
;;;; rather than a socket so that tail and grep work on it.
;;;;
;;;; The supervisor never loads agent code. RELOAD-FUNCTION is the caller's
;;;; hook: a running daemon passes one that does the broker round trip, and a
;;;; test passes one that loads in process. This file stays free of the broker
;;;; so that neither the security boundary nor a test has to know about the
;;;; other.

(in-package #:enchiridion.supervisor)

(defparameter +status-fresh-seconds+ 10
  "How long a status file counts as live. The supervisor rewrites it every
tick, so a file this old was written by a process that has stopped.")

;;;; The two files.

(declaim (ftype (function (&optional t) pathname) control-file))

(defun control-file (&optional (run (enchiridion:run-directory)))
  "Return the path of run/enchiridion.control, one request per line."
  (merge-pathnames "enchiridion.control"
                   (uiop:ensure-directory-pathname run)))

(declaim (ftype (function (&optional t) pathname) status-file))

(defun status-file (&optional (run (enchiridion:run-directory)))
  "Return the path of run/enchiridion.status, rewritten on every change."
  (merge-pathnames "enchiridion.status"
                   (uiop:ensure-directory-pathname run)))

(declaim (ftype (function (pathname t) t) write-json-file))

(defun write-json-file (path table)
  "Write TABLE to PATH as JSON, then rename it into place.

The rename is what makes a reader safe: a reader either sees the old file or
the new one, never half of either. The status file is read by another process
while this one rewrites it, so half a file is a real state and not a theory."
  (let* ((directory (uiop:pathname-directory-pathname path))
         (temporary (merge-pathnames
                     (format nil "~A.new" (file-namestring path))
                     directory)))
    (ensure-directories-exist temporary)
    (with-open-file (stream temporary
                            :direction :output
                            :if-exists :supersede
                            :if-does-not-exist :create
                            :external-format :utf-8)
      (write-string (com.inuoe.jzon:stringify table) stream))
    (rename-file temporary path)
    path))

(declaim (ftype (function (&optional t) t) read-status))

(defun read-status (&optional (run (enchiridion:run-directory)))
  "Return the parsed status file as a hash table, or NIL.

A missing file is the normal answer when no supervisor runs. An unreadable or
half written file is treated the same way: the caller wants to know whether a
supervisor is up, and a parse error is not an answer to that question."
  (let ((path (status-file run)))
    (when (probe-file path)
      (handler-case
          (let ((text (uiop:read-file-string path :external-format :utf-8)))
            (if (plusp (length text))
                (com.inuoe.jzon:parse text)
                nil))
        (error () nil)))))

(declaim (ftype (function (t) t) status-pid))

(defun status-pid (status)
  "Return the process id the status file names, or NIL."
  (and (hash-table-p status) (gethash "pid" status)))

(declaim (ftype (function (t) t) status-updated))

(defun status-updated (status)
  "Return the universal time the status file was last written, or NIL."
  (and (hash-table-p status) (gethash "updated" status)))

(declaim (ftype (function (t) t) status-generation))

(defun status-generation (status)
  "Return the generation the status file names, or NIL."
  (and (hash-table-p status) (gethash "generation" status)))

(declaim (ftype (function (t) t) status-channels))

(defun status-channels (status)
  "Return the channel rows the status file holds, or NIL."
  (and (hash-table-p status) (gethash "channels" status)))

(declaim (ftype (function (t) t) status-bootstrap))

(defun status-bootstrap (status)
  "Return the one line bootstrap state the status file holds, or NIL."
  (and (hash-table-p status) (gethash "bootstrap" status)))

(declaim (ftype (function (t) t) status-report))

(defun status-report (status)
  "Return the last control report the status file holds, or NIL. A shell
command that only appended a line learns what happened by reading this."
  (and (hash-table-p status) (gethash "report" status)))

(declaim (ftype (function (t &key (:seconds integer)) boolean) status-fresh-p))

(defun status-fresh-p (status &key (seconds +status-fresh-seconds+))
  "Return T when STATUS was written recently by a supervisor that runs.

The running flag matters as much as the age. A supervisor that stopped writes
one last status file, and that file is a few milliseconds old: without the
flag, `enchiridion health` would report a healthy agent for ten seconds after
it stopped."
  (let ((updated (status-updated status)))
    (and (integerp updated)
         (not (null (and (hash-table-p status) (gethash "running" status))))
         (<= 0 (- (get-universal-time) updated) seconds))))

(declaim (ftype (function (string &key (:run t)) t) queue-control))

(defun queue-control (line &key (run (enchiridion:run-directory)))
  "Append LINE to the control file and return its path, without waiting.

The tool path uses this. A turn must not block on a poll: the agent asks for a
reload, the answer arrives in the transcript of a later turn."
  (check-type line string)
  (let ((path (control-file run)))
    (ensure-directories-exist path)
    (with-open-file (stream path
                            :direction :output
                            :if-exists :append
                            :if-does-not-exist :create
                            :external-format :utf-8)
      (write-string line stream)
      (terpri stream))
    path))

(declaim (ftype (function (string &key (:run t) (:wait real)) t) request-control))

(defun request-control (line &key (run (enchiridion:run-directory)) (wait 5))
  "Append LINE to the control file and return the status the supervisor writes
back, or NIL when no supervisor answers within WAIT seconds.

A shell command calls this. Nothing is started as a side effect: when no
supervisor is up the answer is NIL and the caller says so and exits non-zero."
  (check-type wait real)
  (let ((before (read-status run)))
    (unless (status-fresh-p before)
      (return-from request-control nil))
    (let ((previous (or (status-updated before) 0))
          (path (queue-control line :run run)))
      (declare (ignore path))
      (let ((deadline (+ (get-internal-real-time)
                         (* wait internal-time-units-per-second))))
        (loop
          (let ((status (read-status run)))
            (when (and status (> (or (status-updated status) 0) previous))
              (return status)))
          (when (> (get-internal-real-time) deadline)
            (return nil))
          (sleep 0.05))))))

;;;; The supervisor.

;; directory is the agent directory, run-directory is where the two files
;; live, channels is the list of live channel objects, and reload-function is
;; the hook that produces a new generation. The supervisor itself never loads
;; agent code, so a daemon passes a function that asks the broker.
(defstruct (supervisor (:constructor %make-supervisor))
  (directory "" :type string)
  (run-directory nil :type (or null string))
  (config nil :type t)
  (store nil :type t)
  (agent nil :type t)
  (session nil :type t)
  (broker nil :type t)
  (generation 0 :type integer)
  (channels '() :type list)
  (running-p nil :type boolean)
  (heartbeat-p nil :type boolean)
  (bootstrap-line "" :type string)
  (report "" :type string)
  (reload-function nil :type t)
  (started 0 :type integer))

(declaim (ftype (function (&key (:directory string) (:run-directory t)
                                (:config t) (:store t) (:agent t) (:session t)
                                (:broker t) (:generation integer) (:channels list)
                                (:bootstrap-line string) (:reload-function t))
                          supervisor)
                make-supervisor))

(defun make-supervisor (&key (directory "") (run-directory nil) (config nil)
                             (store nil) (agent nil) (session nil) (broker nil)
                             (generation 0) (channels '()) (bootstrap-line "")
                             (reload-function nil))
  "Return a SUPERVISOR. Nothing starts until SUPERVISOR-START."
  (%make-supervisor :directory directory
                    :run-directory (or run-directory (enchiridion:run-directory))
                    :config config
                    :store store
                    :agent agent
                    :session session
                    :broker broker
                    :generation generation
                    :channels channels
                    :bootstrap-line bootstrap-line
                    :reload-function reload-function))

(declaim (ftype (function (t) hash-table) channel-row))

(defun channel-row (channel)
  "Return CHANNEL as the JSON row the status file carries."
  (let ((row (make-hash-table :test #'equal))
        (name (enchiridion.channel:channel-name channel)))
    (setf (gethash "name" row) name)
    (setf (gethash "state" row)
          (string-downcase (string (enchiridion.channel:channel-state channel))))
    (setf (gethash "enabled" row) (not (null (enchiridion:channel-enabled-p name))))
    row))

(declaim (ftype (function (supervisor) pathname) supervisor-write-status))

(defun supervisor-write-status (supervisor)
  "Write the status file and return its path.

Every field a `health` reader needs is here: whether the process runs, the
generation, the channels, the bootstrap line, and the time. Nothing secret is
written, because the file is world readable."
  (let ((table (make-hash-table :test #'equal)))
    (setf (gethash "pid" table) (enchiridion.compat:process-id))
    (setf (gethash "running" table) (supervisor-running-p supervisor))
    (setf (gethash "started" table) (supervisor-started supervisor))
    (setf (gethash "updated" table) (get-universal-time))
    (setf (gethash "generation" table) (supervisor-generation supervisor))
    (setf (gethash "bootstrap" table) (supervisor-bootstrap-line supervisor))
    (setf (gethash "report" table) (supervisor-report supervisor))
    (setf (gethash "root" table) (supervisor-directory supervisor))
    (setf (gethash "config" table) (enchiridion:config-digest (supervisor-config supervisor)))
    (setf (gethash "channels" table)
          (mapcar #'channel-row (supervisor-channels supervisor)))
    (write-json-file (status-file (supervisor-run-directory supervisor)) table)))

;;;; Channels on their own threads.

(declaim (ftype (function (supervisor t) null) restart-channel-loop))

(defun restart-channel-loop (supervisor channel)
  "Start CHANNEL and restart it when it stops while the supervisor runs.

A failed channel is restarted and logged, and the agent keeps running: the
channel that died is one surface, not the process. The one second pause keeps
a channel that fails at once from becoming a busy loop."
  (loop
    (handler-case
        (enchiridion.channel:channel-start channel)
      (error (condition)
        (format *error-output* "~&enchiridion: channel ~A stopped: ~A~%"
                (enchiridion.channel:channel-name channel) condition)
        (finish-output *error-output*)))
    (unless (supervisor-running-p supervisor)
      (return nil))
    (sleep 1)))

(declaim (ftype (function (supervisor t) t) start-channel))

(defun start-channel (supervisor channel)
  "Run CHANNEL on its own thread and return it."
  (setf (enchiridion.channel:channel-thread channel)
        (bordeaux-threads:make-thread
         (lambda () (restart-channel-loop supervisor channel))
         :name (format nil "enchiridion channel ~A"
                       (enchiridion.channel:channel-name channel))))
  (setf (enchiridion.channel:channel-state channel) :running)
  channel)

(declaim (ftype (function (supervisor) supervisor) supervisor-start))

(defun supervisor-start (supervisor)
  "Start every channel and write the first status file. Return SUPERVISOR."
  (when (supervisor-running-p supervisor)
    (return-from supervisor-start supervisor))
  (setf (supervisor-started supervisor) (get-universal-time))
  (setf (supervisor-running-p supervisor) t)
  (dolist (channel (supervisor-channels supervisor))
    (start-channel supervisor channel))
  (supervisor-write-status supervisor)
  supervisor)

(declaim (ftype (function (supervisor) supervisor) supervisor-stop))

(defun supervisor-stop (supervisor)
  "Stop every channel, clear the running flag, and write the last status.
Return SUPERVISOR."
  (setf (supervisor-running-p supervisor) nil)
  (dolist (channel (supervisor-channels supervisor))
    (handler-case (enchiridion.channel:channel-stop channel)
      (error () nil))
    (let ((thread (enchiridion.channel:channel-thread channel)))
      (when (and thread (bordeaux-threads:thread-alive-p thread))
        (ignore-errors (bordeaux-threads:destroy-thread thread))))
    (setf (enchiridion.channel:channel-thread channel) nil)
    (setf (enchiridion.channel:channel-state channel) :stopped))
  (supervisor-write-status supervisor)
  supervisor)

;;;; The control file.

(declaim (ftype (function (t) list) consume-control-lines))

(defun consume-control-lines (run)
  "Return the pending control lines and empty the file.

The supervisor is the only reader, so a read followed by a truncate is the
whole protocol. A request appended in the window between the two is lost, and
that window is one file read wide: the operator asks again."
  (let ((path (control-file run)))
    (when (probe-file path)
      (let ((lines (handler-case (uiop:read-file-lines path) (error () '()))))
        (handler-case
            (with-open-file (stream path
                                    :direction :output
                                    :if-exists :supersede
                                    :if-does-not-exist :create)
              ;; IGNORABLE and not IGNORE: WITH-OPEN-FILE's cleanup form reads
              ;; the variable to close the stream, and a declared-IGNORE
              ;; variable that is read is itself a warning, which this tree
              ;; makes fatal.
              (declare (ignorable stream)))
          (error () nil))
        (remove-if (lambda (line)
                     (zerop (length (string-trim '(#\Space #\Tab #\Return) line))))
                   lines)))))

(declaim (ftype (function (supervisor t) t) find-channel))

(defun find-channel (supervisor name)
  "Return the channel SUPERVISOR calls NAME, or NIL. NAME matches a string or
a keyword, because both spellings reach here."
  (find (string-downcase (string name))
        (supervisor-channels supervisor)
        :key (lambda (channel)
               (string-downcase (enchiridion.channel:channel-name channel)))
        :test #'string=))

(declaim (ftype (function (supervisor t) t) handle-channels))

(defun handle-channels (supervisor arguments)
  "Act on `channels list|enable N|disable N` and return a one line report."
  (let ((action (string-downcase (or (first arguments) "list")))
        (name (second arguments)))
    (cond
      ((string= action "list")
       (format nil "~{~A~^, ~}"
               (mapcar (lambda (channel)
                         (format nil "~A ~A"
                                 (enchiridion.channel:channel-name channel)
                                 (string-downcase
                                  (string (enchiridion.channel:channel-state channel)))))
                       (supervisor-channels supervisor))))
      ((member action '("enable" "disable") :test #'string=)
       (let ((channel (and name (find-channel supervisor name))))
         (cond
           ((null name) "which channel?")
           ((null channel) (format nil "channel ~A is not implemented yet." name))
           ((string= action "enable")
            (if (eq (enchiridion.channel:channel-state channel) :running)
                (format nil "~A is already up." name)
                (progn (start-channel supervisor channel)
                       (format nil "~A is up." name))))
           (t
            (handler-case (enchiridion.channel:channel-stop channel) (error () nil))
            (let ((thread (enchiridion.channel:channel-thread channel)))
              (when (and thread (bordeaux-threads:thread-alive-p thread))
                (ignore-errors (bordeaux-threads:destroy-thread thread))))
            (setf (enchiridion.channel:channel-thread channel) nil)
            (setf (enchiridion.channel:channel-state channel) :stopped)
            (format nil "~A is down." name)))))
      (t (format nil "channels takes list, enable or disable.")))))

(declaim (ftype (function (supervisor t) t) handle-heartbeat))

(defun handle-heartbeat (supervisor arguments)
  "Act on `heartbeat on|off|run` and return a one line report. The tick itself
arrives with the sleep agent; until then `run` records the request."
  (let ((action (string-downcase (or (first arguments) "on"))))
    (cond
      ((string= action "on")
       (setf (supervisor-heartbeat-p supervisor) t)
       "heartbeat on.")
      ((string= action "off")
       (setf (supervisor-heartbeat-p supervisor) nil)
       "heartbeat off.")
      ((string= action "run")
       "heartbeat tick requested; the sleep agent answers this in milestone 10.")
      (t "heartbeat takes on, off or run."))))

(declaim (ftype (function (supervisor t) t) apply-reload-result))

(defun apply-reload-result (supervisor result)
  "Record RESULT's generation on SUPERVISOR when it loaded, and return RESULT.

A failed generation changes nothing: the last good code keeps serving, and the
report goes back to whoever asked. That is the whole promise of the loader."
  (when (and result (enchiridion.plugin:generation-result-ok-p result))
    (setf (supervisor-generation supervisor)
          (enchiridion.plugin:generation-result-generation result)))
  result)

(declaim (ftype (function (supervisor) t) default-reload))

(defun default-reload (supervisor)
  "Load a new generation in this process. Tests use this; a daemon passes its
own RELOAD-FUNCTION so the supervisor never loads agent code itself."
  (enchiridion.plugin:load-generation
   (supervisor-directory supervisor)
   :generation (1+ (supervisor-generation supervisor))))

(declaim (ftype (function (supervisor) t) supervisor-reload))

(defun supervisor-reload (supervisor)
  "Produce and record a new generation through the reload hook."
  (apply-reload-result
   supervisor
   (funcall (or (supervisor-reload-function supervisor) #'default-reload)
            supervisor)))

(declaim (ftype (function (supervisor t) t) handle-control))

(defun handle-control (supervisor line)
  "Act on one control LINE and return a one line report, or NIL."
  (let* ((parts (remove-if (lambda (part) (zerop (length part)))
                           (uiop:split-string line :separator " ")))
         (verb (string-downcase (or (first parts) ""))))
    (cond
      ((string= verb "reload")
       (let ((result (supervisor-reload supervisor)))
         (if (enchiridion.plugin:generation-result-ok-p result)
             (format nil "reload done, generation ~D."
                     (enchiridion.plugin:generation-result-generation result))
             (format nil "reload refused: ~A"
                     (enchiridion.plugin:generation-result-report result)))))
      ((string= verb "channels") (handle-channels supervisor (rest parts)))
      ((string= verb "heartbeat") (handle-heartbeat supervisor (rest parts)))
      (t (format nil "unknown control request: ~A" line)))))

(declaim (ftype (function (supervisor) integer) supervisor-poll-control))

(defun supervisor-poll-control (supervisor)
  "Consume the control file, act on each line, and return how many it read.

The last report is written into the status file, which is how a shell command
that only appended a line learns what happened."
  (let ((lines (consume-control-lines (supervisor-run-directory supervisor))))
    (dolist (line lines)
      (let ((report (handle-control supervisor line)))
        (when report
          (setf (supervisor-report supervisor) report)
          (format *error-output* "~&enchiridion: ~A~%" report)
          (finish-output *error-output*))))
    (when lines
      (supervisor-write-status supervisor))
    (length lines)))

(declaim (ftype (function (supervisor &key (:interval real)) supervisor)
                supervisor-poll-loop))

(defun supervisor-poll-loop (supervisor &key (interval 1))
  "Poll the control file and rewrite the status file until SUPERVISOR stops.
Writing the status on every tick is what keeps it fresh, which is how a reader
tells a running supervisor from a file a dead one left."
  (loop while (supervisor-running-p supervisor)
        do (supervisor-poll-control supervisor)
           (supervisor-write-status supervisor)
           (sleep interval))
  supervisor)
