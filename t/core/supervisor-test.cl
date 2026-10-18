;;;; supervisor-test.cl --- The control file, the status file, and channels.
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
        (ok (null (probe-file (merge-pathnames "enchiridion.status.new" run))))))
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
                                :report "broken.cl: READ error during LOAD.")))
    (let ((run (enchiridion.supervisor:supervisor-run-directory supervisor)))
      (enchiridion.supervisor:queue-control "reload" :run run)
      (ok (= 1 (enchiridion.supervisor:supervisor-poll-control supervisor)))
      (let ((status (enchiridion.supervisor:read-status run)))
        (testing "the report carries the reason and not a success"
          (ok (search "reload refused" (enchiridion.supervisor:status-report status)))
          (ok (search "broken.cl" (enchiridion.supervisor:status-report status)))
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
           (testing "the answer is immediate and the request is queued"
             (ok (enchiridion.supervisor:supervisor-tick-requested-p supervisor))
             (ok (enchiridion.supervisor:status-report-ok-p
                  (enchiridion.supervisor:read-status run))))
           (testing "and the schedule being off does not refuse the request"
             (ok (not (enchiridion.supervisor:supervisor-heartbeat-p supervisor)))
             (ok (enchiridion.supervisor:supervisor-heartbeat-due-p supervisor)))
           (testing "a tick clears the request"
             (enchiridion.supervisor:supervisor-tick supervisor)
             (ok (null (enchiridion.supervisor:supervisor-tick-requested-p supervisor)))
             (ok (not (enchiridion.supervisor:supervisor-heartbeat-due-p supervisor))
                 "an hour-long interval is not due a second later")))
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
             (setf (enchiridion.supervisor:supervisor-tick-requested-p supervisor) t)
             (ok (enchiridion.supervisor:supervisor-heartbeat-due-p supervisor))
             (enchiridion.supervisor:supervisor-tick supervisor)
             (ok (= 1 (enchiridion.supervisor:supervisor-ticks supervisor)))))
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
