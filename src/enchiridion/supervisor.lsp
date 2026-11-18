;;;; supervisor.lsp --- The process that owns the channels and the run/ files.
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

(defparameter +status-refresh-seconds+ 1
  "How often a slow control request rewrites the status file while it runs.
A reload can take minutes, and the poll loop is the thread inside the handler,
so without a second writer every shell command would read a live process as a
dead one.")

(defparameter +status-report-seconds+ 30
  "How often the same failing write is reported again.
The poll loop reports and carries on, so once a second would bury the log.")

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
  "Write TABLE to PATH as JSON, then rename it into place. Return PATH.

The rename makes a reader safe: it sees the old file or the new one, never half
of either, which matters because another process reads this file.

The staging name carries the process id and a counter: a single shared name
lets two writers interleave, and a slow control request writes alongside the
poll loop."
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
      ;; A failed stringify or rename leaves a staging file behind, and a
      ;; reader listing the directory would have to guess what it is.
      (delete-file-if-present temporary))))

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

(declaim (ftype (function (t) t) status-writes))

(defun status-writes (status)
  "Return the write report the status file carries, or NIL.
A reader that wants the newest answer asks the running process through
SUPERVISOR-WRITE-REPORT: a file cannot describe the failure of its own write."
  (and (hash-table-p status) (gethash "writes" status)))

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
(defparameter +control-retention-seconds+ 60
  "How long an answer or a staging file stays in the spool.")

(defparameter +control-pending-seconds+ 900
  "How long a queued request may wait its turn before it is answered expired.

The poll loop runs one request at a time, and the broker call limit bounds one
at 660 seconds. Fifteen minutes is longer than that, so a queue drains; the
number keeps an abandoned request from holding its slot forever.")

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
  "Remove expired responses and staging files, and abandoned claims.

Pending requests are never removed here: they are the operator's work and
survive a restart. A claim is abandoned only when it is old and no request or
response still names it, which is what a process that died before publishing
leaves behind.

The listing is taken again after the expired files are gone, and the claim
pass reads that listing. Removing a claim because an expired response named it
would release the slot of a request still pending in it."
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
  "How long a shell command waits for its answer by default.

A picked up request answers within a second or so, but one queued behind a
reload waits as long as the reload. A caller that gave up is not a caller that
found no supervisor.")

(declaim (ftype (function (t t) string) control-wait-detail))

(defun control-wait-detail (run path)
  "Return one line about the request at PATH, which has not been answered yet.

A request file that still exists has not been picked up: the poll loop runs one
at a time, so the caller is told how many are ahead. A file that is gone has
been taken and its handler is running."
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
  "Ask the supervisor at RUN for LINE and return three values.

The answer and :ANSWERED; NIL and :NO-SUPERVISOR when no status file is fresh;
NIL, :TIMEOUT and a line about what the request is doing now; or NIL and
:QUEUE-FULL and a line when it could not be queued at all.

A timed out request is not cancelled: the supervisor has already been told, and
the shell that gave up cannot tell a request still queued from one being
handled."
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
            ;; A response another reader took first is already clean, and the
            ;; cleanup must not turn that into an error a caller has to catch.
            (delete-file-if-present response)
            (delete-file-if-present (control-entry-claim path))))
        (when (>= (get-internal-real-time) deadline)
          (return (values nil :timeout (control-wait-detail run path))))
        (sleep 0.05)))))

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

ENABLED is true for every channel object a supervisor holds, because presence in
that list is the statement: a channel that is off is stopped and taken out, and
one that is configured and off has no object and reaches a reader as a
DISABLED-CHANNEL-ROW.

Reading the configuration here answered for the wrong thing: a channel started
by a --channel flag is wanted here and disabled in the configuration, so its row
called it unwanted."
  (let ((row (make-hash-table :test #'equal)))
    (setf (gethash "name" row) (enchiridion.channel:channel-name channel))
    (setf (gethash "state" row)
          (string-downcase (string (enchiridion.channel:channel-state channel))))
    (setf (gethash "enabled" row) t)
    row))

(declaim (ftype (function (supervisor) list) configured-channel-names))

(defun configured-channel-names (supervisor)
  "Return the channel names the configuration has an entry for, lowercase.

The shipped section is read as well as the supervisor's own, because it decides
a channel's default: a config.lsp that mentions only the webhook still ships a
disabled Fluxer."
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
  "Return the row for a channel this process is not running on purpose.

The state is disabled and not stopped, so a reader can tell a surface the
operator turned off from one that crashed and is being retried. ENABLED is
false."
  (let ((row (make-hash-table :test #'equal)))
    (setf (gethash "name" row) name)
    (setf (gethash "state" row) "disabled")
    (setf (gethash "enabled" row) nil)
    row))

(declaim (ftype (function (supervisor) vector) supervisor-channel-rows))

(defun supervisor-channel-rows (supervisor)
  "Return every channel this process knows about, as the status file's rows.

A running channel is one row. A configured or operator-disabled channel is a
row too: a reader can then tell a surface that was never configured from one
that is off on purpose.

Rows have the same shape as CHANNEL-ROW's."
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
  "Return T when a heartbeat thread is running.

ENABLED says the operator wants a schedule; this says one exists. A thread that
stopped while the flag stayed true is a schedule nobody runs."
  (let ((thread (supervisor-heartbeat-thread supervisor)))
    (and thread (bordeaux-threads:thread-alive-p thread))))

(defvar *status-error-report* nil
  "The last write failure as (message . universal-time), or NIL.
It is what keeps the same line out of the log once a second.")

(defvar *status-write-failure* nil
  "The last write failure as (message . universal-time) since a write last landed.
NIL means the writes are landing. The next working write clears it, so one
transient failure does not colour the process.")

(declaim (ftype (function (t t) null) note-write-error))

(defun note-write-error (what condition)
  "Report that WHAT failed once per +STATUS-REPORT-SECONDS+.

A supervisor whose run directory became unwritable still serves turns, so the
failure is reported and swallowed. The log and the write report are where the
operator sees it."
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
  "Return the last write as the JSON object a health reader takes.

\"ok\" is false while writes fail, \"report\" is the last failure, and \"age\" is
its age in seconds. It describes the write before the one carrying it, because a
status file cannot report the failure of its own write."
  (let ((row (make-hash-table :test #'equal))
        (failure *status-write-failure*))
    (setf (gethash "ok" row) (null failure))
    (setf (gethash "report" row) (or (car failure) ""))
    (setf (gethash "age" row)
          (if failure (max 0 (- (get-universal-time) (cdr failure))) 0))
    row))

(declaim (ftype (function (supervisor) hash-table) supervisor-status-table))

(defun supervisor-status-table (supervisor)
  "Return the status file's contents as a table, without writing them.

Every field a `health` reader needs is here: whether the process runs, the
generation, the channels, the bootstrap line, and the time. Nothing secret is
written, because the file is world readable.

The table and the answer a control request gets come from one place. A response
built by reading the file back would be missing whenever the write failed."
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
            ;; ENABLED answers whether unattended work can happen here: a
            ;; schedule with no hook attached is off, not on.
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
          ;; A vector and not a list: an empty list writes as JSON false, and
          ;; a reader that expects a list of channels would then have to treat
          ;; false and [] as the same thing. The same builder answers the
          ;; webhook's health route, so the two views cannot drift.
          (supervisor-channel-rows supervisor))
    table))

(declaim (ftype (function (supervisor) hash-table) supervisor-write-status))

(defun supervisor-write-status (supervisor)
  "Write the status file and return the table it wrote.

No lock spans the write: each writer stages a file of its own name and renames
it into place, so a reader sees one complete table and the last writer wins. A
lock held while the poll thread is destroyed would stop the last write for
good."
  (let ((table (supervisor-status-table supervisor)))
    (write-json-file (status-file (supervisor-run-directory supervisor)) table)
    table))

(declaim (ftype (function (supervisor &optional t) t) supervisor-try-write-status))

(defun supervisor-try-write-status (supervisor &optional (what "the status file"))
  "Write the status file and return its table, or NIL after reporting a failure.

A run directory that filled up or vanished is a reason to report the failure
and carry on: stopping the loop leaves the process serving while every shell
command reads it as dead."
  (handler-case (progn (note-write-ok) (supervisor-write-status supervisor))
    (error (condition) (note-write-error what condition) nil)))

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

(defparameter +shutdown-budget-seconds+ 20
  "How long SUPERVISOR-STOP may take before it leaves the rest unstopped.

Compose allows thirty seconds between SIGTERM and SIGKILL, and the process still
has to close its store, remove the broker socket and leave. Everything STOP
waits for shares this deadline: a stuck tick plus one draining webhook could
outlast the grace period and be killed before the last status file. A spent
budget is reported and the shutdown goes on.")

(defparameter +tick-drain-seconds+ 10
  "The most of the shutdown budget a heartbeat tick may use before it is stopped.")

(defparameter +channel-stop-seconds+ 8
  "The most of the shutdown budget one channel stop may use.

A channel's stop can wait for a turn in flight. Eight seconds covers the
webhook's six second drain, which takes its own deadline for the acceptor and
the running turn together, and leaves room for the tick's share and a second
channel.")

(declaim (ftype (function (real) real) remaining-seconds))

(defun remaining-seconds (deadline)
  "Return how many seconds are left before DEADLINE, an internal real time."
  (max 0 (/ (- deadline (get-internal-real-time))
            internal-time-units-per-second)))

(declaim (ftype (function (t real) null) note-stop-timeout))

(defun note-stop-timeout (channel seconds)
  "Say that CHANNEL did not stop within SECONDS and mark it stopped.

STOP-CHANNEL destroys the channel's thread on the way out of a cut off stop, so
the last status file would otherwise report a channel no thread serves."
  (format *error-output*
          "~&enchiridion: channel ~A did not stop within ~,1F second~:P of the shutdown.~%"
          (enchiridion.channel:channel-name channel) seconds)
  (finish-output *error-output*)
  (setf (enchiridion.channel:channel-live-p channel) nil
        (enchiridion.channel:channel-state channel) :stopped)
  nil)

(declaim (ftype (function (supervisor) supervisor) supervisor-stop))

(defun supervisor-stop (supervisor)
  "Stop every channel, clear the running flag, and write the last status.
Return SUPERVISOR.

The heartbeat thread gets its share of +SHUTDOWN-BUDGET-SECONDS+ to finish the
tick in flight, because the store closes after this returns and a thread killed
mid-write would leave it locked. Every channel then gets what is left, at most
+CHANNEL-STOP-SECONDS+ each, and the last status file is written whatever
happened."
  (setf (supervisor-running-p supervisor) nil)
  (let ((deadline (+ (get-internal-real-time)
                     (* +shutdown-budget-seconds+ internal-time-units-per-second))))
    (let ((beat (supervisor-heartbeat-thread supervisor)))
      (when (and beat (bordeaux-threads:thread-alive-p beat))
        ;; The loop sees the cleared flag within a second, or when the tick in
        ;; flight returns. Killing it mid-tick can unwind out of an SQLite call
        ;; with a transaction open, so it is the last resort, not the first.
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
          ;; A killed tick leaves a flag describing a thread that is gone; a
          ;; status file would report a dead tick as a slow one.
          (setf (supervisor-tick-running-p supervisor) nil)))
      (setf (supervisor-heartbeat-thread supervisor) nil))
    (dolist (channel (supervisor-channels supervisor))
      ;; A stopped channel holds nothing to release. A signal handler and an
      ;; unwind-protect both call this, and asking again turned a quiet second
      ;; call into a timeout report.
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

(declaim (ftype (function (t real) (values boolean t)) wait-for-channel))

(defun wait-for-channel (channel seconds)
  "Wait up to SECONDS for CHANNEL to report itself live and return two values:
whether it did, and why it did not.

A channel reports live from its own thread, so the state is waited for rather
than read once: a fresh instance is :starting until its bind returns."
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
  "Make CANDIDATE the channel of its own name on SUPERVISOR, dropping OLD.

The name stops being disabled: a channel that runs is not off."
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
  "Replace the running OLD with CANDIDATE, which could not start beside it.

OLD is stopped so CANDIDATE can take what it holds, CANDIDATE is started again,
and OLD is started again when that fails: a failed replacement leaves the
surface it was replacing serving."
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
  "Construct and activate NAME, and return a report and whether it is up.

A running channel is left alone unless REPLACE is true. A replacement is tried
beside the running one first, and only a candidate that reports live takes its
place.

A channel that owns an exclusive resource cannot start beside its predecessor,
so a candidate that fails while a live old channel exists gets one more start
after that channel is stopped, and the old one is started again when that fails
too."
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
             ;; The factory handed back the running channel: there is nothing
             ;; to start beside it and nothing to swap in.
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
                         ;; The new surface is live and is published even when
                         ;; the old one fails to stop cleanly; one broken stop
                         ;; must not leave the process with no channel at all.
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
  "Act on `channels list|enable N|replace N|disable N` and return a report
and whether the request succeeded.

A disable stops the channel and forgets its instance. The name stays so the
status file can say the surface exists and is off, and a later enable builds a
fresh one through the factory."
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
                ;; Success for a name nothing runs lets a typo read as a
                ;; stopped channel, and the operator cannot tell the two apart.
                (values (format nil "no channel called ~A is up." name) nil))))))
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

(declaim (ftype (function (t hash-table t) (or null pathname))
                publish-control-response))

(defun publish-control-response (path table request-id)
  "Write the answer for the request at PATH and return its path, or NIL.

The answer is the table the supervisor holds, not a status file read back: a
failed status write would otherwise leave the shell waiting for an answer that
was known, and another request may have written the file in between."
  (let ((response (alexandria:copy-hash-table table)))
    (setf (gethash "request-id" response) request-id)
    (let ((answer (make-pathname :type "response" :defaults path)))
      (handler-case (progn (note-write-ok) (write-json-file answer response))
        (error (condition)
          (note-write-error "a control response" condition)
          nil)))))

(declaim (ftype (function (supervisor function) t) call-with-status-refresh))

(defun call-with-status-refresh (supervisor function)
  "Call FUNCTION, keeping the status file fresh for as long as it takes.

A reload can run for minutes while the poll loop, the thread it runs on, writes
nothing, and the file ages out. A second thread rewrites the same table, and is
stopped before the caller publishes its answer."
  (let* ((done nil)
         (thread (bordeaux-threads:make-thread
                  (lambda ()
                    (let ((next (+ (get-internal-real-time)
                                   (* +status-refresh-seconds+
                                      internal-time-units-per-second))))
                      (supervisor-try-write-status supervisor)
                      ;; The poll thread that owns this call can be destroyed
                      ;; at shutdown and DONE is never set. A writer that
                      ;; outlived its supervisor would rewrite a status file for
                      ;; a process that is leaving, so the flag ends the loop.
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
  "Handle each published request, publish its own answer, and return how many
requests were consumed.

An answer is published before the status file is rewritten and before the
request is removed. The request and its slot are released whatever happened:
running a reload twice is worse than an uncertain reply."
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
                   ;; The handler has run, so the request is consumed even when
                   ;; its answer could not be written or this thread was
                   ;; interrupted. Replaying a reload is worse than an answer
                   ;; that never arrived.
                   ;;
                   ;; The claim is the slot QUEUE-CONTROL took; releasing it
                   ;; lets the next request take the slot at once.
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
        ;; Another poll may have consumed the file after the directory listing.
        ;; A vanished request needs no answer, and inventing one would overwrite
        ;; the response the other poll already wrote.
        (when (probe-file path)
          (if (control-file-older-p path (- (get-universal-time)
                                            +control-pending-seconds+))
              ;; An expired request still gets an answer: a shell may be
              ;; waiting on it, and silence reads as a dead supervisor. The
              ;; horizon is the queue's, so a request has to outlast a reload
              ;; before it gets here.
              (answer path "control request expired in the queue." nil)
              (run-line (read-control-request path) path)))))
    count))

(declaim (ftype (function (supervisor &key (:interval real)) supervisor)
                supervisor-poll-loop))

(defun supervisor-poll-loop (supervisor &key (interval 1))
  "Poll the control queue and rewrite the status file until SUPERVISOR stops.
Writing the status on every tick is what keeps it fresh, which is how a reader
tells a running supervisor from a file a dead one left.

A failed pass is reported and the loop goes on. The loop is the only thing that
answers control requests and keeps the file fresh, so one bad spool entry must
not leave a running process reported as dead."
  (loop while (supervisor-running-p supervisor)
        do (handler-case (supervisor-poll-control supervisor)
             (error (condition) (note-write-error "the control poll" condition)))
           (supervisor-try-write-status supervisor)
           (sleep interval))
  supervisor)
