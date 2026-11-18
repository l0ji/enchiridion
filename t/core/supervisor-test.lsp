;;;; supervisor-test.lsp --- The control file, the status file, and channels.
;;;;
;;;; The two files are the whole mechanism that lets a one-shot shell command
;;;; talk to a process that is already up. The properties under test are the
;;;; ones a reader depends on: a stale or stopped supervisor is never reported
;;;; as live, a request is consumed exactly once, and the status file never
;;;; exists in half a state.

(defpackage #:enchiridion-supervisor-test
  (:use #:cl)
  (:import-from #:rove #:deftest #:ok #:ng #:testing)
  (:export #:run))

(in-package #:enchiridion-supervisor-test)

;;;; A channel that starts and stops at once, so the thread logic can be
;;;; exercised without a terminal.

(enchiridion.channel:define-channel stub-channel)

(defmethod enchiridion.channel:channel-start ((channel stub-channel) &key config)
  (declare (ignore config))
  (setf (enchiridion.channel:channel-live-p channel) t)
  (setf (enchiridion.channel:channel-state channel) :live)
  nil)

(defmethod enchiridion.channel:channel-stop ((channel stub-channel))
  (setf (enchiridion.channel:channel-live-p channel) nil)
  (setf (enchiridion.channel:channel-state channel) :stopped)
  nil)

(defmethod enchiridion.channel:channel-send ((channel stub-channel) target text
                                              &key reply-to)
  (declare (ignore channel target reply-to))
  text)

(defmethod enchiridion.channel:channel-status ((channel stub-channel))
  (enchiridion.channel:channel-state channel))

(defun scratch-directory ()
  "Return a fresh directory under the directory this build may write."
  (uiop:ensure-directory-pathname
   (merge-pathnames
    (format nil "enchiridion-supervisor-test-~D/" (random most-positive-fixnum))
    (uiop:ensure-directory-pathname *default-pathname-defaults*))))

(defmacro with-scratch-supervisor ((supervisor &key (channels nil)
                                                (reload-function nil)
                                                (tick-function nil))
                                   &body body)
  "Bind SUPERVISOR to a started supervisor in a scratch directory, then stop it
and remove the directory. A failing test must not leave a thread behind."
  `(let* ((directory (scratch-directory))
          (run (merge-pathnames "run/" directory))
          (,supervisor (enchiridion.supervisor:make-supervisor
                        :directory (namestring (merge-pathnames "agents/default/" directory))
                        :run-directory (namestring run)
                        :generation 3
                        :bootstrap-line "bootstrap step 0 of 8"
                        :reload-function ,reload-function
                        :tick-function ,tick-function
                        :heartbeat-p nil
                        :channels ,channels)))
     (unwind-protect
          (progn
            (enchiridion.supervisor:supervisor-start ,supervisor)
            ,@body)
       (ignore-errors (enchiridion.supervisor:supervisor-stop ,supervisor))
       (uiop:delete-directory-tree directory
                                   :validate t
                                   :if-does-not-exist :ignore))))

(deftest a-supervisor-that-never-ran-is-not-live ()
  (let ((directory (scratch-directory)))
    (unwind-protect
         (let ((run (namestring (merge-pathnames "run/" directory))))
           (testing "there is no status file and nothing is fresh"
             (ok (null (enchiridion.supervisor:read-status run)))
             (ok (null (enchiridion.supervisor:status-fresh-p
                        (enchiridion.supervisor:read-status run))))
             (ok (null (enchiridion.supervisor:status-generation
                        (enchiridion.supervisor:read-status run)))))
           (testing "a request nobody answers comes back NIL and starts nothing"
             (ok (null (enchiridion.supervisor:request-control
                        "reload" :run run :wait 0.2)))
             (ok (null (enchiridion.supervisor:read-status run)))))
      (uiop:delete-directory-tree directory
                                  :validate t
                                  :if-does-not-exist :ignore))))

(deftest the-status-file-round-trips ()
  (with-scratch-supervisor (supervisor)
    (let* ((run (enchiridion.supervisor:supervisor-run-directory supervisor))
           (status (enchiridion.supervisor:read-status run)))
      (testing "a running supervisor is live and names its generation"
        (ok (enchiridion.supervisor:status-fresh-p status))
        (ok (= 3 (enchiridion.supervisor:status-generation status)))
        (ok (integerp (enchiridion.supervisor:status-pid status)))
        (ok (string= "bootstrap step 0 of 8"
                     (enchiridion.supervisor:status-bootstrap status))))
      (testing "the write is atomic, so no half file is ever left behind"
        (ok (null (probe-file (merge-pathnames "enchiridion.status.new" run))))
        (ok (null (remove-if-not (lambda (path) (equal "new" (pathname-type path)))
                                 (uiop:directory-files run)))
            "and no staging file of the new name either")))
    (testing "a stopped supervisor is not live, even for a moment"
      (enchiridion.supervisor:supervisor-stop supervisor)
      (ok (null (enchiridion.supervisor:status-fresh-p
                 (enchiridion.supervisor:read-status
                  (enchiridion.supervisor:supervisor-run-directory supervisor))))))))

(deftest a-control-request-is-consumed-once ()
  (with-scratch-supervisor (supervisor
                            :channels (list (make-stub-channel))
                            :tick-function (lambda (supervisor)
                                             (declare (ignore supervisor))
                                             (list :ok-p t :report "ticked")))
    (let ((run (enchiridion.supervisor:supervisor-run-directory supervisor)))
      (testing "the channel is known by name"
        (ok (enchiridion.supervisor:find-channel supervisor "stub-channel"))
        (ok (null (enchiridion.supervisor:find-channel supervisor "nope"))))
      (enchiridion.supervisor:queue-control "heartbeat on" :run run)
      (testing "the first poll reads it and the second does not"
        (ok (= 1 (enchiridion.supervisor:supervisor-poll-control supervisor)))
        (ok (= 0 (enchiridion.supervisor:supervisor-poll-control supervisor))))
      (testing "the report reaches the status file"
        (ok (search "heartbeat on"
                    (enchiridion.supervisor:status-report
                     (enchiridion.supervisor:read-status run))))
        (ok (enchiridion.supervisor:status-report-ok-p
             (enchiridion.supervisor:read-status run)))
        (ok (enchiridion.supervisor:supervisor-heartbeat-p supervisor)))
      (testing "channels list names the channel"
        (enchiridion.supervisor:queue-control "channels list" :run run)
        (ok (= 1 (enchiridion.supervisor:supervisor-poll-control supervisor)))
        (ok (search "stub-channel"
                    (enchiridion.supervisor:status-report
                     (enchiridion.supervisor:read-status run)))))
      (testing "an unknown request is reported and does not stop the poll"
        (enchiridion.supervisor:queue-control "no-such-request" :run run)
        (ok (= 1 (enchiridion.supervisor:supervisor-poll-control supervisor)))
        (ok (search "unknown control request"
                    (enchiridion.supervisor:status-report
                     (enchiridion.supervisor:read-status run))))))))

(deftest a-refused-reload-says-so-in-the-status ()
  ;; The operator script that asked has to be able to tell a refused generation
  ;; from a loaded one, and the generation number is the same either way.
  (with-scratch-supervisor
      (supervisor
       :reload-function (lambda (supervisor)
                          (declare (ignore supervisor))
                          (list :ok-p nil :generation 3
                                :report "broken.lsp: READ error during LOAD.")))
    (let ((run (enchiridion.supervisor:supervisor-run-directory supervisor)))
      (enchiridion.supervisor:queue-control "reload" :run run)
      (ok (= 1 (enchiridion.supervisor:supervisor-poll-control supervisor)))
      (let ((status (enchiridion.supervisor:read-status run)))
        (testing "the report carries the reason and not a success"
          (ok (search "reload refused" (enchiridion.supervisor:status-report status)))
          (ok (search "broken.lsp" (enchiridion.supervisor:status-report status)))
          (ok (null (enchiridion.supervisor:status-report-ok-p status))))
        (testing "and the generation did not move"
          (ok (= 3 (enchiridion.supervisor:status-generation status))))))))

(deftest a-loaded-generation-is-reported-as-answered ()
  (with-scratch-supervisor
      (supervisor
       :reload-function (lambda (supervisor)
                          (declare (ignore supervisor))
                          (list :ok-p t :generation 4 :report "generation 4 loaded, 2 files")))
    (let ((run (enchiridion.supervisor:supervisor-run-directory supervisor)))
      (enchiridion.supervisor:queue-control "reload" :run run)
      (ok (= 1 (enchiridion.supervisor:supervisor-poll-control supervisor)))
      (let ((status (enchiridion.supervisor:read-status run)))
        (ok (enchiridion.supervisor:status-report-ok-p status))
        (ok (= 4 (enchiridion.supervisor:status-generation status)))))))

;;;; The heartbeat.

(deftest a-tick-runs-the-hook-and-records-what-it-said ()
  (let* ((directory (scratch-directory))
         (run (merge-pathnames "run/" directory))
         (ticks 0)
         (supervisor (enchiridion.supervisor:make-supervisor
                      :directory (namestring directory)
                      :run-directory (namestring run)
                      :tick-function (lambda (supervisor)
                                       (declare (ignore supervisor))
                                       (incf ticks)
                                       (list :ok-p t :report "one task done")))))
    (unwind-protect
         (progn
           (enchiridion.supervisor:supervisor-start supervisor)
           (enchiridion.supervisor:supervisor-tick supervisor)
           (ok (= 1 ticks))
           (ok (= 1 (enchiridion.supervisor:supervisor-ticks supervisor)))
           (ok (enchiridion.supervisor:supervisor-tick-ok-p supervisor))
           (ok (string= "one task done"
                        (enchiridion.supervisor:supervisor-tick-report supervisor)))
           (testing "the status file carries a heartbeat object"
             ;; A tick publishes slots; the poll loop is the only writer of the
             ;; status file, so a reader sees the tick after the next poll.
             (enchiridion.supervisor:supervisor-write-status supervisor)
             (let ((beat (enchiridion.supervisor:status-heartbeat
                          (enchiridion.supervisor:read-status run))))
               (ok (hash-table-p beat))
               (ok (eql 1 (gethash "ticks" beat)))
               (ok (string= "one task done" (gethash "report" beat)))
               (ok (integerp (gethash "last-tick" beat)))))
           (testing "a hook that signals does not take the scheduler with it"
             (setf (enchiridion.supervisor:supervisor-tick-function supervisor)
                   (lambda (supervisor)
                     (declare (ignore supervisor))
                     (error "the tick exploded")))
             (let ((report (enchiridion.supervisor:supervisor-tick supervisor)))
               (ok (null (getf report :ok-p)))
               (ok (search "the tick exploded" (getf report :report)))
               (ok (= 2 (enchiridion.supervisor:supervisor-ticks supervisor)))
               (ok (null (enchiridion.supervisor:supervisor-tick-ok-p supervisor))))))
      (ignore-errors (enchiridion.supervisor:supervisor-stop supervisor))
      (uiop:delete-directory-tree directory :validate t :if-does-not-exist :ignore))))

(deftest heartbeat-run-asks-for-one-tick-without-waiting ()
  (let* ((directory (scratch-directory))
         (run (merge-pathnames "run/" directory))
         (supervisor (enchiridion.supervisor:make-supervisor
                      :directory (namestring directory)
                      :run-directory (namestring run)
                      :heartbeat-p nil
                      :heartbeat-interval 3600
                      :tick-function (lambda (supervisor)
                                       (declare (ignore supervisor))
                                       (list :ok-p t :report "ticked")))))
    (unwind-protect
         (progn
           (enchiridion.supervisor:supervisor-start supervisor)
           (enchiridion.supervisor:queue-control "heartbeat run" :run run)
           (ok (= 1 (enchiridion.supervisor:supervisor-poll-control supervisor)))
           (testing "the answer is immediate and names a request, not a result"
             (ok (enchiridion.supervisor:status-report-ok-p
                  (enchiridion.supervisor:read-status run)))
             (ok (search "requested"
                         (enchiridion.supervisor:status-report
                          (enchiridion.supervisor:read-status run)))))
           (testing "and the schedule being off does not refuse the request"
             (ok (not (enchiridion.supervisor:supervisor-heartbeat-p supervisor))))
           (testing "the request is honoured within a second"
             (loop repeat 100
                   until (plusp (enchiridion.supervisor:supervisor-ticks supervisor))
                   do (sleep 0.05))
             (ok (= 1 (enchiridion.supervisor:supervisor-ticks supervisor)))
             (ok (null (enchiridion.supervisor:supervisor-tick-requested-p supervisor)))
             (testing "and an hour-long interval is not due a second later"
               (ok (not (enchiridion.supervisor:supervisor-heartbeat-due-p
                         supervisor))))))
      (ignore-errors (enchiridion.supervisor:supervisor-stop supervisor))
      (uiop:delete-directory-tree directory :validate t :if-does-not-exist :ignore))))

(deftest a-fresh-supervisor-waits-an-interval-for-its-first-tick ()
  ;; A pass at t=0 competes with the first operator turn and spends tokens
  ;; before anyone asked for anything, so the schedule starts one interval out
  ;; and only an explicit `heartbeat run` ticks sooner.
  (let* ((directory (scratch-directory))
         (run (merge-pathnames "run/" directory))
         (supervisor (enchiridion.supervisor:make-supervisor
                      :directory (namestring directory)
                      :run-directory (namestring run)
                      :heartbeat-p t
                      :heartbeat-interval 900
                      :tick-function (lambda (supervisor)
                                       (declare (ignore supervisor))
                                       (list :ok-p t :report "ticked")))))
    (unwind-protect
         (progn
           (enchiridion.supervisor:supervisor-start supervisor)
           (ok (not (enchiridion.supervisor:supervisor-heartbeat-due-p supervisor)))
           (testing "and a request still ticks at once"
             ;; The heartbeat thread is running, so it is the one that answers
             ;; the request; ticking by hand here races it on a slow host.
             (setf (enchiridion.supervisor:supervisor-tick-requested-p supervisor) t)
             (loop repeat 100
                   until (plusp (enchiridion.supervisor:supervisor-ticks supervisor))
                   do (sleep 0.05))
             (ok (= 1 (enchiridion.supervisor:supervisor-ticks supervisor)))))
      (ignore-errors (enchiridion.supervisor:supervisor-stop supervisor))
      (uiop:delete-directory-tree directory :validate t :if-does-not-exist :ignore))))

(deftest heartbeat-on-starts-a-schedule-the-configuration-disabled ()
  ;; An operator who starts with :sleep :enabled nil must be able to turn
  ;; unattended work on, or the command that says it did is lying.
  (let* ((directory (scratch-directory))
         (run (merge-pathnames "run/" directory))
         (supervisor (enchiridion.supervisor:make-supervisor
                      :directory (namestring directory)
                      :run-directory (namestring run)
                      :heartbeat-p nil
                      :heartbeat-interval 3600
                      :tick-function (lambda (supervisor)
                                       (declare (ignore supervisor))
                                       (list :ok-p t :report "ticked")))))
    (unwind-protect
         (progn
           (enchiridion.supervisor:supervisor-start supervisor)
           (ok (null (enchiridion.supervisor::supervisor-heartbeat-thread supervisor)))
           (enchiridion.supervisor:queue-control "heartbeat on" :run run)
           (enchiridion.supervisor:supervisor-poll-control supervisor)
           (ok (enchiridion.supervisor:supervisor-heartbeat-p supervisor))
           (testing "the thread is running now"
             (ok (enchiridion.supervisor::supervisor-heartbeat-thread supervisor))
             (ok (bordeaux-threads:thread-alive-p
                  (enchiridion.supervisor::supervisor-heartbeat-thread supervisor)))))
      (ignore-errors (enchiridion.supervisor:supervisor-stop supervisor))
      (uiop:delete-directory-tree directory :validate t :if-does-not-exist :ignore))))

(deftest a-tick-request-during-a-tick-is-queued ()
  ;; The operator asked. Dropping the request makes the command that said
  ;; "requested" a lie, and the tick it wanted never happens.
  (let* ((released nil)
         (directory (scratch-directory))
         (run (merge-pathnames "run/" directory))
         (supervisor (enchiridion.supervisor:make-supervisor
                      :directory (namestring directory)
                      :run-directory (namestring run)
                      :heartbeat-p t
                      :tick-function (lambda (supervisor)
                                       (declare (ignore supervisor))
                                       ;; Hold the first tick open so the
                                       ;; heartbeat thread is busy, not idle and
                                       ;; free to take the request itself.
                                       (loop repeat 200 until released
                                             do (sleep 0.05))
                                       (list :ok-p t :report "ticked")))))
    (unwind-protect
         (progn
           (enchiridion.supervisor:supervisor-start supervisor)
           (setf (enchiridion.supervisor:supervisor-tick-requested-p supervisor) t)
           (loop repeat 100
                 until (enchiridion.supervisor:supervisor-tick-running-p supervisor)
                 do (sleep 0.05))
           (ok (enchiridion.supervisor:supervisor-tick-running-p supervisor))
           (enchiridion.supervisor:queue-control "heartbeat run" :run run)
           (ok (= 1 (enchiridion.supervisor:supervisor-poll-control supervisor)))
           (ok (enchiridion.supervisor:supervisor-tick-requested-p supervisor))
           (let ((status (enchiridion.supervisor:read-status run)))
             (ok (enchiridion.supervisor:status-report-ok-p status))
             (ok (search "queued" (enchiridion.supervisor:status-report status))))
           (testing "and the queued request runs once the tick ends"
             (setf released t)
             (loop repeat 100
                   until (= 2 (enchiridion.supervisor:supervisor-ticks supervisor))
                   do (sleep 0.05))
             (ok (= 2 (enchiridion.supervisor:supervisor-ticks supervisor)))))
      (setf released t)
      (ignore-errors (enchiridion.supervisor:supervisor-stop supervisor))
      (uiop:delete-directory-tree directory :validate t :if-does-not-exist :ignore))))

(deftest heartbeat-on-without-a-hook-is-not-a-success ()
  ;; The operator script that turns the heartbeat on deserves to know that
  ;; nothing will happen: a channel with no sleep agent attached is a schedule
  ;; with nothing to run.
  (let* ((directory (scratch-directory))
         (run (merge-pathnames "run/" directory))
         (supervisor (enchiridion.supervisor:make-supervisor
                      :directory (namestring directory)
                      :run-directory (namestring run))))
    (unwind-protect
         (progn
           (enchiridion.supervisor:supervisor-start supervisor)
           (enchiridion.supervisor:queue-control "heartbeat on" :run run)
           (enchiridion.supervisor:supervisor-poll-control supervisor)
           (let ((status (enchiridion.supervisor:read-status run)))
             (ok (enchiridion.supervisor:supervisor-heartbeat-p supervisor))
             (ok (search "no sleep agent" (enchiridion.supervisor:status-report status)))
             (ok (null (enchiridion.supervisor:status-report-ok-p status)))))
      (ignore-errors (enchiridion.supervisor:supervisor-stop supervisor))
      (uiop:delete-directory-tree directory :validate t :if-does-not-exist :ignore))))

(deftest enabling-a-live-channel-does-not-start-it-twice ()
  ;; A started channel reports :LIVE, not :RUNNING. The check used to read the
  ;; state, so enable started a second restart loop on the same channel.
  (let ((channel (make-instance 'stub-channel :name "stub")))
    (with-scratch-supervisor (supervisor :channels (list channel))
      (let ((thread (enchiridion.channel:channel-thread channel)))
        (sleep 0.1)
        (ok (eq :live (enchiridion.channel:channel-state channel)))
        (ok (search "already up"
                    (enchiridion.supervisor::handle-channels
                     supervisor '("enable" "stub"))))
        (ok (eq thread (enchiridion.channel:channel-thread channel))
            "the channel still runs on the thread it started with")))))

(deftest stopping-waits-for-the-tick-in-flight ()
  ;; The heartbeat thread used to be destroyed mid-tick, which can unwind out
  ;; of a store write with a transaction open.
  (let* ((finished nil)
         (directory (scratch-directory))
         (supervisor (enchiridion.supervisor:make-supervisor
                      :directory (namestring directory)
                      :run-directory (namestring (merge-pathnames "run/" directory))
                      :heartbeat-p nil
                      :tick-function (lambda (supervisor)
                                       (declare (ignore supervisor))
                                       (sleep 0.5)
                                       (setf finished t)
                                       (list :ok-p t :report "slow tick")))))
    (unwind-protect
         (progn
           (enchiridion.supervisor:supervisor-start supervisor)
           (enchiridion.supervisor::handle-heartbeat supervisor '("run"))
           (loop repeat 100
                 until (enchiridion.supervisor:supervisor-tick-running-p supervisor)
                 do (sleep 0.02))
           (enchiridion.supervisor:supervisor-stop supervisor)
           (ok finished "the tick ran to its end before stop returned"))
      (uiop:delete-directory-tree directory :validate t :if-does-not-exist :ignore))))

(deftest lazy-channel-replacement-preserves-healthy-instance ()
  (with-scratch-supervisor (supervisor)
    (let ((calls 0))
      (setf (enchiridion.supervisor:supervisor-channel-factory supervisor)
            (lambda (name)
              (incf calls)
              (if (string= name "stub-channel") (make-stub-channel) nil)))
      (ok (= calls 0))
      (multiple-value-bind (report good)
          (enchiridion.supervisor:supervisor-enable-channel supervisor "stub-channel")
        (declare (ignore report))
        (ok good))
      (let ((old (enchiridion.supervisor:find-channel supervisor "stub-channel")))
        (ok old)
        (setf (enchiridion.supervisor:supervisor-channel-factory supervisor)
              (lambda (name) (declare (ignore name)) (error "factory refused")))
        (multiple-value-bind (report good)
            (enchiridion.supervisor:supervisor-enable-channel
             supervisor "stub-channel" :replace t)
          (ok (search "factory refused" report))
          (ng good))
        (ok (eq old (enchiridion.supervisor:find-channel supervisor "stub-channel")))
        (ok (enchiridion.channel:channel-live-p old))))))

(deftest simultaneous-control-requests-have-independent-responses ()
  (with-scratch-supervisor (supervisor)
    (let* ((run (enchiridion.supervisor:supervisor-run-directory supervisor))
           (first nil) (second nil)
           (one (bordeaux-threads:make-thread
                 (lambda () (setf first (enchiridion.supervisor:request-control
                                         "channels list" :run run :wait 3)))))
           (two (bordeaux-threads:make-thread
                 (lambda () (setf second (enchiridion.supervisor:request-control
                                          "not-a-command" :run run :wait 3))))))
      (unwind-protect
           (progn
             (loop repeat 100
                   until (and first second)
                   do (enchiridion.supervisor:supervisor-poll-control supervisor)
                      (sleep 0.01))
             (bordeaux-threads:join-thread one)
             (bordeaux-threads:join-thread two)
             (ok first) (ok second)
             (ok (enchiridion.supervisor:status-report-ok-p first))
             (ng (enchiridion.supervisor:status-report-ok-p second))
             (ok (search "no channels" (enchiridion.supervisor:status-report first)))
             (ok (search "unknown control" (enchiridion.supervisor:status-report second)))
             (ng (equal (gethash "request-id" first) (gethash "request-id" second)))
             (ok (= 0 (enchiridion.supervisor:supervisor-poll-control supervisor))))
        (dolist (thread (list one two))
          (when (bordeaux-threads:thread-alive-p thread)
            (bordeaux-threads:destroy-thread thread)))))))

(deftest headless-cli-is-not-restarted ()
  (let* ((*standard-input* (make-string-input-stream ""))
         (channel (enchiridion.channel.cli:make-cli-channel))
         (supervisor (enchiridion.supervisor:make-supervisor)))
    (setf (enchiridion.supervisor:supervisor-running-p supervisor) t)
    (let ((start (get-internal-real-time)))
      (enchiridion.supervisor::restart-channel-loop supervisor channel)
      (ok (< (- (get-internal-real-time) start) internal-time-units-per-second))
      (ok (eq :unavailable (enchiridion.channel:channel-state channel))))))

(enchiridion.channel:define-channel stalled-channel)
(defmethod enchiridion.channel:channel-start ((channel stalled-channel) &key config)
  (declare (ignore channel config))
  (sleep 30))
(defmethod enchiridion.channel:channel-stop ((channel stalled-channel)) channel)

(enchiridion.channel:define-channel conflicting-channel)
(defmethod enchiridion.channel:channel-start ((channel conflicting-channel) &key config)
  (declare (ignore channel config))
  (error "Address already in use"))
(defmethod enchiridion.channel:channel-stop ((channel conflicting-channel)) channel)

(deftest replacement-timeout-and-listener-conflict-preserve-old-channel ()
  ;; A candidate that cannot start beside the running one gets a second attempt
  ;; with the old one stopped, and the old one is started again when that fails:
  ;; the surface is serving either way.
  (with-scratch-supervisor (supervisor :channels (list (make-stub-channel)))
    (let ((old (enchiridion.supervisor:find-channel supervisor "stub-channel"))
          (enchiridion.supervisor::+channel-start-seconds+ 0.05))
      (loop repeat 100 until (enchiridion.channel:channel-live-p old) do (sleep 0.01))
      (dolist (constructor (list #'make-stalled-channel #'make-conflicting-channel))
        (setf (enchiridion.supervisor:supervisor-channel-factory supervisor)
              (lambda (name) (funcall constructor :name name)))
        (multiple-value-bind (report good)
            (enchiridion.supervisor:supervisor-enable-channel
             supervisor "stub-channel" :replace t)
          (ng good)
          (ok (search "refused" report))
          (ok (search "serving again" report)
              "the report says the old channel was put back"))
        (ok (eq old (enchiridion.supervisor:find-channel supervisor "stub-channel")))
        (ok (enchiridion.channel:channel-live-p old) "and it is live")))))

(enchiridion.channel:define-channel bound-channel)

(defvar *bound-channel* nil
  "The instance an exclusive bind belongs to, or NIL when nothing holds it.")

(defmethod enchiridion.channel:channel-start ((channel bound-channel) &key config)
  (declare (ignore config))
  (when (and *bound-channel* (not (eq *bound-channel* channel)))
    (error "Address already in use"))
  (setf *bound-channel* channel)
  (setf (enchiridion.channel:channel-live-p channel) t
        (enchiridion.channel:channel-state channel) :live)
  nil)

(defmethod enchiridion.channel:channel-stop ((channel bound-channel))
  (when (eq *bound-channel* channel)
    (setf *bound-channel* nil))
  (setf (enchiridion.channel:channel-live-p channel) nil
        (enchiridion.channel:channel-state channel) :stopped)
  nil)

(defmethod enchiridion.channel:channel-send ((channel bound-channel) target text
                                             &key reply-to)
  (declare (ignore channel target reply-to))
  text)

(defmethod enchiridion.channel:channel-status ((channel bound-channel))
  (enchiridion.channel:channel-state channel))

(deftest a-replacement-that-needs-the-bind-stops-the-old-one ()
  ;; A channel that owns a port or a session cannot start beside its
  ;; predecessor, so the old one is stopped and the new one takes its place.
  ;;
  ;; The bind is a global on purpose: a thread does not see another thread's
  ;; binding.
  (setf *bound-channel* nil)
  (unwind-protect
       (with-scratch-supervisor (supervisor :channels (list (make-bound-channel
                                                             :name "bound")))
         (let ((old (enchiridion.supervisor:find-channel supervisor "bound"))
               (enchiridion.supervisor::+channel-start-seconds+ 2))
           (loop repeat 100 until (enchiridion.channel:channel-live-p old)
                 do (sleep 0.01))
           (ok (enchiridion.channel:channel-live-p old))
           (setf (enchiridion.supervisor:supervisor-channel-factory supervisor)
                 (lambda (name) (make-bound-channel :name name)))
           (multiple-value-bind (report good)
               (enchiridion.supervisor:supervisor-enable-channel supervisor "bound"
                                                                :replace t)
             (ok good report)
             (ok (search "stopped so the new one could bind" report)))
           (let ((new (enchiridion.supervisor:find-channel supervisor "bound")))
             (ok new)
             (ng (eq new old))
             (ok (enchiridion.channel:channel-live-p new))
             (ng (enchiridion.channel:channel-live-p old))
             (ok (eq *bound-channel* new)
                 "the exclusive resource belongs to the new instance"))))
    (setf *bound-channel* nil)))

(deftest control-admission-is-bounded-and-expiry-is-explicit ()
  (with-scratch-supervisor (supervisor)
    (let* ((run (enchiridion.supervisor:supervisor-run-directory supervisor))
           (enchiridion.supervisor::+control-file-limit+ 1)
           (path (enchiridion.supervisor:queue-control "heartbeat off" :run run)))
      (ok (handler-case
              (progn (enchiridion.supervisor:queue-control "heartbeat on" :run run) nil)
            (error () t)))
      ;; A queued request expires on the queue's horizon, not the answer's:
      ;; an answer sits in the spool for a minute.
      (let ((enchiridion.supervisor::+control-pending-seconds+ -1))
        (ok (= 1 (enchiridion.supervisor:supervisor-poll-control supervisor)))
        (let ((reply (com.inuoe.jzon:parse
                      (uiop:read-file-string (make-pathname :type "response" :defaults path)))))
          (ng (enchiridion.supervisor:status-report-ok-p reply))
          (ok (string= (pathname-name path) (gethash "request-id" reply)))
          (ok (search "expired" (enchiridion.supervisor:status-report reply)))))
      (ok (handler-case
              (progn (enchiridion.supervisor:queue-control (make-string 4097) :run run) nil)
            (error () t))))))

(deftest concurrent-admission-reserves-one-slot-and-recovers-abandoned-claims ()
  (with-scratch-supervisor (supervisor)
    (let* ((run (enchiridion.supervisor:supervisor-run-directory supervisor))
           (success 0)
           (lock (bordeaux-threads:make-lock))
           (threads
             (loop repeat 12 collect
                   (bordeaux-threads:make-thread
                    (lambda ()
                      (let ((enchiridion.supervisor::+control-file-limit+ 1))
                        (handler-case
                            (progn
                              (enchiridion.supervisor:queue-control "channels list" :run run)
                              (bordeaux-threads:with-lock-held (lock) (incf success)))
                          (error () nil))))))))
      (dolist (thread threads) (bordeaux-threads:join-thread thread))
      (ok (= 1 success))
      (ok (= 1 (enchiridion.supervisor:supervisor-poll-control supervisor)))
      (let ((enchiridion.supervisor::+control-retention-seconds+ -1))
        (enchiridion.supervisor::clean-control-spool run))
      (ok (null (uiop:directory-files (enchiridion.supervisor::control-spool run))))
      (let ((enchiridion.supervisor::+control-file-limit+ 1))
        (let ((claim (enchiridion.supervisor::reserve-control-slot run)))
          (ok (probe-file claim))
          (let ((enchiridion.supervisor::+control-retention-seconds+ -1))
            (enchiridion.supervisor::clean-control-spool run))
          (ng (probe-file claim)))))))

(deftest malformed-control-never-runs-a-command ()
  (with-scratch-supervisor (supervisor)
    (let* ((run (enchiridion.supervisor:supervisor-run-directory supervisor))
           (path (enchiridion.supervisor:queue-control "channels list" :run run)))
      (with-open-file (stream path :direction :output :if-exists :supersede)
        (write-line "reload " stream)
        (write-line "channels list" stream))
      (ok (= 1 (enchiridion.supervisor:supervisor-poll-control supervisor)))
      (ok (= 3 (enchiridion.supervisor:supervisor-generation supervisor)))
      (ng (enchiridion.supervisor::supervisor-report-ok-p supervisor)))))

(deftest pending-requests-survive-a-restart-and-fresh-responses-are-retained ()
  (let* ((directory (scratch-directory))
         (run (namestring (merge-pathnames "run/" directory))))
    (unwind-protect
         (progn
           (let ((first (enchiridion.supervisor:make-supervisor
                         :directory (namestring (merge-pathnames "agents/default/" directory))
                         :run-directory run)))
             (enchiridion.supervisor:supervisor-start first)
             (enchiridion.supervisor:queue-control "channels list" :run run)
             (enchiridion.supervisor:supervisor-stop first))
           (let ((second (enchiridion.supervisor:make-supervisor
                          :directory (namestring (merge-pathnames "agents/default/" directory))
                          :run-directory run)))
             (enchiridion.supervisor:supervisor-start second)
             (ok (= 1 (enchiridion.supervisor:supervisor-poll-control second)))
             (let ((response (first (remove-if-not
                                     (lambda (path)
                                       (string= "response" (pathname-type path)))
                                     (uiop:directory-files
                                      (enchiridion.supervisor::control-spool run))))))
               (ok response)
               (ok (string= "response" (pathname-type response)))
               (enchiridion.supervisor::clean-control-spool run)
               (ok (probe-file response)))
             (enchiridion.supervisor:supervisor-stop second)))
      (uiop:delete-directory-tree directory :validate t :if-does-not-exist :ignore))))

(deftest unrecognized-spool-files-are-bounded ()
  (with-scratch-supervisor (supervisor)
    (let* ((run (enchiridion.supervisor:supervisor-run-directory supervisor))
           (spool (enchiridion.supervisor::control-spool run))
           (junk (merge-pathnames "operator-notes.txt" spool))
           (enchiridion.supervisor::+control-retention-seconds+ -1))
      (ensure-directories-exist junk)
      (with-open-file (stream junk :direction :output :if-exists :supersede)
        (write-line "not a request" stream))
      (enchiridion.supervisor::clean-control-spool run)
      (ng (probe-file junk)))))

(deftest the-replace-control-verb-publishes-a-fresh-channel ()
  (with-scratch-supervisor (supervisor :channels (list (make-stub-channel)))
    (let* ((old (enchiridion.supervisor:find-channel supervisor "stub-channel"))
           (built nil))
      (setf (enchiridion.supervisor:supervisor-channel-factory supervisor)
            (lambda (name) (setf built (make-stub-channel :name name))))
      (multiple-value-bind (report ok)
          (enchiridion.supervisor::handle-control
           supervisor "channels replace stub-channel")
        (ok (not (null ok)))
        (ok (search "is up" report)))
      (ok built)
      (ok (not (eq old built)))
      (ok (eq built (enchiridion.supervisor:find-channel supervisor "stub-channel")))
      (ok (enchiridion.channel:channel-live-p built)))))

(deftest polling-an-idle-supervisor-does-no-work ()
  (with-scratch-supervisor (supervisor)
    (ok (= 0 (enchiridion.supervisor:supervisor-poll-control supervisor)))
    (ok (= 0 (enchiridion.supervisor:supervisor-poll-control supervisor)))))

(deftest legacy-lines-rotate-without-being-truncated-under-a-reader ()
  (with-scratch-supervisor (supervisor)
    (let* ((run (enchiridion.supervisor:supervisor-run-directory supervisor))
           (path (enchiridion.supervisor:control-file run)))
      (with-open-file (stream path :direction :output :if-exists :supersede
                                   :if-does-not-exist :create)
        (write-line "heartbeat off" stream)
        (write-line "channels list" stream))
      (ok (= 2 (enchiridion.supervisor:supervisor-poll-control supervisor)))
      (ng (probe-file path))
      (ng (probe-file (make-pathname :type "batch" :defaults path)))
      (ok (= 0 (enchiridion.supervisor:supervisor-poll-control supervisor))))))

;;;; Shutdown, status writes, and control answers.
;;;;
;;;; An operator depends on a stop that fits the container's window, a status
;;;; write failure that leaves the process serving, an answer that does not
;;;; depend on a file, and a stopped channel or schedule that says so.

(enchiridion.channel:define-channel slow-stop-channel)

(defmethod enchiridion.channel:channel-start ((channel slow-stop-channel) &key config)
  (declare (ignore config))
  (setf (enchiridion.channel:channel-live-p channel) t
        (enchiridion.channel:channel-state channel) :live)
  nil)

(defmethod enchiridion.channel:channel-stop ((channel slow-stop-channel))
  (sleep 5)
  (setf (enchiridion.channel:channel-live-p channel) nil
        (enchiridion.channel:channel-state channel) :stopped)
  nil)

(defun delete-file-if-present-safe (path)
  (when (probe-file path)
    (ignore-errors (delete-file path))))

(defun occupy-path (path)
  "Replace PATH with a directory that cannot be renamed over.

PATH has to become a directory for that: ensuring the directories of a file
pathname creates its parent and leaves the name itself free, so the write that
was supposed to fail wrote to a cleared path and the test passed for nothing.
A rename onto an empty directory succeeds on Darwin, so the directory gets one
file in it, and the failure is in the file the test is about rather than in the
process's permissions."
  (delete-file-if-present-safe path)
  (let ((directory (uiop:ensure-directory-pathname path)))
    (ensure-directories-exist directory)
    (with-open-file (stream (merge-pathnames "occupant" directory)
                            :direction :output
                            :if-exists :supersede
                            :if-does-not-exist :create)
      (write-string "occupied" stream))
    directory))

(deftest stopping-fits-inside-one-shutdown-budget ()
  ;; A tick and a channel that both refuse to finish used to be waited out one
  ;; after the other, for thirty seconds each, past the container's whole
  ;; window.
  (let* ((directory (scratch-directory))
         (run (merge-pathnames "run/" directory))
         (channel (make-slow-stop-channel :name "slow"))
         (supervisor (enchiridion.supervisor:make-supervisor
                      :directory (namestring directory)
                      :run-directory (namestring run)
                      :heartbeat-p nil
                      :channels (list channel)
                      :tick-function (lambda (supervisor)
                                       (declare (ignore supervisor))
                                       (sleep 30)
                                       (list :ok-p t :report "tick"))))
         ;; The budgets are parameters, so the same code runs with twenty
         ;; seconds in a container and here with a window of one second.
         (enchiridion.supervisor::+shutdown-budget-seconds+ 0.6)
         (enchiridion.supervisor::+tick-drain-seconds+ 0.2)
         (enchiridion.supervisor::+channel-stop-seconds+ 0.2))
    (unwind-protect
         (progn
           (enchiridion.supervisor:supervisor-start supervisor)
           (enchiridion.supervisor::handle-heartbeat supervisor '("run"))
           (loop repeat 200
                 until (enchiridion.supervisor::supervisor-tick-running-p supervisor)
                 do (sleep 0.01))
           (ok (enchiridion.supervisor::supervisor-tick-running-p supervisor))
           (let ((start (get-internal-real-time)))
             (enchiridion.supervisor:supervisor-stop supervisor)
             (ok (< (- (get-internal-real-time) start)
                    internal-time-units-per-second)
                 "the tick and the channel are stopped inside one second"))
           (testing "the last status file says the process is gone"
             (let ((status (enchiridion.supervisor:read-status run)))
               (ok (hash-table-p status))
               (ng (gethash "running" status))
               (ng (enchiridion.supervisor:status-fresh-p status))))
           (testing "a channel that outlasted its share is reported stopped"
             (ok (eq :stopped (enchiridion.channel:channel-state channel)))
             (ng (enchiridion.channel:channel-live-p channel)))
           (testing "and no tick is reported as still running"
             (ng (enchiridion.supervisor::supervisor-tick-running-p supervisor))))
      (ignore-errors (enchiridion.supervisor:supervisor-stop supervisor))
      (uiop:delete-directory-tree directory :validate t :if-does-not-exist :ignore))))

(deftest an-unwritable-status-file-does-not-stop-the-control-loop ()
  ;; The poll loop answers control requests and keeps the status file fresh. A
  ;; failed write used to end it, so every shell command read the process as
  ;; dead and a queued request was never answered.
  (with-scratch-supervisor (supervisor)
    (let* ((run (enchiridion.supervisor:supervisor-run-directory supervisor))
           (status-path (enchiridion.supervisor:status-file run))
           (request nil)
           (loop-thread nil))
      (unwind-protect
           (progn
             (occupy-path status-path)
             (setf loop-thread
                   (bordeaux-threads:make-thread
                    (lambda ()
                      (enchiridion.supervisor:supervisor-poll-loop
                       supervisor :interval 0.05))))
             (setf request (enchiridion.supervisor:queue-control "channels list" :run run))
             (loop repeat 150
                   until (probe-file (make-pathname :type "response" :defaults request))
                   do (sleep 0.02))
             (ok (probe-file (make-pathname :type "response" :defaults request))
                 "the request is answered although the status file cannot be written")
             (ok (bordeaux-threads:thread-alive-p loop-thread)
                 "the poll loop is still running after the failed write"))
        (ignore-errors (enchiridion.supervisor:supervisor-stop supervisor))
        (when (and loop-thread (bordeaux-threads:thread-alive-p loop-thread))
          (ignore-errors (bordeaux-threads:destroy-thread loop-thread)))
        (uiop:delete-directory-tree (uiop:ensure-directory-pathname status-path)
                                    :validate t :if-does-not-exist :ignore)))))

(deftest a-control-answer-does-not-need-the-status-file ()
  ;; The answer was the status file read back, so a failed write left the shell
  ;; with nothing after the handler had run.
  (with-scratch-supervisor (supervisor)
    (let* ((run (enchiridion.supervisor:supervisor-run-directory supervisor))
           (path (enchiridion.supervisor:queue-control "channels list" :run run))
           (response (make-pathname :type "response" :defaults path)))
      (occupy-path (enchiridion.supervisor:status-file run))
      (ok (= 1 (enchiridion.supervisor:supervisor-poll-control supervisor)))
      (ok (probe-file response) "the answer is written")
      (let ((answer (com.inuoe.jzon:parse
                     (uiop:read-file-string response :external-format :utf-8))))
        (ok (string= (pathname-name path) (gethash "request-id" answer)))
        (ok (enchiridion.supervisor:status-report-ok-p answer)))
      (testing "the request and its slot are released"
        (ng (probe-file path))
        (ng (probe-file (enchiridion.supervisor::control-entry-claim path))))
      (uiop:delete-directory-tree
       (uiop:ensure-directory-pathname
        (enchiridion.supervisor:status-file run))
       :validate t :if-does-not-exist :ignore))))

(deftest an-answered-request-releases-its-admission-slot ()
  ;; A slot was released only by the reader that waited on it or by the
  ;; minute-long cleanup, so a burst left every slot held and the next command
  ;; saw a full queue that was empty.
  (with-scratch-supervisor (supervisor)
    (let* ((run (enchiridion.supervisor:supervisor-run-directory supervisor))
           (enchiridion.supervisor::+control-file-limit+ 1))
      (enchiridion.supervisor:queue-control "channels list" :run run)
      (ok (= 1 (enchiridion.supervisor:supervisor-poll-control supervisor)))
      (ok (handler-case
              (progn (enchiridion.supervisor:queue-control "channels list" :run run) t)
            (error () nil))
          "the slot the answered request held is free again")
      (ok (= 1 (enchiridion.supervisor:supervisor-poll-control supervisor))))))

(deftest an-expired-answer-does-not-release-a-pending-requests-slot ()
  ;; An expired response and a pending request name the same claim. Removing
  ;; the claim with the response let the next request take a slot in use.
  (with-scratch-supervisor (supervisor)
    (let* ((run (enchiridion.supervisor:supervisor-run-directory supervisor))
           (spool (enchiridion.supervisor::control-spool run))
           (claim (merge-pathnames "1.claim" spool))
           (pending (merge-pathnames "1_pending.request" spool))
           (expired (merge-pathnames "1_expired.response" spool))
           (enchiridion.supervisor::+control-retention-seconds+ -1))
      (ensure-directories-exist pending)
      (dolist (path (list claim pending expired))
        (with-open-file (stream path :direction :output :if-exists :supersede
                                     :if-does-not-exist :create)
          (write-line "x" stream)))
      (enchiridion.supervisor::clean-control-spool run)
      (ng (probe-file expired) "the expired answer is gone")
      (ok (probe-file pending) "the pending request is untouched")
      (ok (probe-file claim)
          "and the slot it is using is still reserved for it"))))

(deftest a-slow-control-request-keeps-the-supervisor-live ()
  ;; A reload can take minutes, and the status file used to age out while it
  ;; ran, so every shell command reported a running supervisor as dead.
  (with-scratch-supervisor
      (supervisor
       :reload-function (lambda (supervisor)
                          (declare (ignore supervisor))
                          (sleep 2.5)
                          (list :ok-p t :generation 4 :report "slow generation 4")))
    (let* ((run (enchiridion.supervisor:supervisor-run-directory supervisor))
           ;; The window here is one second wide, so a two and a half second
           ;; handler is stale without a writer behind it.
           (enchiridion.supervisor::+status-refresh-seconds+ 0.1)
           (enchiridion.supervisor::+status-fresh-seconds+ 1.2)
           (stale 0)
           (poll nil))
      (enchiridion.supervisor:queue-control "reload" :run run)
      (enchiridion.supervisor:supervisor-write-status supervisor)
      (setf poll (bordeaux-threads:make-thread
                  (lambda ()
                    (enchiridion.supervisor:supervisor-poll-control supervisor))))
      (loop while (bordeaux-threads:thread-alive-p poll)
            do (unless (enchiridion.supervisor:status-fresh-p
                        (enchiridion.supervisor:read-status run))
                 (incf stale))
               (sleep 0.02))
      (ok (zerop stale) "the status file never went stale while the reload ran")
      (let ((status (enchiridion.supervisor:read-status run)))
        (ok (enchiridion.supervisor:status-report-ok-p status))
        (ok (search "reload done, generation 4"
                    (enchiridion.supervisor:status-report status)))
        (ok (= 4 (enchiridion.supervisor:status-generation status)))))))

(deftest disabling-a-channel-that-is-not-up-is-refused ()
  ;; Success for a name nothing runs lets a typo read as a stopped channel.
  (with-scratch-supervisor (supervisor)
    (multiple-value-bind (report ok)
        (enchiridion.supervisor::handle-channels supervisor '("disable" "nope"))
      (ng ok)
      (ok (search "no channel called nope" report)))))

(deftest a-heartbeat-with-no-hook-is-reported-off ()
  ;; An enabled schedule with no hook answered "on" and explained nothing.
  (let* ((directory (scratch-directory))
         (run (merge-pathnames "run/" directory))
         (supervisor (enchiridion.supervisor:make-supervisor
                      :directory (namestring directory)
                      :run-directory (namestring run)
                      :heartbeat-p t)))
    (unwind-protect
         (progn
           (enchiridion.supervisor:supervisor-start supervisor)
           (let ((beat (enchiridion.supervisor:status-heartbeat
                        (enchiridion.supervisor:read-status run))))
             (ok (hash-table-p beat))
             (ng (gethash "enabled" beat))
             (ng (gethash "alive" beat))
             (ng (gethash "requested" beat))))
      (ignore-errors (enchiridion.supervisor:supervisor-stop supervisor))
      (uiop:delete-directory-tree directory :validate t :if-does-not-exist :ignore))))

(deftest a-dead-heartbeat-thread-is-replaced ()
  ;; A dead thread in the slot was permanent: later `heartbeat on` calls
  ;; reported success and started nothing.
  (let* ((directory (scratch-directory))
         (run (merge-pathnames "run/" directory))
         (supervisor (enchiridion.supervisor:make-supervisor
                      :directory (namestring directory)
                      :run-directory (namestring run)
                      :heartbeat-p t
                      :heartbeat-interval 3600
                      :tick-function (lambda (supervisor)
                                       (declare (ignore supervisor))
                                       (list :ok-p t :report "ticked")))))
    (unwind-protect
         (progn
           (enchiridion.supervisor:supervisor-start supervisor)
           (let ((first (enchiridion.supervisor::supervisor-heartbeat-thread supervisor)))
             (ok (bordeaux-threads:thread-alive-p first))
             (bordeaux-threads:destroy-thread first)
             (loop repeat 100 while (bordeaux-threads:thread-alive-p first)
                   do (sleep 0.01))
             (testing "the status file says the schedule has no thread"
               (enchiridion.supervisor:supervisor-write-status supervisor)
               (ng (gethash "alive"
                            (enchiridion.supervisor:status-heartbeat
                             (enchiridion.supervisor:read-status run)))))
             (testing "and turning it on starts one again"
               (multiple-value-bind (report ok)
                   (enchiridion.supervisor::handle-heartbeat supervisor '("on"))
                 (ok ok)
                 (ok (search "heartbeat on" report)))
               (let ((second (enchiridion.supervisor::supervisor-heartbeat-thread supervisor)))
                 (ok second)
                 (ng (eq first second))
                 (ok (bordeaux-threads:thread-alive-p second))))))
      (ignore-errors (enchiridion.supervisor:supervisor-stop supervisor))
      (uiop:delete-directory-tree directory :validate t :if-does-not-exist :ignore))))

(deftest a-stopped-supervisor-reports-no-live-schedule ()
  (let* ((directory (scratch-directory))
         (run (merge-pathnames "run/" directory))
         (supervisor (enchiridion.supervisor:make-supervisor
                      :directory (namestring directory)
                      :run-directory (namestring run)
                      :heartbeat-p t
                      :heartbeat-interval 3600
                      :tick-function (lambda (supervisor)
                                       (declare (ignore supervisor))
                                       (list :ok-p t :report "ticked")))))
    (unwind-protect
         (progn
           (enchiridion.supervisor:supervisor-start supervisor)
           (ok (gethash "alive" (enchiridion.supervisor:status-heartbeat
                                 (enchiridion.supervisor:read-status run))))
           (enchiridion.supervisor:supervisor-stop supervisor)
           (let ((beat (enchiridion.supervisor:status-heartbeat
                        (enchiridion.supervisor:read-status run))))
             (ok (gethash "enabled" beat) "the schedule is still configured")
             (ng (gethash "alive" beat) "but nothing runs it any more")
             (ng (gethash "running" beat))))
      (ignore-errors (enchiridion.supervisor:supervisor-stop supervisor))
      (uiop:delete-directory-tree directory :validate t :if-does-not-exist :ignore))))

(defun channel-row-named (rows name)
  "Return the row called NAME in ROWS, or NIL."
  (find name rows :key (lambda (row) (gethash "name" row)) :test #'string=))

(deftest a-channel-row-reports-what-this-process-wants-on ()
  ;; A row used to answer ENABLED from the configuration. A channel started by
  ;; a --channel flag is disabled in the file but wanted here, so a crash before
  ;; it went live left a row that called it unwanted.
  (let* ((directory (scratch-directory))
         (run (merge-pathnames "run/" directory))
         (supervisor (enchiridion.supervisor:make-supervisor
                      :directory (namestring directory)
                      :run-directory (namestring run)
                      :config '(:channels (:stub-channel (:enabled nil)))
                      :channels (list (make-stub-channel)))))
    (unwind-protect
         (progn
           (enchiridion.supervisor:supervisor-write-status supervisor)
           (let* ((status (enchiridion.supervisor:read-status run))
                  (row (channel-row-named (enchiridion.supervisor:status-channels status)
                                          "stub-channel")))
             (ok row)
             (ok (gethash "enabled" row)
                 "a channel the supervisor holds is one it wants on")
             (ok (string= "stopped" (gethash "state" row)))))
      (ignore-errors (enchiridion.supervisor:supervisor-stop supervisor))
      (uiop:delete-directory-tree directory :validate t :if-does-not-exist :ignore))))

(deftest a-channel-that-is-not-running-is-reported-disabled ()
  ;; A configured channel that is off was never reported, so a reader could not
  ;; tell it from one that was never configured.
  (with-scratch-supervisor (supervisor)
    (let* ((run (enchiridion.supervisor:supervisor-run-directory supervisor))
           (rows (enchiridion.supervisor:supervisor-channel-rows supervisor))
           (names (map 'list (lambda (row) (gethash "name" row)) rows)))
      (testing "the shipped defaults disable the network channels and they are listed"
        (ok (member "http" names :test #'string=))
        (ok (member "fluxer" names :test #'string=))
        (dolist (name '("http" "fluxer"))
          (let ((row (channel-row-named rows name)))
            (ok (string= "disabled" (gethash "state" row)))
            (ng (gethash "enabled" row)
                "a disabled channel never fails a readiness rule"))))
      (testing "and the status file carries the same rows"
        (let ((from-file (enchiridion.supervisor:status-channels
                          (enchiridion.supervisor:read-status run))))
          (ok (= (length rows) (length from-file)))
          (dolist (name '("http" "fluxer"))
            (ok (channel-row-named from-file name))))))))

(deftest disabling-a-channel-is-reported-and-reversible ()
  ;; `channels disable` left the stopped instance in the list, so the status
  ;; file called it enabled while it was down.
  (with-scratch-supervisor (supervisor :channels (list (make-stub-channel)))
    (let ((old (enchiridion.supervisor:find-channel supervisor "stub-channel")))
      (loop repeat 100 until (enchiridion.channel:channel-live-p old) do (sleep 0.01))
      (setf (enchiridion.supervisor:supervisor-channel-factory supervisor)
            (lambda (name) (make-stub-channel :name name)))
      (multiple-value-bind (report ok)
          (enchiridion.supervisor::handle-channels supervisor '("disable" "stub-channel"))
        (ok ok)
        (ok (search "is down" report)))
      (testing "the instance is gone and the name is not"
        (ng (enchiridion.supervisor:find-channel supervisor "stub-channel"))
        (ok (member "stub-channel"
                    (enchiridion.supervisor:supervisor-disabled-channels supervisor)
                    :test #'string=))
        (let ((row (channel-row-named
                    (enchiridion.supervisor:supervisor-channel-rows supervisor)
                    "stub-channel")))
          (ok row "a channel the operator turned off is still reported")
          (ok (string= "disabled" (gethash "state" row)))
          (ng (gethash "enabled" row))))
      (testing "listing says which channels are off"
        (multiple-value-bind (report ok)
            (enchiridion.supervisor::handle-channels supervisor '("list"))
          (ok ok)
          (ok (search "disabled: stub-channel" report))))
      (testing "a second disable is refused rather than repeated"
        (multiple-value-bind (report ok)
            (enchiridion.supervisor::handle-channels supervisor '("disable" "stub-channel"))
          (ng ok)
          (ok (search "no channel called" report))))
      (testing "enabling builds a fresh instance and clears the name"
        (multiple-value-bind (report ok)
            (enchiridion.supervisor::handle-channels supervisor '("enable" "stub-channel"))
          (ok ok report)
          (ok (search "is up" report)))
        (let ((new (enchiridion.supervisor:find-channel supervisor "stub-channel")))
          (loop repeat 100 until (enchiridion.channel:channel-live-p new)
                do (sleep 0.01))
          (ok new)
          (ng (eq new old))
          (ok (enchiridion.channel:channel-live-p new)))
        (ng (member "stub-channel"
                    (enchiridion.supervisor:supervisor-disabled-channels supervisor)
                    :test #'string=))))))

;;;; Waiting for an answer.

(deftest a-request-that-times-out-says-which-wait-it-is-in ()
  ;; Requests queued behind a long reload wait that long. The client used to
  ;; answer "no supervisor is running, so nothing was asked".
  (with-scratch-supervisor (supervisor)
    (let ((run (enchiridion.supervisor:supervisor-run-directory supervisor)))
      (testing "a request still in the spool is reported queued"
        (multiple-value-bind (status state detail)
            (enchiridion.supervisor:request-control "channels list" :run run :wait 0.1)
          (ng status)
          (ok (eq :timeout state))
          (ok (search "still queued" detail))))
      (testing "a request behind another says how many are ahead"
        ;; Answer the request above so this one starts from a queue of two.
        (ok (plusp (enchiridion.supervisor:supervisor-poll-control supervisor)))
        (enchiridion.supervisor:queue-control "channels list" :run run)
        (multiple-value-bind (status state detail)
            (enchiridion.supervisor:request-control "channels list" :run run
                                                    :wait 0.1)
          (ng status)
          (ok (eq :timeout state))
          (ok (search "behind 1 other request" detail))))
      (testing "a request the supervisor has taken is reported taken"
        (let ((path (enchiridion.supervisor:queue-control "channels list" :run run)))
          ;; The poll loop removes the request before it answers, so a missing
          ;; file is one being handled.
          (delete-file path)
          (ok (search "has taken the request"
                      (enchiridion.supervisor::control-wait-detail run path)))))
      (testing "and the requests it left behind are all still answered"
        (ok (plusp (enchiridion.supervisor:supervisor-poll-control supervisor)))))))

(deftest a-request-that-cannot-be-queued-says-so ()
  (with-scratch-supervisor (supervisor)
    (let* ((run (enchiridion.supervisor:supervisor-run-directory supervisor))
           (enchiridion.supervisor::+control-file-limit+ 0))
      (multiple-value-bind (status state detail)
          (enchiridion.supervisor:request-control "channels list" :run run :wait 0.1)
        (ng status)
        (ok (eq :queue-full state))
        (ok (search "not queued" detail))))))

(deftest no-supervisor-is-a-separate-answer ()
  (let* ((directory (scratch-directory))
         (run (namestring (merge-pathnames "run/" directory))))
    (unwind-protect
         (multiple-value-bind (status state detail)
             (enchiridion.supervisor:request-control "reload" :run run :wait 0.1)
           (ng status)
           (ok (eq :no-supervisor state))
           (ng detail))
      (uiop:delete-directory-tree directory :validate t :if-does-not-exist :ignore))))

;;;; What the files did.

(deftest a-failed-status-write-is-reported-to-a-reader ()
  ;; A full run directory left the failure only in the log, so `health` saw a
  ;; stale file and said the supervisor was gone.
  (with-scratch-supervisor (supervisor)
    (let* ((run (enchiridion.supervisor:supervisor-run-directory supervisor))
           (path (enchiridion.supervisor:status-file run)))
      (enchiridion.supervisor::supervisor-try-write-status supervisor)
      (ok (gethash "ok" (enchiridion.supervisor:supervisor-write-report)))
      (occupy-path path)
      (ng (enchiridion.supervisor::supervisor-try-write-status supervisor))
      (let ((report (enchiridion.supervisor:supervisor-write-report)))
        (ng (gethash "ok" report))
        (ok (plusp (length (gethash "report" report))))
        (ok (<= 0 (gethash "age" report))))
      (uiop:delete-directory-tree (uiop:ensure-directory-pathname path)
                                  :validate t :if-does-not-exist :ignore)
      (testing "and a write that works clears it"
        (ok (enchiridion.supervisor::supervisor-try-write-status supervisor))
        (ok (gethash "ok" (enchiridion.supervisor:supervisor-write-report)))
        (ok (gethash "ok" (enchiridion.supervisor:status-writes
                           (enchiridion.supervisor:read-status run))))))))

(deftest stopping-twice-does-not-ask-the-channels-again ()
  ;; A signal handler and an unwind-protect both stop the same supervisor. The
  ;; second call used to give stopped channels a fresh share and a timeout
  ;; report.
  (with-scratch-supervisor (supervisor :channels (list (make-stub-channel)))
    (let ((channel (enchiridion.supervisor:find-channel supervisor "stub-channel")))
      (loop repeat 100 until (enchiridion.channel:channel-live-p channel)
            do (sleep 0.01))
      (enchiridion.supervisor:supervisor-stop supervisor)
      (let ((start (get-internal-real-time)))
        (enchiridion.supervisor:supervisor-stop supervisor)
        (ok (< (- (get-internal-real-time) start)
               (/ internal-time-units-per-second 2))
            "the second stop does nothing and waits for nothing"))
      (ok (eq :stopped (enchiridion.channel:channel-state channel)))
      (ng (gethash "running" (enchiridion.supervisor:read-status
                              (enchiridion.supervisor:supervisor-run-directory
                               supervisor)))))))
