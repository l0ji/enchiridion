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
  "Return the channel rows the status file holds as a list, or NIL.

JZON parses a JSON array into a vector, and every reader here wants a list, so
the coercion lives in the one accessor rather than in each caller."
  (let ((rows (and (hash-table-p status) (gethash "channels" status))))
    (cond
      ((null rows) nil)
      ((listp rows) rows)
      ((vectorp rows) (coerce rows 'list))
      (t nil))))

(declaim (ftype (function (t) t) status-handled))

(defun status-handled (status)
  "Return how many control requests the supervisor has answered, or NIL.

A counter and not a timestamp: the poll loop rewrites the status file every
second to stay fresh, so a changed timestamp says nothing about whether a
particular request was handled."
  (and (hash-table-p status) (gethash "handled" status)))

(declaim (ftype (function (t) t) status-bootstrap))

(defun status-bootstrap (status)
  "Return the one line bootstrap state the status file holds, or NIL."
  (and (hash-table-p status) (gethash "bootstrap" status)))

(declaim (ftype (function (t) t) status-report))

(defun status-report (status)
  "Return the last control report the status file holds, or NIL. A shell
command that only appended a line learns what happened by reading this."
  (and (hash-table-p status) (gethash "report" status)))

(declaim (ftype (function (t) t) status-report-ok-p))

(defun status-report-ok-p (status)
  "Return T when the last control request was answered, NIL when it was
refused or when the status file answers nothing.

A reload that refused a generation is the refusal this exists for: the operator
script that asked has to be able to tell it from a reload that landed."
  (and (hash-table-p status) (gethash "report-ok" status)))

(declaim (ftype (function (t) t) status-heartbeat))

(defun status-heartbeat (status)
  "Return the heartbeat object the status file holds, or NIL.
A reader that wants one field asks for it here rather than walking the JSON:
the shape is written in SUPERVISOR-WRITE-STATUS and read in one place."
  (and (hash-table-p status) (gethash "heartbeat" status)))

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

(defparameter *control-id-lock* (bordeaux-threads:make-lock "control ids"))
(defvar *control-id* 0)
(defparameter +control-retention-seconds+ 60)
(defparameter +control-file-limit+ 256)

(defun control-spool (run)
  "Return the directory that holds request, response, and claim files."
  (merge-pathnames "control/" (uiop:ensure-directory-pathname run)))


(defun delete-file-if-present (path)
  "Delete PATH when it still exists. A vanished entry is already clean."
  (when (probe-file path)
    (ignore-errors (delete-file path))))

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
  "Remove expired responses and staging files, and abandoned claims.
Pending requests are never removed here: they are the operator's work and
survive a restart. A claim is abandoned only when it is old and no request or
response still names it, which is what a process that died before publishing
leaves behind."
  (ensure-directories-exist (control-spool run))
  (let* ((paths (uiop:directory-files (control-spool run)))
         (cutoff (- (get-universal-time) +control-retention-seconds+)))
    (dolist (path paths)
      (when (and (member (pathname-type path) '("new" "response") :test #'equal)
                 (control-file-older-p path cutoff))
        (when (probe-file path)
          (delete-file-if-present path)
          (delete-file-if-present (control-entry-claim path)))))
    (dolist (path paths)
      (when (and (equal "claim" (pathname-type path))
                 (control-file-older-p path cutoff)
                 (not (control-entry-live-p path paths)))
        (delete-file-if-present path)))
    (dolist (path paths)
      (unless (member (pathname-type path) '("request" "response" "claim" "new")
                      :test #'equal)
        (when (control-file-older-p path cutoff)
          (delete-file-if-present path))))))

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

(declaim (ftype (function (string &key (:run t) (:wait real)) t) request-control))

(defun request-control (line &key (run (enchiridion:run-directory)) (wait 5))
  "Return this request's response, or NIL after WAIT seconds."
  (check-type wait (real 0 30))
  (unless (status-fresh-p (read-status run))
    (return-from request-control nil))
  (let* ((path (queue-control line :run run))
         (response (make-pathname :type "response" :defaults path))
         (deadline (+ (get-internal-real-time) (* wait internal-time-units-per-second))))
    (loop
      (when (probe-file response)
        (unwind-protect
             (return (com.inuoe.jzon:parse
                      (uiop:read-file-string response :external-format :utf-8)))
          (delete-file response)
          (delete-file-if-present (control-entry-claim path))))
      (when (>= (get-internal-real-time) deadline) (return nil))
      (sleep 0.05))))

;;;; The supervisor.

;; directory is the agent directory, run-directory is where the two files
;; live, channels is the list of live channel objects, and reload-function is
;; the hook that produces a new generation. The supervisor itself never loads
;; agent code, so a daemon passes a function that asks the broker.
;;
;; tick-function is the second such hook: the heartbeat's work lives in the
;; kernel, and this file loads before it, so the caller supplies the function
;; rather than the supervisor reaching forward for it. last-tick is measured
;; from the end of a tick, so a pass that takes longer than the interval runs
;; again when it finishes rather than piling up behind itself.
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
  "Return a SUPERVISOR. Nothing starts until SUPERVISOR-START.

HEARTBEAT-INTERVAL is a positive whole number of seconds; anything else is the
fifteen minutes the shipped configuration names, because an interval of zero
is a tick loop and a string is a mis-typed configuration key."
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
  "Return CHANNEL as the JSON row the status file carries.

ENABLED is true when the configuration enables the channel or when this process
is running it. A channel started by a --channel flag is enabled in the process
that is serving, and a row that called it disabled while its state said live
would be the status file contradicting itself."
  (let ((row (make-hash-table :test #'equal))
        (name (enchiridion.channel:channel-name channel)))
    (setf (gethash "name" row) name)
    (setf (gethash "state" row)
          (string-downcase (string (enchiridion.channel:channel-state channel))))
    (setf (gethash "enabled" row)
          (or (not (null (enchiridion:channel-enabled-p name)))
              (not (null (enchiridion.channel:channel-live-p channel)))))
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
    ;; The report strings come from control lines and from the tick, and both
    ;; can quote a failure that mentions a token. The status file is world
    ;; readable, so it is scrubbed on the way out like every other text path.
    (setf (gethash "report" table)
          (enchiridion.llm.secrets:scrub (supervisor-report supervisor)))
    (setf (gethash "report-ok" table) (supervisor-report-ok-p supervisor))
    (setf (gethash "handled" table) (supervisor-handled supervisor))
    (setf (gethash "heartbeat" table)
          (let ((beat (make-hash-table :test #'equal)))
            (setf (gethash "enabled" beat) (supervisor-heartbeat-p supervisor))
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
    (setf (gethash "channels" table)
          ;; A vector and not a list: an empty list writes as JSON false, and
          ;; a reader that expects a list of channels would then have to treat
          ;; false and [] as the same thing.
          (coerce (mapcar #'channel-row (supervisor-channels supervisor)) 'vector))
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
  "Start the heartbeat thread when a tick hook is attached and none runs.

One place starts it, so `heartbeat on` can start a schedule that the
configuration had disabled at startup: without that, an operator who begins
with :sleep :enabled nil can never turn unattended work on, and the command
that claims to have done it is lying.

LAST-TICK is set first, so the first tick waits one interval rather than firing
at t=0. A pass immediately after startup competes with the first operator turn
and spends tokens before anyone asked for anything; `heartbeat run` still forces
one at once."
  (when (and (supervisor-tick-function supervisor)
             (supervisor-running-p supervisor)
             (null (supervisor-heartbeat-thread supervisor)))
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
  ;; The heartbeat runs on its own thread and never on the poll thread: a tick
  ;; is one or more model calls, and a poll loop held inside one stops
  ;; rewriting the status file. The status file is what every shell command
  ;; reads to decide whether a supervisor is up, and it goes stale in ten
  ;; seconds, so a tick on that thread would make the agent look dead while it
  ;; worked.
  (when (supervisor-heartbeat-p supervisor)
    (supervisor-ensure-heartbeat-thread supervisor))
  (supervisor-write-status supervisor)
  supervisor)

(defparameter +tick-drain-seconds+ 30
  "How long SUPERVISOR-STOP waits for a heartbeat tick to finish.")

(declaim (ftype (function (supervisor) supervisor) supervisor-stop))

(defun supervisor-stop (supervisor)
  "Stop every channel, clear the running flag, and write the last status.
Return SUPERVISOR.

The heartbeat thread is given +TICK-DRAIN-SECONDS+ to finish the tick in
flight and leave, because the store closes after this returns and a thread
killed mid-write would leave it locked. A tick that outlasts the drain is
stopped and reported; its task stays claimed as running and the next process
marks it failed."
  (setf (supervisor-running-p supervisor) nil)
  (let ((beat (supervisor-heartbeat-thread supervisor)))
    (when (and beat (bordeaux-threads:thread-alive-p beat))
      ;; The loop sees the cleared flag within a second, or when the tick in
      ;; flight returns. Killing it mid-tick can unwind out of an SQLite call
      ;; with a transaction open, so it is the last resort, not the first.
      (let ((deadline (+ (get-internal-real-time)
                         (* +tick-drain-seconds+ internal-time-units-per-second))))
        (loop while (and (bordeaux-threads:thread-alive-p beat)
                         (< (get-internal-real-time) deadline))
              do (sleep 0.05)))
      (when (bordeaux-threads:thread-alive-p beat)
        (format *error-output*
                "~&enchiridion: a heartbeat tick outlasted the ~D second drain and was stopped.~%"
                +tick-drain-seconds+)
        (finish-output *error-output*)
        (ignore-errors (bordeaux-threads:destroy-thread beat))))
    (setf (supervisor-heartbeat-thread supervisor) nil))
  (dolist (channel (supervisor-channels supervisor))
    (ignore-errors (stop-channel channel)))
  (supervisor-write-status supervisor)
  supervisor)

;;;; The heartbeat.

(declaim (ftype (function (supervisor) boolean) supervisor-heartbeat-due-p))

(defun supervisor-heartbeat-due-p (supervisor)
  "Return T when a tick should run now.
A request runs one whatever the schedule says: the operator asked for it. The
schedule measures from the end of the last tick, so a pass that takes longer
than the interval is never overlapped by the next one."
  (or (supervisor-tick-requested-p supervisor)
      (and (supervisor-heartbeat-p supervisor)
           (>= (- (get-universal-time) (supervisor-last-tick supervisor))
               (supervisor-heartbeat-interval supervisor)))))

(declaim (ftype (function (supervisor) t) supervisor-tick))

(defun supervisor-tick (supervisor)
  "Run one tick through the hook and record what it said. Return its plist.

A tick never signals. The thread that runs it is the whole scheduler for
unattended work, and a scheduler that dies on one bad pass is a process that
quietly stops doing any."
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
  "Run a tick whenever one is due, until SUPERVISOR stops.
The loop wakes once a second, which is free, and is the same cadence the poll
loop uses: a shutdown and a forced tick are both noticed within a second."
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
  "Return the channel SUPERVISOR calls NAME, or NIL. NAME matches a string or
a keyword, because both spellings reach here."
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

(defun supervisor-enable-channel (supervisor name &key replace)
  "Construct and activate NAME, retaining the old channel on failure.

A live channel is left alone unless REPLACE is true. A replacement starts a
fresh candidate, waits for it to report :live, and only then stops and removes
the old one."
  (let* ((old (find-channel supervisor name))
         (factory (supervisor-channel-factory supervisor)))
    (when (and old (enchiridion.channel:channel-live-p old) (not replace))
      (return-from supervisor-enable-channel
        (values (format nil "~A is already up." name) t)))
    (handler-case
        (let ((candidate (if factory (funcall factory name) old)))
          (unless candidate
            (return-from supervisor-enable-channel
              (values (format nil "channel ~A is not implemented yet." name) nil)))
          (when (and replace (eq candidate old))
            (error "Replacement requires a fresh channel."))
          (unwind-protect
               (progn
                 (start-channel supervisor candidate)
                 (let ((deadline (+ (get-internal-real-time)
                                    (* +channel-start-seconds+
                                       internal-time-units-per-second))))
                   (loop until (or (enchiridion.channel:channel-live-p candidate)
                                   (member (enchiridion.channel:channel-state candidate)
                                           '(:failed :unavailable))
                                   (>= (get-internal-real-time) deadline))
                         do (sleep 0.01)))
                 (unless (enchiridion.channel:channel-live-p candidate)
                   (error "Channel ~A did not become live: ~A" name
                          (or (enchiridion.channel::channel-start-error candidate)
                              (enchiridion.channel:channel-state candidate))))
                 (when (and old (not (eq old candidate)))
                   ;; The new surface is live and must be published even when
                   ;; the old one fails to stop cleanly; otherwise one broken
                   ;; stop leaves the process with no channel at all.
                   (ignore-errors (stop-channel old)))
                 (setf (supervisor-channels supervisor)
                       (cons candidate (remove old (supervisor-channels supervisor))))
                 (setf candidate nil)
                 (values (format nil "~A is up." name) t))
            (when candidate (ignore-errors (stop-channel candidate)))))
      (error (condition)
        (values (format nil "channel ~A refused: ~A" name condition) nil)))))

(declaim (ftype (function (supervisor t) t) handle-channels))

(defun handle-channels (supervisor arguments)
  "Act on `channels list|enable N|replace N|disable N` and return a report
and whether the request succeeded."
  (let ((action (string-downcase (or (first arguments) "list")))
        (name (second arguments)))
    (cond
      ((string= action "list")
       (values
        (if (supervisor-channels supervisor)
           (format nil "~{~A~^, ~}"
                   (mapcar (lambda (channel)
                             (format nil "~A ~A"
                                     (enchiridion.channel:channel-name channel)
                                     (string-downcase
                                      (string (enchiridion.channel:channel-state channel)))))
                           (supervisor-channels supervisor)))
           "no channels are up.") t))
      ((member action '("enable" "replace" "disable") :test #'string=)
       (cond
         ((null name) (values "which channel?" nil))
         ((member action '("enable" "replace") :test #'string=)
          (supervisor-enable-channel supervisor name :replace (string= action "replace")))
         (t
          (let ((channel (find-channel supervisor name)))
            (when channel (stop-channel channel))
            (values (format nil "~A is down." name) t)))))
      (t (format nil "channels takes list, enable, replace or disable.")))))

(declaim (ftype (function (supervisor t) t) handle-heartbeat))

(defun handle-heartbeat (supervisor arguments)
  "Act on `heartbeat on|off|run` and return two values: a report, and whether
the request was answered.

`run` asks for a tick and answers at once. Waiting for the tick here would hold
the control poll inside a sleep pass, and the poll loop is what keeps the
status file fresh: a shell command that asked for a tick would then find a
supervisor that looks dead. The outcome lands in the status file within a
second of the tick finishing, which is what `health` prints.

`off` stops the schedule and not the operator: `run` still ticks, because the
request was explicit."
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
          ;; A request during a tick is queued rather than dropped: the
          ;; operator asked, and a request that vanishes is worse than one that
          ;; runs a minute later.
          (setf (supervisor-tick-requested-p supervisor) t)
          (supervisor-ensure-heartbeat-thread supervisor)
          (if (supervisor-tick-running-p supervisor)
              (values "a tick is running; one more is queued and the answer lands in the status file." t)
              (values "heartbeat tick requested; the answer lands in the status file." t)))))
      (t
       (values "heartbeat takes on, off or run." nil)))))

(declaim (ftype (function (supervisor t) t) apply-reload-result))

(defun apply-reload-result (supervisor result)
  "Record the generation in RESULT on SUPERVISOR when it loaded, and return
RESULT. RESULT is a plist of :OK-P, :GENERATION and :REPORT.

A plist rather than the loader's own struct, because the reload hook may be a
broker round trip in another process and a struct does not cross a socket. A
failed generation changes nothing: the last good code keeps serving, and the
report goes back to whoever asked. That is the whole promise of the loader."
  (when (and (consp result) (getf result :ok-p))
    (setf (supervisor-generation supervisor) (getf result :generation)))
  result)

(declaim (ftype (function (supervisor) t) default-reload))

(defun default-reload (supervisor)
  "Load a new generation in this process and return a plist of :OK-P,
:GENERATION and :REPORT.

Tests use this; a daemon passes its own RELOAD-FUNCTION so the supervisor
never loads agent code itself."
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
  "Act on one control LINE and return two values: a one line report, and
whether the request was answered.

A reload that refused a generation is a report and not a success, and the shell
command that asked has to be able to tell the two apart: an operator script
that reloads and continues deserves a non-zero status from a refusal."
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
  "Handle each published request and write its own response."
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
    (labels ((handle (line)
               (multiple-value-bind (report ok-p)
                   (handler-case (handle-control supervisor line)
                     (error (condition) (values (princ-to-string condition) nil)))
                 (incf count)
                 (incf (supervisor-handled supervisor))
                 (setf (supervisor-report-ok-p supervisor) ok-p
                       (supervisor-report supervisor) (or report ""))
                 (supervisor-write-status supervisor))))
      (dolist (line (consume-control-lines run)) (handle line))
      (dolist (path requests)
        ;; Another poll may have consumed the file after the directory listing.
        ;; A vanished request needs no answer, and inventing one would overwrite
        ;; the response the other poll already wrote.
        (when (probe-file path)
          (if (control-file-older-p path (- (get-universal-time)
                                            +control-retention-seconds+))
              (progn
                (incf count)
                (incf (supervisor-handled supervisor))
                (setf (supervisor-report supervisor) "control request expired."
                      (supervisor-report-ok-p supervisor) nil)
                (supervisor-write-status supervisor))
              (handle (read-control-request path)))
          (let ((response (read-status run)))
            (when (hash-table-p response)
              (setf (gethash "request-id" response) (pathname-name path))
              (write-json-file (make-pathname :type "response" :defaults path)
                               response)))
          (delete-file-if-present path))))
    count))

(declaim (ftype (function (supervisor &key (:interval real)) supervisor)
                supervisor-poll-loop))

(defun supervisor-poll-loop (supervisor &key (interval 1))
  "Poll the control queue and rewrite the status file until SUPERVISOR stops.
Writing the status on every tick is what keeps it fresh, which is how a reader
tells a running supervisor from a file a dead one left."
  (loop while (supervisor-running-p supervisor)
        do (supervisor-poll-control supervisor)
           (supervisor-write-status supervisor)
           (sleep interval))
  supervisor)
