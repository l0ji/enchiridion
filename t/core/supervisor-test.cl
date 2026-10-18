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

(defmacro with-scratch-supervisor ((supervisor &key (channels nil)) &body body)
  "Bind SUPERVISOR to a started supervisor in a scratch directory, then stop it
and remove the directory. A failing test must not leave a thread behind."
  `(let* ((directory (scratch-directory))
          (run (merge-pathnames "run/" directory))
          (,supervisor (enchiridion.supervisor:make-supervisor
                        :directory (namestring (merge-pathnames "agents/default/" directory))
                        :run-directory (namestring run)
                        :generation 3
                        :bootstrap-line "bootstrap step 0 of 8"
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
                            :channels (list (make-stub-channel)))
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
