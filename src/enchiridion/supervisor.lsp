;;;; supervisor.lsp --- Supervisor owning channels, heartbeat, and run/ IPC files.
;;;;
;;;; Shell commands communicate via polled request/response files in run/control/
;;;; and a periodically rewritten run/enchiridion.status file.
;;;; RELOAD-FUNCTION and TICK-FUNCTION are caller-supplied hooks so the supervisor
;;;; stays decoupled from the broker and kernel.

(in-package #:enchiridion.supervisor)

(defparameter +status-fresh-seconds+ 10
  "Maximum age in seconds for a status file to count as live.")

(defparameter +status-refresh-seconds+ 1
  "Interval in seconds for background status refreshes during slow control requests.")

(defparameter +status-report-seconds+ 30
  "Minimum interval in seconds between repeated error logs for the same write failure.")

(defun delete-file-if-present (path)
  "Delete PATH when it still exists. A vanished entry is already clean."
  (when (probe-file path)
    (ignore-errors (delete-file path))))

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

(defparameter *json-write-lock* (bordeaux-threads:make-lock "json write names"))
(defvar *json-write-counter* 0)

(declaim (ftype (function (pathname t) t) write-json-file))

(defun write-json-file (path table)
  "Atomically write TABLE as JSON to PATH via a unique PID/counter staging file and rename."
  (let* ((directory (uiop:pathname-directory-pathname path))
         (temporary (merge-pathnames
                     (format nil "~A.~D-~D.new"
                             (file-namestring path)
                             (enchiridion.compat:process-id)
                             (bordeaux-threads:with-lock-held (*json-write-lock*)
                               (incf *json-write-counter*)))
                     directory)))
    (ensure-directories-exist temporary)
    (unwind-protect
         (progn
           (with-open-file (stream temporary
                                   :direction :output
                                   :if-exists :supersede
                                   :if-does-not-exist :create
                                   :external-format :utf-8)
             (write-string (com.inuoe.jzon:stringify table) stream))
           (rename-file temporary path)
           path)
      ;; Clean up the staging file if stringify or rename fails.
      (delete-file-if-present temporary))))

(declaim (ftype (function (&optional t) t) read-status))

(defun read-status (&optional (run (enchiridion:run-directory)))
  "Return the parsed status file as a hash table, or NIL if missing or unreadable."
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
  "Return the channel rows from STATUS as a list (coercing JZON vectors), or NIL."
  (let ((rows (and (hash-table-p status) (gethash "channels" status))))
    (cond
      ((null rows) nil)
      ((listp rows) rows)
      ((vectorp rows) (coerce rows 'list))
      (t nil))))

(declaim (ftype (function (t) t) status-handled))

(defun status-handled (status)
  "Return the count of control requests answered by the supervisor, or NIL."
  (and (hash-table-p status) (gethash "handled" status)))

(declaim (ftype (function (t) t) status-bootstrap))

(defun status-bootstrap (status)
  "Return the one line bootstrap state the status file holds, or NIL."
  (and (hash-table-p status) (gethash "bootstrap" status)))

(declaim (ftype (function (t) t) status-report))

(defun status-report (status)
  "Return the last control report string from STATUS, or NIL."
  (and (hash-table-p status) (gethash "report" status)))

(declaim (ftype (function (t) t) status-report-ok-p))

(defun status-report-ok-p (status)
  "Return T if the last control request succeeded, or NIL if refused or absent."
  (and (hash-table-p status) (gethash "report-ok" status)))

(declaim (ftype (function (t) t) status-writes))

(defun status-writes (status)
  "Return the write report object from STATUS, or NIL. Reflects the previous write."
  (and (hash-table-p status) (gethash "writes" status)))

(declaim (ftype (function (t) t) status-heartbeat))

(defun status-heartbeat (status)
  "Return the heartbeat status hash table from STATUS, or NIL."
  (and (hash-table-p status) (gethash "heartbeat" status)))

(declaim (ftype (function (t &key (:seconds integer)) boolean) status-fresh-p))

(defun status-fresh-p (status &key (seconds +status-fresh-seconds+))
  "Return T when STATUS has running=true and was updated within SECONDS.
Checking the running flag prevents a freshly written shutdown status from looking live."
  (let ((updated (status-updated status)))
    (and (integerp updated)
         (not (null (and (hash-table-p status) (gethash "running" status))))
         (<= 0 (- (get-universal-time) updated) seconds))))

(declaim (ftype (function (string &key (:run t)) t) queue-control))

(defparameter *control-id-lock* (bordeaux-threads:make-lock "control ids"))
(defvar *control-id* 0)
(defparameter +control-retention-seconds+ 60
  "How long an answer or a staging file stays in the spool.")

(defparameter +control-pending-seconds+ 900
  "Maximum age in seconds for a queued control request before expiring.
Exceeds the 660s broker call limit so requests queued behind a reload drain normally.")

(defparameter +control-file-limit+ 256)

(defun control-spool (run)
  "Return the directory that holds request, response, and claim files."
  (merge-pathnames "control/" (uiop:ensure-directory-pathname run)))


(defun control-file-older-p (path cutoff)
  "Return T when PATH still exists and was last written before CUTOFF."
  (let ((date (ignore-errors (file-write-date path))))
    (and date (< date cutoff))))

(defun control-entry-claim (path)
  "Return the claim path belonging to PATH, a request or response file."
  (let* ((name (pathname-name path))
         (cut (or (position #\_ name) (length name))))
    (make-pathname :name (subseq name 0 cut) :type "claim" :defaults path)))

(defun control-entry-live-p (claim paths)
  "Return T when a request or response in PATHS still uses CLAIM."
  (let ((prefix (concatenate 'string (pathname-name claim) "_")))
    (some (lambda (other)
            (and (not (equal other claim))
                 (member (pathname-type other) '("request" "response" "new")
                         :test #'equal)
                 (let ((name (pathname-name other)))
                   (and (> (length name) (length prefix))
                        (string= prefix name :end2 (length prefix))))))
          paths)))

(defun clean-control-spool (run)
  "Remove expired responses, staging files, unknown files, and abandoned claims.
Pending requests are kept. Claims are re-listed after deleting expired files so
active requests keep their slots."
  (ensure-directories-exist (control-spool run))
  (let ((cutoff (- (get-universal-time) +control-retention-seconds+)))
    (dolist (path (uiop:directory-files (control-spool run)))
      (when (and (member (pathname-type path) '("new" "response") :test #'equal)
                 (control-file-older-p path cutoff))
        (delete-file-if-present path)))
    (let ((paths (uiop:directory-files (control-spool run))))
      (dolist (path paths)
        (unless (member (pathname-type path) '("request" "response" "claim" "new")
                        :test #'equal)
          (when (control-file-older-p path cutoff)
            (delete-file-if-present path))))
      (let ((current (uiop:directory-files (control-spool run))))
        (dolist (path current)
          (when (and (equal "claim" (pathname-type path))
                     (control-file-older-p path cutoff)
                     (not (control-entry-live-p path current)))
            (delete-file-if-present path)))))))

(defun reserve-control-slot (run)
  "Reserve one exclusive admission slot under RUN and return its claim path."
  (loop for slot below +control-file-limit+
        for path = (merge-pathnames (format nil "~D.claim" slot) (control-spool run))
        do (let ((stream (open path :direction :output :if-exists nil
                                   :if-does-not-exist :create)))
             (when stream
               (close stream)
               (return-from reserve-control-slot path))))
  (error "The control queue is full."))

(defun queue-control (line &key (run (enchiridion:run-directory)))
  "Publish one bounded control request atomically and return its path."
  (check-type line string)
  (when (or (> (length line) 4096) (find #\Newline line) (find #\Return line))
    (error "Control requests must be one line of at most 4096 characters."))
  (clean-control-spool run)
  (let* ((claim (reserve-control-slot run))
         (id (bordeaux-threads:with-lock-held (*control-id-lock*)
               (format nil "~A_~D-~D-~D-~D" (pathname-name claim) (get-universal-time)
                       (enchiridion.compat:process-id) (incf *control-id*)
                       (random most-positive-fixnum))))
         (path (merge-pathnames (concatenate 'string id ".request") (control-spool run)))
         (temporary (make-pathname :type "new" :defaults path)))
    (unwind-protect
         (progn
           (with-open-file (stream temporary :direction :output :if-exists :error
                                             :external-format :utf-8)
             (write-line line stream))
           (rename-file temporary path)
           path)
      (when (probe-file temporary) (delete-file temporary))
      (unless (probe-file path) (delete-file claim)))))

(defparameter +control-wait-seconds+ 5
  "Default timeout in seconds for a shell command waiting on a control response.")

(declaim (ftype (function (t t) string) control-wait-detail))

(defun control-wait-detail (run path)
  "Return a status line for an unanswered request at PATH (queued count or in progress)."
  (if (probe-file path)
      (let* ((slot (or (parse-integer (pathname-name path) :junk-allowed t)
                       most-positive-fixnum))
             (requests (remove-if-not
                        (lambda (other) (equal "request" (pathname-type other)))
                        (ignore-errors (uiop:directory-files (control-spool run)))))
             (ahead (count-if (lambda (other)
                                (let ((other-slot
                                        (ignore-errors
                                          (parse-integer (pathname-name other)
                                                         :junk-allowed t))))
                                  (and other-slot (< other-slot slot))))
                              requests)))
        (if (plusp ahead)
            (format nil "the request is still queued behind ~D other request~:P."
                    ahead)
            (format nil "the request is still queued.")))
      "the supervisor has taken the request and has not answered it yet."))

(declaim (ftype (function (string &key (:run t) (:wait real)) t) request-control))

(defun request-control (line &key (run (enchiridion:run-directory))
                                 (wait +control-wait-seconds+))
  "Send LINE to the supervisor at RUN and return (values answer status detail).
STATUS is :ANSWERED, :NO-SUPERVISOR, :TIMEOUT, or :QUEUE-FULL.
Timed-out requests remain queued and are not cancelled."
  (check-type wait (real 0 30))
  (unless (status-fresh-p (read-status run))
    (return-from request-control (values nil :no-supervisor nil)))
  (let ((path (handler-case (queue-control line :run run)
                (error (condition)
                  (return-from request-control
                    (values nil :queue-full
                            (format nil "the request was not queued: ~A"
                                    condition)))))))
    (let ((response (make-pathname :type "response" :defaults path))
          (deadline (+ (get-internal-real-time)
                       (* wait internal-time-units-per-second))))
      (loop
        (when (probe-file response)
          (unwind-protect
               (return (values (com.inuoe.jzon:parse
                                (uiop:read-file-string response :external-format :utf-8))
                               :answered nil))
            ;; Ignore missing files if another reader already cleaned up.
            (delete-file-if-present response)
            (delete-file-if-present (control-entry-claim path))))
        (when (>= (get-internal-real-time) deadline)
          (return (values nil :timeout (control-wait-detail run path))))
        (sleep 0.05)))))

;;;; The supervisor.

;; RELOAD-FUNCTION and TICK-FUNCTION are caller-supplied hooks (this file loads
;; before the kernel and stays decoupled from the broker). LAST-TICK is recorded
;; at tick completion so slow ticks do not overlap.
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
  ;; Keep disabled names visible after removing their channel objects
  (disabled-channels '() :type list)
  (channel-factory nil :type (or null function))
  (running-p nil :type boolean)
  (heartbeat-p nil :type boolean)
  (heartbeat-interval 900 :type integer)
  (heartbeat-thread nil :type t)
  (tick-function nil :type t)
  (tick-running-p nil :type boolean)
  (tick-requested-p nil :type boolean)
  (tick-ok-p t :type boolean)
  (tick-report "" :type string)
  (ticks 0 :type integer)
  (last-tick 0 :type integer)
  (tick-started 0 :type integer)
  (last-compacted-turn 0 :type integer)
  (last-sleep-turn 0 :type integer)
  (bootstrap-line "" :type string)
  (report "" :type string)
  (report-ok-p t :type boolean)
  (handled 0 :type integer)
  (reload-function nil :type t)
  (started 0 :type integer))

(declaim (ftype (function (&key (:directory string) (:run-directory t)
                                (:config t) (:store t) (:agent t) (:session t)
                                (:broker t) (:generation integer) (:channels list)
                                 (:channel-factory t)
                                (:heartbeat-p t) (:heartbeat-interval integer)
                                (:tick-function t) (:bootstrap-line string)
                                (:reload-function t))
                          supervisor)
                make-supervisor))

(defun make-supervisor (&key (directory "") (run-directory nil) (config nil)
                             (store nil) (agent nil) (session nil) (broker nil)
                             (generation 0) (channels '()) (channel-factory nil) (heartbeat-p nil)
                             (heartbeat-interval 900) (tick-function nil)
                             (bootstrap-line "") (reload-function nil))
  "Return a SUPERVISOR (stopped until SUPERVISOR-START).
Non-positive or non-integer HEARTBEAT-INTERVAL falls back to 900 seconds."
  (%make-supervisor :directory directory
                    :run-directory (or run-directory (enchiridion:run-directory))
                    :config config
                    :store store
                    :agent agent
                    :session session
                    :broker broker
                    :generation generation
                    :channels channels
                     :channel-factory channel-factory
                    :heartbeat-p (not (null heartbeat-p))
                    :heartbeat-interval (if (and (integerp heartbeat-interval)
                                                 (plusp heartbeat-interval))
                                            heartbeat-interval
                                            900)
                    :tick-function tick-function
                    :bootstrap-line bootstrap-line
                    :reload-function reload-function))

(declaim (ftype (function (t) hash-table) channel-row))

(defun channel-row (channel)
  "Return CHANNEL as a status JSON row with enabled=T (only active channels have objects)."
  (let ((row (make-hash-table :test #'equal)))
    (setf (gethash "name" row) (enchiridion.channel:channel-name channel))
    (setf (gethash "state" row)
          (string-downcase (string (enchiridion.channel:channel-state channel))))
    (setf (gethash "enabled" row) t)
    row))

(declaim (ftype (function (supervisor) list) configured-channel-names))

(defun configured-channel-names (supervisor)
  "Return lowercase channel names from both default and supervisor configs."
  (let ((names '()))
    (dolist (config (list (enchiridion:default-config)
                          (supervisor-config supervisor)))
      (dolist (entry (enchiridion:config-section config :channels))
        (let ((name (first entry)))
          (when (or (keywordp name) (stringp name))
            (pushnew (string-downcase (string name)) names :test #'string=)))))
    (nreverse names)))

(declaim (ftype (function (string) hash-table) disabled-channel-row))

(defun disabled-channel-row (name)
  "Return a status JSON row for an intentionally disabled channel (state \"disabled\", enabled NIL)."
  (let ((row (make-hash-table :test #'equal)))
    (setf (gethash "name" row) name)
    (setf (gethash "state" row) "disabled")
    (setf (gethash "enabled" row) nil)
    row))

(declaim (ftype (function (supervisor) vector) supervisor-channel-rows))

(defun supervisor-channel-rows (supervisor)
  "Return a vector of status rows for all active, configured, and disabled channels."
  (let* ((channels (supervisor-channels supervisor))
         (rows (mapcar #'channel-row channels))
         (seen (mapcar (lambda (row) (gethash "name" row)) rows))
         (names (remove-duplicates
                 (remove-if (lambda (name) (member name seen :test #'string=))
                            (append (configured-channel-names supervisor)
                                    (supervisor-disabled-channels supervisor)))
                 :test #'string=)))
    (coerce (append rows (mapcar #'disabled-channel-row names)) 'vector)))

(declaim (ftype (function (supervisor) boolean) supervisor-heartbeat-live-p))

(defun supervisor-heartbeat-live-p (supervisor)
  "Return T when SUPERVISOR's heartbeat thread is currently alive."
  (let ((thread (supervisor-heartbeat-thread supervisor)))
    (and thread (bordeaux-threads:thread-alive-p thread))))

(defvar *status-error-report* nil
  "Last logged write failure as (message . universal-time) for rate-limiting.")

(defvar *status-write-failure* nil
  "Last write failure as (message . universal-time), cleared on the next successful write.")

(declaim (ftype (function (t t) null) note-write-error))

(defun note-write-error (what condition)
  "Record and rate-limit logging of a write failure for WHAT (once per +STATUS-REPORT-SECONDS+)."
  (let* ((message (enchiridion.llm.secrets:scrub (princ-to-string condition)))
         (now (get-universal-time))
         (last *status-error-report*))
    (setf *status-write-failure* (cons message now))
    (unless (and last (string= (car last) message)
                 (< (- now (cdr last)) +status-report-seconds+))
      (setf *status-error-report* (cons message now))
      (format *error-output* "~&enchiridion: ~A failed: ~A~%" what message)
      (finish-output *error-output*))))

(declaim (ftype (function () null) note-write-ok))

(defun note-write-ok ()
  "Record that a write landed, so a failure that is over stops being reported."
  (setf *status-write-failure* nil))

(declaim (ftype (function () hash-table) supervisor-write-report))

(defun supervisor-write-report ()
  "Return a JSON object describing the previous write's status (ok, report, age)."
  (let ((row (make-hash-table :test #'equal))
        (failure *status-write-failure*))
    (setf (gethash "ok" row) (null failure))
    (setf (gethash "report" row) (or (car failure) ""))
    (setf (gethash "age" row)
          (if failure (max 0 (- (get-universal-time) (cdr failure))) 0))
    row))

(declaim (ftype (function (supervisor) hash-table) supervisor-status-table))

(defun supervisor-status-table (supervisor)
  "Build and return the status hash table (world-readable; secrets are scrubbed)."
  (let ((table (make-hash-table :test #'equal)))
    (setf (gethash "pid" table) (enchiridion.compat:process-id))
    (setf (gethash "running" table) (supervisor-running-p supervisor))
    (setf (gethash "started" table) (supervisor-started supervisor))
    (setf (gethash "updated" table) (get-universal-time))
    (setf (gethash "generation" table) (supervisor-generation supervisor))
    (setf (gethash "bootstrap" table) (supervisor-bootstrap-line supervisor))
    ;; Scrub report strings before writing to the world-readable status file.
    (setf (gethash "report" table)
          (enchiridion.llm.secrets:scrub (supervisor-report supervisor)))
    (setf (gethash "report-ok" table) (supervisor-report-ok-p supervisor))
    (setf (gethash "handled" table) (supervisor-handled supervisor))
    (setf (gethash "heartbeat" table)
          (let ((beat (make-hash-table :test #'equal)))
            ;; Enabled only when both requested and a tick hook is attached.
            (setf (gethash "enabled" beat)
                  (and (supervisor-heartbeat-p supervisor)
                       (not (null (supervisor-tick-function supervisor)))))
            (setf (gethash "alive" beat) (supervisor-heartbeat-live-p supervisor))
            (setf (gethash "requested" beat) (supervisor-tick-requested-p supervisor))
            (setf (gethash "ticks" beat) (supervisor-ticks supervisor))
            (setf (gethash "last-tick" beat) (supervisor-last-tick supervisor))
            (setf (gethash "running" beat) (supervisor-tick-running-p supervisor))
            (setf (gethash "started" beat) (supervisor-tick-started supervisor))
            (setf (gethash "ok" beat) (supervisor-tick-ok-p supervisor))
            (setf (gethash "report" beat)
                  (enchiridion.llm.secrets:scrub (supervisor-tick-report supervisor)))
            beat))
    (setf (gethash "root" table) (supervisor-directory supervisor))
    (setf (gethash "config" table) (enchiridion:config-digest (supervisor-config supervisor)))
    ;; Reports the preceding write
    (setf (gethash "writes" table) (supervisor-write-report))
    (setf (gethash "channels" table)
          ;; Vector so empty encodes as JSON [] rather than false.
          (supervisor-channel-rows supervisor))
    table))

(declaim (ftype (function (supervisor) hash-table) supervisor-write-status))

(defun supervisor-write-status (supervisor)
  "Atomically write the status file via a unique staging rename (no lock held) and return the table."
  (let ((table (supervisor-status-table supervisor)))
    (write-json-file (status-file (supervisor-run-directory supervisor)) table)
    table))

(declaim (ftype (function (supervisor &optional t) t) supervisor-try-write-status))

(defun supervisor-try-write-status (supervisor &optional (what "the status file"))
  "Write the status file and return its table, or log and return NIL on error."
  (handler-case (progn (note-write-ok) (supervisor-write-status supervisor))
    (error (condition) (note-write-error what condition) nil)))

;;;; Channels on their own threads.

(declaim (ftype (function (supervisor t) null) restart-channel-loop))

(defun restart-channel-loop (supervisor channel)
  "Run CHANNEL and restart it after a 1s delay on error while the supervisor is running."
  (loop
    (handler-case
        (progn
          (setf (enchiridion.channel::channel-start-error channel) nil)
          (enchiridion.channel:channel-start channel))
      (error (condition)
        (setf (enchiridion.channel:channel-state channel) :failed
              (enchiridion.channel::channel-start-error channel)
              (enchiridion.llm.secrets:scrub (princ-to-string condition)))
        (format *error-output* "~&enchiridion: channel ~A stopped: ~A~%"
                (enchiridion.channel:channel-name channel)
                (enchiridion.channel::channel-start-error channel))
        (finish-output *error-output*)))
    (when (or (not (supervisor-running-p supervisor))
              (member (enchiridion.channel:channel-state channel)
                      '(:unavailable)))
      (return nil))
    (sleep 1)))

(declaim (ftype (function (supervisor t) t) start-channel))

(defun start-channel (supervisor channel)
  "Run CHANNEL on its own thread and return it."
  (setf (enchiridion.channel:channel-state channel) :starting
        (enchiridion.channel::channel-start-error channel) nil)
  (setf (enchiridion.channel:channel-thread channel)
        (bordeaux-threads:make-thread
         (lambda () (restart-channel-loop supervisor channel))
         :name (format nil "enchiridion channel ~A"
                       (enchiridion.channel:channel-name channel))))
  channel)

(declaim (ftype (function (supervisor) supervisor) supervisor-ensure-heartbeat-thread))

(defun supervisor-ensure-heartbeat-thread (supervisor)
  "Start the heartbeat thread if running with a tick hook and no live thread.
Initializes LAST-TICK to now so the first scheduled tick waits one interval."
  (when (and (supervisor-tick-function supervisor)
             (supervisor-running-p supervisor)
             (not (supervisor-heartbeat-live-p supervisor)))
    (setf (supervisor-last-tick supervisor) (get-universal-time))
    (setf (supervisor-heartbeat-thread supervisor)
          (bordeaux-threads:make-thread
           (lambda () (supervisor-heartbeat-loop supervisor))
           :name "enchiridion heartbeat")))
  supervisor)

(declaim (ftype (function (supervisor) supervisor) supervisor-start))

(defun supervisor-start (supervisor)
  "Start every channel and write the first status file. Return SUPERVISOR."
  (when (supervisor-running-p supervisor)
    (return-from supervisor-start supervisor))
  (setf (supervisor-started supervisor) (get-universal-time))
  (setf (supervisor-running-p supervisor) t)
  (dolist (channel (supervisor-channels supervisor))
    (start-channel supervisor channel))
  ;; Run heartbeat on its own thread so slow ticks do not starve status refreshes.
  (when (supervisor-heartbeat-p supervisor)
    (supervisor-ensure-heartbeat-thread supervisor))
  (supervisor-write-status supervisor)
  supervisor)

(defparameter +shutdown-budget-seconds+ 20
  "Total shutdown deadline in seconds shared across heartbeat drain and channel stops.")

(defparameter +tick-drain-seconds+ 10
  "Maximum seconds of the shutdown budget allotted to draining an active heartbeat tick.")

(defparameter +channel-stop-seconds+ 8
  "Maximum seconds of the shutdown budget allotted to stopping a single channel.")

(declaim (ftype (function (real) real) remaining-seconds))

(defun remaining-seconds (deadline)
  "Return how many seconds are left before DEADLINE, an internal real time."
  (max 0 (/ (- deadline (get-internal-real-time))
            internal-time-units-per-second)))

(declaim (ftype (function (t real) null) note-stop-timeout))

(defun note-stop-timeout (channel seconds)
  "Log that CHANNEL exceeded SECONDS during shutdown and mark it stopped."
  (format *error-output*
          "~&enchiridion: channel ~A did not stop within ~,1F second~:P of the shutdown.~%"
          (enchiridion.channel:channel-name channel) seconds)
  (finish-output *error-output*)
  (setf (enchiridion.channel:channel-live-p channel) nil
        (enchiridion.channel:channel-state channel) :stopped)
  nil)

(declaim (ftype (function (supervisor) supervisor) supervisor-stop))

(defun supervisor-stop (supervisor)
  "Stop heartbeat and channels within +SHUTDOWN-BUDGET-SECONDS+, write final status, and return SUPERVISOR."
  (setf (supervisor-running-p supervisor) nil)
  (let ((deadline (+ (get-internal-real-time)
                     (* +shutdown-budget-seconds+ internal-time-units-per-second))))
    (let ((beat (supervisor-heartbeat-thread supervisor)))
      (when (and beat (bordeaux-threads:thread-alive-p beat))
        ;; Wait up to +tick-drain-seconds+ before destroying the thread to avoid interrupting SQLite.
        (let ((until (min deadline
                          (+ (get-internal-real-time)
                             (* +tick-drain-seconds+
                                internal-time-units-per-second)))))
          (loop while (and (bordeaux-threads:thread-alive-p beat)
                           (< (get-internal-real-time) until))
                do (sleep 0.05)))
        (when (bordeaux-threads:thread-alive-p beat)
          (format *error-output*
                  "~&enchiridion: a heartbeat tick outlasted its ~D second shutdown share.~%"
                  +tick-drain-seconds+)
          (finish-output *error-output*)
          (ignore-errors (bordeaux-threads:destroy-thread beat))
          ;; Clear running flag so the final status does not report a destroyed tick as active.
          (setf (supervisor-tick-running-p supervisor) nil)))
      (setf (supervisor-heartbeat-thread supervisor) nil))
    (dolist (channel (supervisor-channels supervisor))
      ;; Skip already-stopped channels (stop may be called from both signal handler and unwind-protect).
      (unless (and (not (enchiridion.channel:channel-live-p channel))
                   (eq :stopped (enchiridion.channel:channel-state channel)))
        (let ((share (min +channel-stop-seconds+ (remaining-seconds deadline))))
          (handler-case
              (cond
                ((not (plusp share)) (note-stop-timeout channel share))
                ((eq :stop-timed-out
                     (enchiridion.compat:with-deadline
                         (share :on-timeout :stop-timed-out)
                       (stop-channel channel)))
                 (note-stop-timeout channel share)))
            (error (condition)
              (format *error-output*
                      "~&enchiridion: channel ~A refused to stop: ~A~%"
                      (enchiridion.channel:channel-name channel)
                      (enchiridion.llm.secrets:scrub (princ-to-string condition)))
              (finish-output *error-output*)
              (note-stop-timeout channel share)))))))
  (supervisor-try-write-status supervisor)
  supervisor)

;;;; The heartbeat.

(declaim (ftype (function (supervisor) boolean) supervisor-heartbeat-due-p))

(defun supervisor-heartbeat-due-p (supervisor)
  "Return T when a tick is explicitly requested or HEARTBEAT-INTERVAL has elapsed since LAST-TICK."
  (or (supervisor-tick-requested-p supervisor)
      (and (supervisor-heartbeat-p supervisor)
           (>= (- (get-universal-time) (supervisor-last-tick supervisor))
               (supervisor-heartbeat-interval supervisor)))))

(declaim (ftype (function (supervisor) t) supervisor-tick))

(defun supervisor-tick (supervisor)
  "Run one tick via the hook, record status, and return its result plist. Never signals."
  (setf (supervisor-tick-requested-p supervisor) nil
        (supervisor-tick-running-p supervisor) t
        (supervisor-tick-started supervisor) (get-universal-time))
  (unwind-protect
       (let* ((hook (supervisor-tick-function supervisor))
              (result (if hook
                          (handler-case (funcall hook supervisor)
                            (error (condition)
                              (list :ok-p nil
                                    :report (enchiridion.errors:condition-report-line
                                             condition))))
                          (list :ok-p nil :report "no heartbeat hook is attached"))))
         (setf (supervisor-last-tick supervisor) (get-universal-time)
               (supervisor-ticks supervisor) (1+ (supervisor-ticks supervisor))
               (supervisor-tick-ok-p supervisor) (not (null (getf result :ok-p)))
               (supervisor-tick-report supervisor) (or (getf result :report) ""))
         result)
    (setf (supervisor-tick-running-p supervisor) nil)))

(declaim (ftype (function (supervisor &key (:interval real)) supervisor)
                supervisor-heartbeat-loop))

(defun supervisor-heartbeat-loop (supervisor &key (interval 1))
  "Poll every INTERVAL seconds and run ticks when due until SUPERVISOR stops."
  (loop while (supervisor-running-p supervisor)
        do (when (supervisor-heartbeat-due-p supervisor)
             (supervisor-tick supervisor))
           (sleep interval))
  supervisor)

;;;; The control file.

(defun consume-control-lines (run)
  "Rotate legacy input without truncating an active writer's file."
  (let* ((path (control-file run))
         (batch (make-pathname :type "batch" :defaults path)))
    (when (and (probe-file path) (not (probe-file batch)))
      (rename-file path batch))
    (when (probe-file batch)
      (prog1 (remove-if (lambda (line) (zerop (length line)))
                        (uiop:read-file-lines batch :external-format :utf-8))
        (delete-file batch)))))

(declaim (ftype (function (supervisor t) t) find-channel))

(defun find-channel (supervisor name)
  "Return the active channel matching NAME (string or keyword, case-insensitive), or NIL."
  (find (string-downcase (string name))
        (supervisor-channels supervisor)
        :key (lambda (channel)
               (string-downcase (enchiridion.channel:channel-name channel)))
        :test #'string=))

(defun stop-channel (channel)
  "Stop CHANNEL and release its supervisor thread."
  (unwind-protect
       (enchiridion.channel:channel-stop channel)
    (let ((thread (enchiridion.channel:channel-thread channel)))
      (when (and thread (bordeaux-threads:thread-alive-p thread))
        (bordeaux-threads:destroy-thread thread)))
    (setf (enchiridion.channel:channel-thread channel) nil
          (enchiridion.channel:channel-live-p channel) nil
          (enchiridion.channel:channel-state channel) :stopped))
  channel)

(defparameter +channel-start-seconds+ 20
  "How long a replacement candidate may take to report :live.")

(declaim (ftype (function (t real) (values boolean t)) wait-for-channel))

(defun wait-for-channel (channel seconds)
  "Wait up to SECONDS for CHANNEL's thread to report :live, returning (values live-p reason)."
  (let ((deadline (+ (get-internal-real-time)
                     (* seconds internal-time-units-per-second))))
    (loop until (or (enchiridion.channel:channel-live-p channel)
                    (member (enchiridion.channel:channel-state channel)
                            '(:failed :unavailable))
                    (>= (get-internal-real-time) deadline))
          do (sleep 0.01))
    (if (enchiridion.channel:channel-live-p channel)
        (values t nil)
        (values nil (or (enchiridion.channel::channel-start-error channel)
                        (enchiridion.channel:channel-state channel))))))

(declaim (ftype (function (supervisor t t) t) install-channel))

(defun install-channel (supervisor candidate old)
  "Install CANDIDATE on SUPERVISOR, replacing OLD and clearing its name from disabled-channels."
  (let ((name (string-downcase (enchiridion.channel:channel-name candidate))))
    (setf (supervisor-disabled-channels supervisor)
          (remove name (supervisor-disabled-channels supervisor) :test #'string=)))
  (setf (supervisor-channels supervisor)
        (cons candidate
              (remove old (remove candidate (supervisor-channels supervisor)))))
  candidate)

(declaim (ftype (function (supervisor t t t t) (values string boolean))
                replace-after-stopping))

(defun replace-after-stopping (supervisor name candidate old reason)
  "Stop OLD so CANDIDATE can bind, start CANDIDATE, and restart OLD if CANDIDATE fails."
  (ignore-errors (stop-channel candidate))
  (stop-channel old)
  (multiple-value-bind (live again)
      (progn (start-channel supervisor candidate)
             (wait-for-channel candidate +channel-start-seconds+))
    (if live
        (progn
          (install-channel supervisor candidate old)
          (values
           (format nil "~A is up; the previous instance was stopped so the new one could bind.~@[ The first attempt: ~A~]"
                   name reason)
           t))
        (progn
          (ignore-errors (stop-channel candidate))
          (multiple-value-bind (recovered recovery)
              (progn (start-channel supervisor old)
                     (wait-for-channel old +channel-start-seconds+))
            (if recovered
                (values
                 (format nil "channel ~A refused: ~A; the previous instance is serving again."
                         name again)
                 nil)
                (values
                 (format nil "channel ~A refused: ~A, and the previous instance could not be restarted either: ~A. ~A is down."
                         name again recovery name)
                 nil)))))))

(declaim (ftype (function (supervisor t &key (:replace t)) t)
                supervisor-enable-channel))

(defun supervisor-enable-channel (supervisor name &key replace)
  "Start or replace channel NAME, returning (values report ok-p).
With REPLACE, tries starting the candidate beside OLD first; if that fails due
to an exclusive resource, falls back to REPLACE-AFTER-STOPPING."
  (let* ((old (find-channel supervisor name))
         (factory (supervisor-channel-factory supervisor)))
    (when (and old (enchiridion.channel:channel-live-p old) (not replace))
      (return-from supervisor-enable-channel
        (values (format nil "~A is already up." name) t)))
    (handler-case
        (let ((candidate (if factory (funcall factory name) old))
              (kept nil))
          (cond
            ((null candidate)
             (values (format nil "channel ~A is not implemented yet." name) nil))
            ((and replace (eq candidate old))
             ;; Factory returned the existing instance; cannot replace in place.
             (values (format nil "channel ~A needs a fresh instance to be replaced."
                             name)
                     nil))
            (t
             (unwind-protect
                  (multiple-value-bind (live reason)
                      (progn (start-channel supervisor candidate)
                             (wait-for-channel candidate +channel-start-seconds+))
                    (cond
                      (live
                       (when (and old (not (eq old candidate)))
                         ;; Publish the new channel even if stopping the old one fails.
                         (ignore-errors (stop-channel old)))
                       (install-channel supervisor candidate old)
                       (setf kept t)
                       (values (format nil "~A is up." name) t))
                      ((and replace old (enchiridion.channel:channel-live-p old))
                       (multiple-value-bind (report up)
                           (replace-after-stopping supervisor name candidate old reason)
                         (setf kept up)
                         (values report up)))
                      (t
                       (values (format nil "channel ~A refused: ~A" name reason)
                               nil))))
               (unless kept
                 (ignore-errors (stop-channel candidate)))))))
      (error (condition)
        (values (format nil "channel ~A refused: ~A" name
                        (enchiridion.llm.secrets:scrub (princ-to-string condition)))
                nil)))))

(declaim (ftype (function (supervisor t) t) handle-channels))

(defun handle-channels (supervisor arguments)
  "Handle `channels list|enable N|replace N|disable N`, returning (values report ok-p).
Disabling stops and drops the instance while keeping its name in disabled-channels."
  (let ((action (string-downcase (or (first arguments) "list")))
        (name (second arguments)))
    (cond
      ((string= action "list")
       (let ((off (supervisor-disabled-channels supervisor)))
         (values
          (if (or (supervisor-channels supervisor) off)
              (format nil "~{~A~^, ~}~@[; disabled: ~{~A~^, ~}~]"
                      (mapcar (lambda (channel)
                                (format nil "~A ~A"
                                        (enchiridion.channel:channel-name channel)
                                        (string-downcase
                                         (string (enchiridion.channel:channel-state channel)))))
                              (supervisor-channels supervisor))
                      off)
              "no channels are up.")
          t)))
      ((member action '("enable" "replace" "disable") :test #'string=)
       (cond
         ((null name) (values "which channel?" nil))
         ((member action '("enable" "replace") :test #'string=)
          (supervisor-enable-channel supervisor name :replace (string= action "replace")))
         (t
          (let ((channel (find-channel supervisor name)))
            (if channel
                (let ((lowercase (string-downcase (string name))))
                  (stop-channel channel)
                  (setf (supervisor-channels supervisor)
                        (remove channel (supervisor-channels supervisor))
                        (supervisor-disabled-channels supervisor)
                        (adjoin lowercase (supervisor-disabled-channels supervisor)
                                :test #'string=))
                  (values (format nil "~A is down." name) t))
                ;; Fail on unknown/inactive channel names so typos are reported.
                (values (format nil "no channel called ~A is up." name) nil))))))
      (t (format nil "channels takes list, enable, replace or disable.")))))

(declaim (ftype (function (supervisor t) t) handle-heartbeat))

(defun handle-heartbeat (supervisor arguments)
  "Handle `heartbeat on|off|run`, returning (values report ok-p).
`run` triggers an asynchronous tick (even when schedule is off) so the poll loop
is not blocked; results appear in the status file."
  (let ((action (string-downcase (or (first arguments) "on"))))
    (cond
      ((string= action "on")
       (setf (supervisor-heartbeat-p supervisor) t)
       (if (supervisor-tick-function supervisor)
           (progn (supervisor-ensure-heartbeat-thread supervisor)
                  (values "heartbeat on." t))
           (values "heartbeat on, but no sleep agent is attached to this process." nil)))
      ((string= action "off")
       (setf (supervisor-heartbeat-p supervisor) nil)
       (values "heartbeat off." t))
      ((string= action "run")
       (cond
         ((null (supervisor-tick-function supervisor))
          (values "no sleep agent is attached to this process." nil))
         (t
          ;; Queue another tick if one is already running.
          (setf (supervisor-tick-requested-p supervisor) t)
          (supervisor-ensure-heartbeat-thread supervisor)
          (if (supervisor-tick-running-p supervisor)
              (values "a tick is running; one more is queued and the answer lands in the status file." t)
              (values "heartbeat tick requested; the answer lands in the status file." t)))))
      (t
       (values "heartbeat takes on, off or run." nil)))))

(declaim (ftype (function (supervisor t) t) apply-reload-result))

(defun apply-reload-result (supervisor result)
  "Update SUPERVISOR's generation if RESULT (:ok-p, :generation, :report plist) succeeded; return RESULT."
  (when (and (consp result) (getf result :ok-p))
    (setf (supervisor-generation supervisor) (getf result :generation)))
  result)

(declaim (ftype (function (supervisor) t) default-reload))

(defun default-reload (supervisor)
  "In-process reload hook returning (:ok-p :generation :report). Used by tests; daemons use the broker."
  (let ((result (enchiridion.plugin:load-generation
                 (supervisor-directory supervisor)
                 :generation (1+ (supervisor-generation supervisor)))))
    (list :ok-p (enchiridion.plugin:generation-result-ok-p result)
          :generation (enchiridion.plugin:generation-result-generation result)
          :report (enchiridion.plugin:generation-result-report result))))

(declaim (ftype (function (supervisor) t) supervisor-reload))

(defun supervisor-reload (supervisor)
  "Produce and record a new generation through the reload hook."
  (apply-reload-result
   supervisor
   (funcall (or (supervisor-reload-function supervisor) #'default-reload)
            supervisor)))

(declaim (ftype (function (supervisor t) t) handle-control))

(defun handle-control (supervisor line)
  "Dispatch one control LINE and return (values report ok-p)."
  (let* ((parts (remove-if (lambda (part) (zerop (length part)))
                           (uiop:split-string line :separator " ")))
         (verb (string-downcase (or (first parts) ""))))
    (cond
      ((string= verb "reload")
       (let ((result (supervisor-reload supervisor)))
         (if (getf result :ok-p)
             (values (format nil "reload done, generation ~D."
                             (getf result :generation))
                     t)
             (values (format nil "reload refused: ~A" (getf result :report))
                     nil))))
      ((string= verb "channels")
       (handle-channels supervisor (rest parts)))
      ((string= verb "heartbeat")
       (handle-heartbeat supervisor (rest parts)))
      (t (values (format nil "unknown control request: ~A" line) nil)))))

(declaim (ftype (function (supervisor) integer) supervisor-poll-control))

(declaim (ftype (function (t hash-table t) (or null pathname))
                publish-control-response))

(defun publish-control-response (path table request-id)
  "Write TABLE as the JSON response for the request at PATH and return its path, or NIL on error."
  (let ((response (alexandria:copy-hash-table table)))
    (setf (gethash "request-id" response) request-id)
    (let ((answer (make-pathname :type "response" :defaults path)))
      (handler-case (progn (note-write-ok) (write-json-file answer response))
        (error (condition)
          (note-write-error "a control response" condition)
          nil)))))

(declaim (ftype (function (supervisor function) t) call-with-status-refresh))

(defun call-with-status-refresh (supervisor function)
  "Call FUNCTION while a background thread refreshes the status file every +STATUS-REFRESH-SECONDS+."
  (let* ((done nil)
         (thread (bordeaux-threads:make-thread
                  (lambda ()
                    (let ((next (+ (get-internal-real-time)
                                   (* +status-refresh-seconds+
                                      internal-time-units-per-second))))
                      (supervisor-try-write-status supervisor)
                      ;; Stop refreshing if the supervisor shuts down (DONE may not be set if poll thread is killed).
                      (loop until (or done (not (supervisor-running-p supervisor)))
                            do (sleep 0.02)
                               (when (and (not done)
                                          (>= (get-internal-real-time) next))
                                 (setf next (+ (get-internal-real-time)
                                               (* +status-refresh-seconds+
                                                  internal-time-units-per-second)))
                                 (supervisor-try-write-status supervisor)))))
                  :name "enchiridion status refresh")))
    (unwind-protect (funcall function)
      (setf done t)
      (loop repeat 5
            while (bordeaux-threads:thread-alive-p thread)
            do (sleep 0.01))
      (when (bordeaux-threads:thread-alive-p thread)
        (ignore-errors (bordeaux-threads:destroy-thread thread))))))

(defun read-control-request (path)
  "Return a bounded single request line, or an invalid-request marker."
  (handler-case
      (with-open-file (stream path :external-format :utf-8)
        (let* ((buffer (make-string 4098))
               (size (read-sequence buffer stream))
               (line (string-right-trim '(#\Newline #\Return) (subseq buffer 0 size))))
          (if (or (> size 4097) (> (length line) 4096)
                  (find #\Newline line) (find #\Return line))
              "invalid oversized or multiline request"
              line)))
    (error () "invalid unreadable request")))

(defun supervisor-poll-control (supervisor)
  "Process pending control requests, publish responses, and return the count consumed.
Requests and claims are always deleted after execution so handlers are never replayed."
  (let* ((run (supervisor-run-directory supervisor))
         (requests (progn
                     (clean-control-spool run)
                     (sort (remove-if-not
                            (lambda (path) (equal "request" (pathname-type path)))
                            (uiop:directory-files (control-spool run)))
                           #'< :key (lambda (path)
                                      (or (parse-integer (pathname-name path)
                                                         :junk-allowed t)
                                          most-positive-fixnum)))))
         (count 0))
    (labels ((answer (path report ok-p)
               (incf count)
               (incf (supervisor-handled supervisor))
               (setf (supervisor-report-ok-p supervisor) ok-p
                     (supervisor-report supervisor) (or report ""))
               (when path
                 (unwind-protect
                      (publish-control-response path
                                                (supervisor-status-table supervisor)
                                                (pathname-name path))
                   ;; Always delete request and release claim slot even if response write fails, to prevent replay.
                   (delete-file-if-present path)
                   (delete-file-if-present (control-entry-claim path))))
               (supervisor-try-write-status supervisor))
             (run-line (line path)
               (multiple-value-bind (report ok-p)
                   (call-with-status-refresh
                    supervisor
                    (lambda ()
                      (handler-case (handle-control supervisor line)
                        (error (condition)
                          (values (enchiridion.llm.secrets:scrub
                                   (princ-to-string condition))
                                  nil)))))
                 (answer path report ok-p))))
      (dolist (line (consume-control-lines run)) (run-line line nil))
      (dolist (path requests)
        ;; Skip if another poll already consumed this request.
        (when (probe-file path)
          (if (control-file-older-p path (- (get-universal-time)
                                            +control-pending-seconds+))
              ;; Answer expired requests explicitly so waiting callers do not time out silently.
              (answer path "control request expired in the queue." nil)
              (run-line (read-control-request path) path)))))
    count))

(declaim (ftype (function (supervisor &key (:interval real)) supervisor)
                supervisor-poll-loop))

(defun supervisor-poll-loop (supervisor &key (interval 1))
  "Poll control requests and refresh the status file every INTERVAL seconds until SUPERVISOR stops.
Logs and swallows poll errors so status refreshes continue."
  (loop while (supervisor-running-p supervisor)
        do (handler-case (supervisor-poll-control supervisor)
             (error (condition) (note-write-error "the control poll" condition)))
           (supervisor-try-write-status supervisor)
           (sleep interval))
  supervisor)
