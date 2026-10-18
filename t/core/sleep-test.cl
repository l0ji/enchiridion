;;;; sleep-test.cl --- The heartbeat, the sleep agent, and compaction.
;;;;
;;;; The backend here is a fake that counts its calls, because most of what
;;;; this file tests is what a tick does NOT do: no model call for an empty
;;;; queue, none past a spent cap, none while bootstrap still owns the seed
;;;; files. A tick that quietly spends money is the failure worth a test.

(defpackage #:enchiridion-sleep-test
  (:use #:cl)
  (:import-from #:rove #:deftest #:ok #:ng #:testing)
  (:export #:run))

(in-package #:enchiridion-sleep-test)

(defstruct (counting-backend (:constructor make-counting-backend))
  (calls 0 :type integer)
  (reply "done" :type string)
  (fail-p nil :type boolean))

(defmethod enchiridion.llm:complete ((backend counting-backend) messages
                                     &key model tools budget)
  (declare (ignore messages model tools budget))
  (incf (counting-backend-calls backend))
  (when (counting-backend-fail-p backend)
    (error 'enchiridion.errors:backend-error :backend "counting"))
  (enchiridion.llm::%make-completion
   :text (counting-backend-reply backend)
   :model "counting-model"
   :input-tokens 11
   :output-tokens 5))

(defmethod enchiridion.llm:model-capabilities ((backend counting-backend))
  (declare (ignore backend))
  '(:tools nil))

(defmethod enchiridion.llm:backend-name ((backend counting-backend))
  (declare (ignore backend))
  "counting")

(defun scratch-directory ()
  "Return a fresh directory under the directory this build may write."
  (uiop:ensure-directory-pathname
   (merge-pathnames
    (format nil "enchiridion-sleep-test-~D/" (random most-positive-fixnum))
    (uiop:ensure-directory-pathname *default-pathname-defaults*))))

(defmacro with-scratch-world ((store supervisor &key (config nil)) &body body)
  "Bind STORE to a scratch store and SUPERVISOR to a supervisor over it.
The supervisor carries one counting agent, so a tick's model calls are
countable from the test."
  `(let* ((directory (scratch-directory))
          (,store (enchiridion.memory.store:open-store
                   :path (merge-pathnames "memory.db" directory)))
          (agent (enchiridion.kernel:make-agent
                  :backend (make-counting-backend)
                  :directory (namestring directory)
                  :budget '(:max-tokens-per-tick 4000 :max-tokens-per-day 400000)
                  :store ,store))
          (session (enchiridion.kernel:make-session :agent agent))
          (,supervisor (enchiridion.supervisor:make-supervisor
                        :directory (namestring directory)
                        :run-directory (namestring (merge-pathnames "run/" directory))
                        :store ,store
                        :agent agent
                        :session session
                        :config ,config
                        :tick-function #'enchiridion.kernel:heartbeat)))
     (unwind-protect
          (progn ,@body)
       (ignore-errors (enchiridion.memory.store:close-store ,store))
       (uiop:delete-directory-tree directory
                                   :validate t
                                   :if-does-not-exist :ignore))))

(defun agent-of (supervisor)
  "Return the agent the supervisor owns."
  (enchiridion.supervisor:supervisor-agent supervisor))

(defun backend-of (supervisor)
  "Return the counting backend behind the supervisor's agent."
  (enchiridion.kernel:agent-backend (agent-of supervisor)))

(defun calls-made (supervisor)
  "Return how many model calls the supervisor's agent has made."
  (counting-backend-calls (backend-of supervisor)))

(defun store-of (supervisor)
  "Return the store the supervisor owns."
  (enchiridion.supervisor:supervisor-store supervisor))

;;;; Tasks.

(deftest the-task-queue-is-the-store-under-another-name ()
  (with-scratch-world (store supervisor)
    (declare (ignore supervisor))
    (let ((first (enchiridion.kernel:enqueue-task store "write the guide"))
          (second (enchiridion.kernel:enqueue-task store "read the journal")))
      (ok (= 2 (enchiridion.kernel:task-queue-length store)))
      (ok (string= "write the guide"
                   (enchiridion.memory.store:task-row-body
                    (first (enchiridion.kernel:task-queue store)))))
      (testing "a claimed task is running, not done"
        (let ((claimed (enchiridion.kernel:dequeue-task store)))
          (ok (string= "write the guide"
                       (enchiridion.memory.store:task-row-body claimed)))
          (ok (eq :running (enchiridion.memory.store:task-row-status claimed)))
          (ok (= 1 (enchiridion.kernel:task-queue-length store)))))
      (testing "and only the running one can be finished"
        (ok (enchiridion.memory.store:complete-task
             store (enchiridion.memory.store:task-row-id first)))
        (ok (= 1 (enchiridion.memory.store:count-tasks store :status :done)))
        (ok (string= "read the journal"
                     (enchiridion.memory.store:task-row-body second)))))))

(deftest a-task-left-running-by-a-dead-process-is-failed ()
  (with-scratch-world (store supervisor)
    (enchiridion.kernel:enqueue-task store "unfinished business")
    (enchiridion.kernel:dequeue-task store)
    (ok (= 1 (enchiridion.memory.store:count-tasks store :status :running)))
    (let ((report (enchiridion.kernel:heartbeat supervisor)))
      (ok (getf report :ok-p))
      (ok (search "interrupted" (getf report :report))))
    (testing "the row says failed rather than in progress"
      (ok (= 1 (enchiridion.memory.store:count-tasks store :status :failed)))
      (ok (zerop (enchiridion.memory.store:count-tasks store :status :running))))))

;;;; The sleep agent.

(deftest the-sleep-agent-owns-the-identity-files ()
  (let ((agent (enchiridion.kernel:sleep-agent
                :backend (make-counting-backend)
                :directory nil)))
    (dolist (block (enchiridion.kernel:agent-blocks agent))
      (case (enchiridion.memory:block-label block)
        ((:persona :operator :world)
         (testing (format nil "~A is writable for the sleep agent"
                          (enchiridion.memory:block-label block))
           (ok (enchiridion.memory:block-writable-p block))))
        (t
         (testing (format nil "~A stays a harness block"
                          (enchiridion.memory:block-label block))
           (ok (enchiridion.memory:block-writable-p block))))))
    (testing "and the operator's agent does not own them"
      (let ((primary (enchiridion.kernel:make-agent :backend (make-counting-backend))))
        (dolist (block (enchiridion.kernel:agent-blocks primary))
          (when (member (enchiridion.memory:block-label block)
                        '(:persona :operator :world)
                        :test #'eq)
            (ng (enchiridion.memory:block-writable-p block))))))))

(deftest a-pass-with-a-task-runs-one-turn-and-completes-it ()
  (with-scratch-world (store supervisor)
    (let* ((task (enchiridion.kernel:enqueue-task store "say hello"))
           (agent (agent-of supervisor))
           (result (enchiridion.kernel:run-sleep-pass agent store :task task)))
      (ok (getf result :ran-p))
      (ok (eq :done (getf result :status)))
      (ok (eql (enchiridion.memory.store:task-row-id task) (getf result :task-id)))
      (ok (= 1 (calls-made supervisor)))
      (testing "the task is done and nothing is left running"
        (ok (= 1 (enchiridion.memory.store:count-tasks store :status :done)))
        (ok (zerop (enchiridion.memory.store:count-tasks store :status :running))))
      (testing "and the transcript names the sleep channel"
        (let ((row (first (enchiridion.memory.store:recent-turns store :limit 1))))
          (ok row)
          (ok (eq :sleep (enchiridion.memory.store:turn-row-channel row))))))))

(deftest a-pass-that-fails-marks-the-task-failed ()
  (with-scratch-world (store supervisor)
    (let* ((task (enchiridion.kernel:enqueue-task store "do the impossible"))
           (agent (agent-of supervisor)))
      (setf (counting-backend-fail-p (backend-of supervisor)) t)
      (let ((result (enchiridion.kernel:run-sleep-pass agent store :task task)))
        (ok (eq :failed (getf result :status)))
        (ok (search "counting" (getf result :note))))
      (testing "the row says failed rather than done"
        (ok (= 1 (enchiridion.memory.store:count-tasks store :status :failed)))
        (ok (zerop (enchiridion.memory.store:count-tasks store :status :done)))))))

;;;; The tick.

(deftest a-tick-with-no-store-reports-and-does-not-signal ()
  (let ((supervisor (enchiridion.supervisor:make-supervisor
                     :directory (namestring (scratch-directory))
                     :run-directory (namestring (merge-pathnames
                                                 "run/" (scratch-directory))))))
    (let ((report (enchiridion.kernel:heartbeat supervisor)))
      (ok (listp report))
      (ok (search "no memory store" (getf report :report))))))

(deftest an-idle-tick-costs-nothing ()
  (with-scratch-world (store supervisor)
    (declare (ignore store))
    (let ((report (enchiridion.kernel:heartbeat supervisor)))
      (ok (getf report :ok-p))
      (testing "no queued task and no new turn means no model call"
        (ok (search "idle" (getf report :report)))
        (ok (zerop (calls-made supervisor)))))))

(deftest a-tick-drains-one-task-and-writes-the-ledger ()
  (with-scratch-world (store supervisor)
    (enchiridion.kernel:enqueue-task store "write the world file")
    (let ((report (enchiridion.kernel:heartbeat supervisor)))
      (ok (getf report :ok-p))
      (ok (search "done" (getf report :report)))
      (ok (= 1 (calls-made supervisor))))
    (testing "the ledger block carries the spend"
      (let ((ledger (enchiridion.memory.store:ledger-block store)))
        (ok (plusp (length ledger)))
        (ok (search "session in" ledger))
        (ok (<= (length ledger) (enchiridion.memory:default-block-limit :ledger)))))
    (testing "and the queue is empty afterwards"
      (ok (zerop (enchiridion.kernel:task-queue-length store))))))

(deftest a-spent-cap-stops-the-tick-before-it-spends ()
  (with-scratch-world (store supervisor)
    (let ((agent (agent-of supervisor)))
      (setf (enchiridion.kernel:agent-budget agent)
            '(:max-tokens-per-tick 10 :max-tokens-per-day 400000))
      (enchiridion.kernel:enqueue-task store "a task that must wait")
      (let ((report (enchiridion.kernel:heartbeat supervisor)))
        (ok (search "sleep skipped" (getf report :report)))
        (ok (search "tick cap" (getf report :report)))
        (ok (zerop (calls-made supervisor))))
      (testing "and the task is still waiting rather than claimed"
        (ok (= 1 (enchiridion.kernel:task-queue-length store)))
        (ok (zerop (enchiridion.memory.store:count-tasks store :status :running)))))))

(deftest bootstrap-keeps-the-identity-files-out-of-reach ()
  (with-scratch-world (store supervisor)
    (let ((directory (enchiridion.supervisor:supervisor-directory supervisor)))
      ;; A directory with no state file is one where bootstrap has not run:
      ;; the seed files still belong to the operator.
      (enchiridion.kernel:enqueue-task store "rewrite SOUL.md")
      (let ((report (enchiridion.kernel:heartbeat supervisor)))
        (ok (search "bootstrap" (getf report :report)))
        (ok (search "sleep skipped" (getf report :report)))
        (ok (zerop (calls-made supervisor))))
      (declare (ignore directory)))))

;;;; Compaction.

(deftest compaction-waits-for-enough-new-turns ()
  (with-scratch-world (store supervisor)
    (flet ((add-turns (count)
             (dotimes (index count)
               (enchiridion.memory.store:record-turn
                store :session "operator" :role "user"
                :body (format nil "turn ~D" index)))))
      (add-turns 3)
      (ok (null (enchiridion.kernel::compact-when-due
                 supervisor store (agent-of supervisor)))
          "three turns are not worth a summary")
      (ok (string= "" (enchiridion.memory.store:session-block store)))
      (add-turns 1)
      (ok (enchiridion.kernel::compact-when-due
           supervisor store (agent-of supervisor))
          "the fourth turn is")
      (testing "the session block holds what the cheap model answered"
        (ok (string= "done" (enchiridion.memory.store:session-block store))))
      (testing "and the cursor stops it happening again"
        (ok (null (enchiridion.kernel::compact-when-due
                   supervisor store (agent-of supervisor))))))))
