;;;; sleep-test.lsp --- The heartbeat, the sleep agent, and compaction.
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
  (fail-p nil :type boolean)
  (last-prompt "" :type string))

(defmethod enchiridion.llm:complete ((backend counting-backend) messages
                                     &key model tools budget)
  (declare (ignore model tools budget))
  (incf (counting-backend-calls backend))
  (let ((user (find "user" messages :key #'enchiridion.llm:message-role
                                    :test #'string= :from-end t)))
    (when user
      (setf (counting-backend-last-prompt backend)
            (enchiridion.llm:message-content user))))
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
     ;; IGNORABLE and not IGNORE: a test that only wants the store, or only the
     ;; supervisor, is a normal test, and the binding the macro makes is not a
     ;; variable the test has to use to be correct.
     (declare (ignorable ,store ,supervisor))
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
        (:adapt
         (testing "the adaptation block stays harness-owned"
           (ng (enchiridion.memory:block-writable-p block))))
        (t
         (testing (format nil "~A stays a harness block"
                          (enchiridion.memory:block-label block))
           (ok (enchiridion.memory:block-writable-p block))))))
    (testing "and the operator's agent does not own them"
      (let ((primary (enchiridion.kernel:make-agent :backend (make-counting-backend))))
        (dolist (block (enchiridion.kernel:agent-blocks primary))
          (when (member (enchiridion.memory:block-label block)
                        '(:persona :operator :world :adapt)
                        :test #'eq)
            (ng (enchiridion.memory:block-writable-p block))))))))

(deftest the-tick-agents-share-the-operator-lock ()
  (with-scratch-world (store supervisor)
    (let* ((agent (agent-of supervisor))
           (sleep (enchiridion.kernel::sleep-pass-agent agent nil store))
           (compactor (enchiridion.kernel::compactor-agent agent))
           (lock (enchiridion.kernel::agent-lock agent)))
      (testing "the constructors pass the operator's lock, not a fresh one"
        (ok (eq lock (enchiridion.kernel::agent-lock sleep)))
        (ok (eq lock (enchiridion.kernel::agent-lock compactor))))
      (testing "and a turn on either is busy while the operator's turn holds it"
        (let ((held (bordeaux-threads:make-semaphore :count 0))
              (release (bordeaux-threads:make-semaphore :count 0))
              (holder nil))
          (setf holder
                (bordeaux-threads:make-thread
                 (lambda ()
                   (bordeaux-threads:acquire-lock lock t)
                   (bordeaux-threads:signal-semaphore held)
                   (bordeaux-threads:wait-on-semaphore release)
                   (bordeaux-threads:release-lock lock))
                 :name "enchiridion sleep test holder"))
          (bordeaux-threads:wait-on-semaphore held)
          (unwind-protect
               (dolist (other (list sleep compactor))
                 (ok (handler-case
                         (progn (enchiridion.kernel:run-turn other "hello"
                                                             :block-p nil)
                                nil)
                       (enchiridion.errors:turn-busy () t))))
            (bordeaux-threads:signal-semaphore release)
            (bordeaux-threads:join-thread holder)))))))

(deftest a-pass-with-a-task-runs-one-turn-and-completes-it ()
  (with-scratch-world (store supervisor)
    (let* ((queued (enchiridion.kernel:enqueue-task store "say hello"))
           (task (enchiridion.kernel:dequeue-task store))
           (agent (agent-of supervisor))
           (result (enchiridion.kernel:run-sleep-pass agent store :task task)))
      (declare (ignore queued))
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
    (enchiridion.kernel:enqueue-task store "do the impossible")
    (let* ((task (enchiridion.kernel:dequeue-task store))
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

(deftest a-tick-cap-is-this-tick-and-not-the-process ()
  ;; The cap bounds one pass. Measuring it from a timestamp put a one second
  ;; window around the tick in which an operator's own turn counted as
  ;; unattended spend, and measuring it from the whole in-memory ledger let one
  ;; operator turn disable the sleep agent until the process restarted.
  (with-scratch-world (store supervisor)
    (setf (enchiridion.kernel:agent-budget (agent-of supervisor))
          '(:max-tokens-per-tick 10 :max-tokens-per-day 400000))
    (enchiridion.kernel:enqueue-task store "the first task")
    (enchiridion.kernel:enqueue-task store "the second task")
    (let ((first (enchiridion.kernel:heartbeat supervisor)))
      (ok (getf first :ok-p))
      (ok (search "done" (getf first :report)))
      (testing "the pass spent the cap, so compaction waits for the next tick"
        (ok (search "compaction skipped" (getf first :report)))
        (ok (search "tick cap" (getf first :report)))))
    (testing "and the next tick has its own budget"
      (let ((second (enchiridion.kernel:heartbeat supervisor)))
        (ok (getf second :ok-p))
        (ok (search "done" (getf second :report)))))
    (ok (= 2 (calls-made supervisor)))))

(deftest a-spent-day-cap-stops-the-tick-before-it-spends ()
  (with-scratch-world (store supervisor)
    (setf (enchiridion.kernel:agent-budget (agent-of supervisor))
          '(:max-tokens-per-tick 4000 :max-tokens-per-day 20))
    ;; The day window is the rolling twenty-four hours, so a row written before
    ;; the tick counts, which is the whole point of a day cap.
    (enchiridion.memory.store:record-usage store :model "counting" :input 15 :output 15)
    (enchiridion.kernel:enqueue-task store "a task that must wait")
    (let ((report (enchiridion.kernel:heartbeat supervisor)))
      (ok (search "sleep skipped" (getf report :report)))
      (ok (search "day cap" (getf report :report)))
      (ok (zerop (calls-made supervisor))))
    (testing "and the task is still waiting rather than claimed"
      (ok (= 1 (enchiridion.kernel:task-queue-length store)))
      (ok (zerop (enchiridion.memory.store:count-tasks store :status :running))))))

(deftest an-operator-turn-does-not-spend-the-sleep-budget ()
  ;; The tick cap is about this tick. An operator turn recorded on the same
  ;; agent used to count against it forever, which turned a busy afternoon into
  ;; an agent that never slept again.
  (with-scratch-world (store supervisor)
    (let ((agent (agent-of supervisor)))
      (setf (enchiridion.kernel:agent-budget agent)
            '(:max-tokens-per-tick 50 :max-tokens-per-day 400000))
      (enchiridion.kernel:record-spend
       agent
       (enchiridion.llm::%make-completion :text "operator turn" :model "counting"
                                          :input-tokens 40 :output-tokens 24)
       :channel :http)
      (enchiridion.memory.store:record-usage store :session "operator"
                                                   :model "counting"
                                                   :input 40 :output 24
                                                   :channel :http)
      (enchiridion.kernel:enqueue-task store "a task that must still run")
      (let ((report (enchiridion.kernel:heartbeat supervisor)))
        (ok (getf report :ok-p))
        (ok (search "done" (getf report :report)))
        (ok (= 1 (calls-made supervisor)))))))

(deftest an-oversized-task-body-says-it-was-cut ()
  (with-scratch-world (store supervisor)
    (enchiridion.kernel:enqueue-task store (make-string 9000 :initial-element #\x))
    (let ((report (enchiridion.kernel:heartbeat supervisor)))
      (ok (getf report :ok-p))
      (ok (search "body cut" (getf report :report)))
      (testing "and the row still holds the whole body"
        (ok (= 9000 (length (enchiridion.memory.store:task-row-body
                             (first (enchiridion.kernel:task-queue store))))))))))

(deftest bootstrap-keeps-the-identity-files-out-of-reach ()
  (with-scratch-world (store supervisor)
    ;; A directory seeded by INIT-AGENT is one where bootstrap has not run yet:
    ;; the seed files still belong to the operator. A directory with no
    ;; BOOTSTRAP.md at all is not that case, because there are no steps to
    ;; work through and nothing to refuse.
    (enchiridion.memory:init-agent
     (enchiridion.supervisor:supervisor-directory supervisor))
    (ok (enchiridion.memory:bootstrap-refuse-writes-p
         (enchiridion.supervisor:supervisor-directory supervisor)))
    (enchiridion.kernel:enqueue-task store "rewrite SOUL.md")
    (let ((report (enchiridion.kernel:heartbeat supervisor)))
      (ok (search "bootstrap" (getf report :report)))
      (ok (search "sleep skipped" (getf report :report)))
      (ok (zerop (calls-made supervisor))))))

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

(defun projection-rows (store)
  (enchiridion.memory.store:query-rows
   store "SELECT from_turn, to_turn, rebased_p FROM projections ORDER BY id"))

(deftest every-nth-compaction-rebuilds-from-raw-turns ()
  ;; Every eighth compaction rebases from the last 24 raw turns; here
  ;; every second, from six
  (with-scratch-world (store supervisor)
    (let ((enchiridion.memory:*compaction-rebase-every* 2)
          (enchiridion.memory:*compaction-rebase-turns* 6))
      (flet ((add-turns (count)
               (dotimes (index count)
                 (enchiridion.memory.store:record-turn
                  store :session "operator" :role "user"
                  :body (format nil "turn ~D" index))))
             (compact ()
               (enchiridion.kernel::compact-when-due
                supervisor store (agent-of supervisor)
                :rebase-p (enchiridion.kernel::compaction-rebase-due-p store))))
        (testing "a store with no passes is not due a rebase"
          (ng (enchiridion.kernel::compaction-rebase-due-p store)))
        (add-turns 4)
        (ok (compact))
        (testing "an ordinary pass records a projection over its four turns"
          (let ((row (first (projection-rows store))))
            (ok (= 1 (length (projection-rows store))))
            (ok (= 0 (enchiridion.memory.store:field row "rebased_p")))
            (ok (= 3 (- (enchiridion.memory.store:field row "to_turn")
                        (enchiridion.memory.store:field row "from_turn")))))
          (ok (enchiridion.kernel::compaction-rebase-due-p store)))
        (add-turns 4)
        (ok (search "raw turns" (compact)))
        (testing "the second pass is a rebase over the last six raw turns"
          ;; The first pass's own turns sit between the operator's, on the
          ;; sleep channel, so the range is counted rather than subtracted.
          (let ((row (second (projection-rows store))))
            (ok (= 1 (enchiridion.memory.store:field row "rebased_p")))
            (ok (= 6 (enchiridion.memory.store:field
                      (first (enchiridion.memory.store:query-rows
                              store
                              "SELECT COUNT(*) AS n FROM turns
                                WHERE id BETWEEN ? AND ? AND channel <> 'sleep'"
                              (list (enchiridion.memory.store:field row "from_turn")
                                    (enchiridion.memory.store:field row "to_turn"))))
                      "n")))))
        (testing "and the count starts again after it"
          (ng (enchiridion.kernel::compaction-rebase-due-p store)))))))

(deftest a-reserve-the-tick-cap-cannot-cover-is-refused ()
  (with-scratch-world (store supervisor)
    (let* ((agent (agent-of supervisor))
           (cap (getf (enchiridion.kernel:agent-budget agent) :max-tokens-per-tick)))
      (when cap
        (ok (null (enchiridion.kernel::budget-refusal agent store 0 0 :reserve 1)))
        (ok (search "cannot cover"
                    (enchiridion.kernel::budget-refusal agent store 0 0
                                                        :reserve (1+ cap))))))))

(deftest a-compaction-prompt-reads-oldest-first ()
  (with-scratch-world (store supervisor)
    (dolist (body '("first turn" "second turn" "third turn" "fourth turn"))
      (enchiridion.memory.store:record-turn
       store :session "operator" :role "user" :body body))
    (ok (enchiridion.kernel::compact-when-due supervisor store (agent-of supervisor)))
    (let ((prompt (counting-backend-last-prompt (backend-of supervisor))))
      (ok (< (search "first turn" prompt) (search "fourth turn" prompt))))))

(deftest a-recovered-t2-pass-says-where-its-candidate-came-from ()
  (testing "a pass that gates an earlier pass's candidate says so"
    (ok (search "a candidate an earlier pass built and never gated"
                (enchiridion.kernel::t2-report-line
                 (list :outcome :promoted :generation-id 4 :recovered t)))))
  (testing "and a pass that built its own does not"
    (ng (search "earlier pass"
                (enchiridion.kernel::t2-report-line
                 (list :outcome :promoted :generation-id 4))))))

(deftest a-large-store-says-its-size-and-age-once-a-day ()
  (with-scratch-world (store supervisor)
    ;; 1000000 is the report's NOW below; the turn is two days older than it.
    (enchiridion.memory.store:record-turn store :session "s" :role "user"
                                          :body "one turn" :ts 827200)
    (let ((enchiridion.kernel::+store-report-bytes+ 0)
          (enchiridion.kernel::*store-reported-ts* 0)
          (enchiridion.kernel::*store-failure-watermark* nil))
      (let ((line (enchiridion.kernel::store-report-line store :now 1000000)))
        (testing "the line carries the size, the count, the age and the policy"
          (ok (search "the memory store holds" line))
          (ok (search "1 episode" line))
          (ok (search "2 days old" line))
          (ok (search "nothing is deleted automatically" line))))
      (testing "the same day does not repeat it"
        (ok (null (enchiridion.kernel::store-report-line store :now 1000100))))
      (testing "and the next day does"
        (ok (search "the memory store holds"
                    (enchiridion.kernel::store-report-line
                     store :now (+ 1000000 enchiridion.kernel::+store-report-interval-seconds+))))))))

(deftest a-small-store-does-not-wake-an-idle-tick ()
  ;; The heartbeat reports work done. A store below the size threshold is not a
  ;; disk problem, and a tick with nothing else to say stays idle.
  (with-scratch-world (store supervisor)
    (let ((enchiridion.kernel::*store-reported-ts* 0)
          (enchiridion.kernel::*store-failure-watermark* nil))
      (ok (null (enchiridion.kernel::store-report-line store))))))

(deftest a-write-that-failed-since-the-last-tick-is-reported-on-this-one ()
  (with-scratch-world (store supervisor)
    (let ((enchiridion.kernel::*store-failure-watermark* nil)
          (enchiridion.kernel::*store-reported-ts* (get-universal-time))
          (enchiridion.kernel::*persistence-failure-reporter* nil))
      (unwind-protect
           (progn
             (enchiridion.kernel::store-report-line store)
             (testing "nothing new is nothing to say"
               (ok (null (enchiridion.kernel::store-report-line store))))
             (enchiridion.kernel::note-persistence-failure
              :turn "could not persist turn: database or disk is full")
             (testing "one failure is reported once, with the row's context"
               (let ((line (enchiridion.kernel::store-report-line store)))
                 (ok (search "1 memory write failed since the last tick" line))
                 (ok (search "database or disk is full" line)))
               (testing "and not again on the next tick"
                 (ok (null (enchiridion.kernel::store-report-line store))))))
        (setf enchiridion.kernel::*persistence-failures* 0
              enchiridion.kernel::*last-persistence-failure* nil
              enchiridion.kernel::*store-failure-watermark* nil)))))

(deftest t2-spend-counts-toward-the-day-cap-but-not-the-tick-cap ()
  ;; A T2 pass is held to its own caps and is larger than a tick by design,
  ;; but unattended work as a whole stays under the day cap.
  (with-scratch-world (store supervisor)
    (let ((agent (agent-of supervisor)))
      (setf (enchiridion.kernel:agent-budget agent)
            '(:max-tokens-per-tick 100 :max-tokens-per-day 1000))
      (let ((start (enchiridion.kernel::store-total store)))
        (enchiridion.memory.store:record-usage store :input 500 :output 0 :channel :t2)
        (testing "five times the tick cap on :t2 leaves the tick open"
          (ok (null (enchiridion.kernel::budget-refusal agent store start 0))))
        (enchiridion.memory.store:record-usage store :input 500 :output 0 :channel :t2)
        (testing "and the day cap still closes on it"
          (ok (search "day cap"
                      (enchiridion.kernel::budget-refusal agent store start 0))))))))

;;;; T2.

(deftest the-first-t2-pass-reports-what-is-missing-and-then-waits ()
  (with-scratch-world (store supervisor)
    (let ((enchiridion.memory:*t2-enabled-p* t)
          (enchiridion.memory:*t2-interval-seconds* 86400)
          (enchiridion.memory:*assertion-deriver* nil))
      (let ((first (getf (enchiridion.kernel:heartbeat supervisor) :report)))
        (ok (search "T2 skipped: instruments missing (deriver" first))
        (ok (zerop (calls-made supervisor))))
      (testing "a pass that is not due says nothing"
        (ng (search "T2" (getf (enchiridion.kernel:heartbeat supervisor) :report)))))))

(deftest t2-switched-off-says-nothing ()
  (with-scratch-world (store supervisor)
    (let ((enchiridion.memory:*t2-enabled-p* nil))
      (ng (search "T2" (getf (enchiridion.kernel:heartbeat supervisor) :report))))))

(deftest a-spent-day-cap-skips-t2-too ()
  (with-scratch-world (store supervisor)
    (setf (enchiridion.kernel:agent-budget (agent-of supervisor))
          '(:max-tokens-per-tick 10 :max-tokens-per-day 20))
    (enchiridion.memory.store:record-usage store :model "counting" :input 15 :output 15)
    (let ((enchiridion.memory:*t2-enabled-p* t))
      (ok (search "T2 skipped: the day cap is spent"
                  (getf (enchiridion.kernel:heartbeat supervisor) :report))))))

(deftest compaction-requires-four-new-rows-after-each-pass ()
  (with-scratch-world (store supervisor)
    (flet ((add-turn ()
             (enchiridion.memory.store:record-turn
              store :session "operator" :role "user" :body "new turn"))
           (compact ()
             (enchiridion.kernel::compact-when-due supervisor store (agent-of supervisor))))
      (dotimes (i 4) (add-turn))
      (ok (compact))
      (ok (= 1 (calls-made supervisor)))
      (dotimes (i 3)
        (add-turn)
        (enchiridion.memory.store:record-turn
         store :session "sleep" :channel :sleep :role "assistant" :body "sleep output")
        (ng (compact))
        (ok (= 1 (calls-made supervisor))))
      (add-turn)
      (ok (compact))
      (ok (= 2 (calls-made supervisor)))
      (ok (= 2 (length (projection-rows store)))))))

(deftest a-blank-compaction-keeps-its-window-and-reports-the-retry ()
  ;; The paid call that returns nothing must not advance the cursor: with the
  ;; four-new-row gate, advancing on a blank answer drops the whole window.
  (with-scratch-world (store supervisor)
    (flet ((add-turn (index)
             (enchiridion.memory.store:record-turn
              store :session "operator" :role "user"
              :body (format nil "turn ~D" index))))
      (dotimes (index 4) (add-turn index))
      (setf (counting-backend-reply (backend-of supervisor)) "")
      (enchiridion.memory.store:set-session-block store "the session so far")
      (let ((cursor (enchiridion.supervisor:supervisor-last-compacted-turn supervisor))
            (first-report (enchiridion.kernel:heartbeat supervisor)))
        (testing "the blank answer is visible in the phase report"
          (ok (search "compaction produced no text" (getf first-report :report))))
        (testing "and the cursor, the block and the projections are untouched"
          (ok (= cursor
                 (enchiridion.supervisor:supervisor-last-compacted-turn supervisor)))
          (ok (null (projection-rows store)))
          (ok (string= "the session so far"
                      (enchiridion.memory.store:session-block store))))
        (testing "the next tick summarises the same four rows"
          (setf (counting-backend-reply (backend-of supervisor)) "done")
          (let ((second-report (enchiridion.kernel:heartbeat supervisor)))
            (ok (search "the session block was compacted" (getf second-report :report)))
            (ok (= 1 (length (projection-rows store))))
            (ok (search "turn 0"
                        (counting-backend-last-prompt (backend-of supervisor))))
            (let ((row (first (projection-rows store))))
              (ok (= 3 (- (enchiridion.memory.store:field row "to_turn")
                          (enchiridion.memory.store:field row "from_turn")))))))))))

;;;; Dense embedding inside the tick.

(deftest a-window-that-keeps-refusing-stops-paying-every-tick ()
  ;; A model that overshoots the block limit refuses the same four turns every
  ;; time, and the heartbeat used to buy that refusal every fifteen minutes.
  (with-scratch-world (store supervisor)
    (flet ((add-turn (index)
             (enchiridion.memory.store:record-turn
              store :session "operator" :role "user"
              :body (format nil "turn ~D" index))))
      (dotimes (index 4) (add-turn index))
      (setf (counting-backend-reply (backend-of supervisor)) "")
      (let ((cursor (enchiridion.supervisor:supervisor-last-compacted-turn supervisor)))
        (testing "the first empty answer is reported"
          (ok (search "compaction produced no text"
                      (getf (enchiridion.kernel:heartbeat supervisor) :report))))
        (testing "and the same window gets its one retry"
          (ok (search "compaction produced no text"
                      (getf (enchiridion.kernel:heartbeat supervisor) :report))))
        (testing "then the window is held instead of bought again"
          (let ((calls (calls-made supervisor)))
            (ok (null (enchiridion.kernel::compact-when-due
                       supervisor store (agent-of supervisor))))
            (ok (= calls (calls-made supervisor))
                "no model call for a window that has used its attempts")
            (ok (= cursor
                   (enchiridion.supervisor:supervisor-last-compacted-turn supervisor))
                "the cursor did not advance over unsaved turns")))
        (testing "a newer turn makes the window worth offering again"
          (add-turn 4)
          (setf (counting-backend-reply (backend-of supervisor)) "done")
          (ok (search "the session block was compacted"
                      (getf (enchiridion.kernel:heartbeat supervisor) :report)))
          (ok (= 1 (length (projection-rows store)))))))))

(deftest an-over-limit-compaction-answer-changes-nothing-and-says-so ()
  ;; The session block holds four hundred characters. A longer answer used to
  ;; signal out of the phase and mark the tick failed; the outcome is that
  ;; nothing changes, so it comes back as a reported no-op.
  (with-scratch-world (store supervisor)
    (flet ((add-turn (index)
             (enchiridion.memory.store:record-turn
              store :session "operator" :role "user"
              :body (format nil "turn ~D" index))))
      (dotimes (index 4) (add-turn index))
      (setf (counting-backend-reply (backend-of supervisor))
            (make-string 500 :initial-element #\x))
      (enchiridion.memory.store:set-session-block store "the session so far")
      (let ((cursor (enchiridion.supervisor:supervisor-last-compacted-turn supervisor))
            (report (enchiridion.kernel:heartbeat supervisor)))
        (testing "the tick succeeds and says why the answer was refused"
          (ok (getf report :ok-p))
          (ok (search "compaction produced nothing usable" (getf report :report))))
        (testing "and the block, the cursor and the projections are untouched"
          (ok (= cursor
                 (enchiridion.supervisor:supervisor-last-compacted-turn supervisor)))
          (ok (null (projection-rows store)))
          (ok (string= "the session so far"
                       (enchiridion.memory.store:session-block store))))))))

(deftest a-t2-refusal-reads-as-a-sentence ()
  ;; The refusal is a keyword, and the report is a line an operator reads:
  ;; ":pass-budget-spent" is neither.
  (with-scratch-world (store supervisor)
    (let ((enchiridion.memory:*t2-enabled-p* t)
          (enchiridion.memory:*t2-max-tokens-per-pass* 1000))
      (enchiridion.memory.store:record-usage store :model "m" :input 1000 :output 0
                                                   :channel :t2)
      (let ((report (getf (enchiridion.kernel:heartbeat supervisor) :report)))
        (ok (search "T2 skipped: the pass budget is spent" report))
        (ng (search ":pass-budget-spent" report))))))

(deftest a-spent-cap-skips-the-embedding-phase ()
  (with-scratch-world (store supervisor)
    (let ((calls (list 0)))
      (enchiridion.memory.store:record-turn
       store :session "s" :role "user" :body "an episode with no vector yet")
      (let ((enchiridion.memory:*memory-embedder*
              (lambda (texts)
                (incf (car calls))
                (mapcar (lambda (text) (declare (ignore text)) (vector 1.0 0.0))
                        texts)))
            (enchiridion.memory:*memory-embed-model* "m")
            (enchiridion.memory::*memory-embed-settings* '(:dimensions 2)))
        ;; The day window counts every channel and every earlier second, so a
        ;; row written before the tick is what a mid-tick phase can find spent.
        (setf (enchiridion.kernel:agent-budget (agent-of supervisor))
              '(:max-tokens-per-tick 4000 :max-tokens-per-day 100))
        (enchiridion.memory.store:record-usage store :input 4000 :output 0
                                                     :channel :sleep)
        (let ((report (getf (enchiridion.kernel:heartbeat supervisor) :report)))
          (testing "the phase is skipped with the reason"
            (ok (search "memory embedding skipped" report))
            (ok (search "day cap" report)))
          (testing "and no paid request started"
            (ok (zerop (car calls)))
            (ok (null (enchiridion.memory.store:query-rows
                       store "SELECT * FROM episode_vectors")))))))))

(deftest embedding-spend-counts-toward-the-tick ()
  (with-scratch-world (store supervisor)
    (let ((agent (agent-of supervisor))
          (start (enchiridion.kernel::store-total store)))
      (setf (enchiridion.kernel:agent-budget agent)
            '(:max-tokens-per-tick 100 :max-tokens-per-day 400000))
      (enchiridion.memory.store:record-usage store :input 100 :output 0
                                                   :channel :embed)
      (testing "the embedding row is this tick's spend"
        (ok (= 100 (- (enchiridion.kernel::store-total store) start))))
      (testing "and the tick cap then refuses the next phase"
        (ok (search "tick cap"
                    (enchiridion.kernel::budget-refusal agent store start 0)))))))

;;;; Adaptation.

(defun adaptation-text (directory)
  "Return ADAPT.md for DIRECTORY, or the empty string."
  (let ((path (enchiridion.kernel:adaptation-path directory)))
    (if (probe-file path) (uiop:read-file-string path) "")))

(defun adaptation-write-for-test (directory text)
  "Write TEXT as ADAPT.md without the evidence checks, as a model would."
  (let ((path (enchiridion.kernel:adaptation-path directory)))
    (ensure-directories-exist path)
    (with-open-file (stream path :direction :output
                                  :if-exists :supersede
                                  :if-does-not-exist :create
                                  :external-format :utf-8)
      (write-string text stream))
    text))

(defun proposal (kind category text evidence &optional quote)
  "Return one adaptation proposal as the plist the apply path takes."
  (list :kind kind :category category :text text
        :evidence evidence :quote quote))

(defun proposal-table (kind category text evidence &optional quote)
  "Return a jzon object for one adaptation proposal file."
  (let ((table (make-hash-table :test #'equal)))
    (setf (gethash "kind" table) kind
          (gethash "category" table) category
          (gethash "text" table) text
          (gethash "evidence" table) (coerce evidence 'vector))
    (when quote (setf (gethash "quote" table) quote))
    table))

(defun write-proposal (directory kind category text evidence &optional quote)
  "Write one proposal file under DIRECTORY and return its path."
  (let ((path (enchiridion.kernel:adaptation-proposal-path directory)))
    (ensure-directories-exist path)
    (with-open-file (stream path :direction :output
                                  :if-exists :supersede
                                  :if-does-not-exist :create
                                  :external-format :utf-8)
      (write-string (com.inuoe.jzon:stringify
                     (proposal-table kind category text evidence quote))
                    stream))
    path))

(defun add-user-turns (store count &key (session "operator") (ts (get-universal-time)))
  "Add COUNT ordinary operator turns and return their ids."
  (loop repeat count
        collect (enchiridion.memory.store:turn-row-id
                 (enchiridion.memory.store:record-turn
                  store :session session :role "user"
                  :body (format nil "operator turn ~D" (random most-positive-fixnum))
                  :ts ts))))

(defun add-experienced-sessions (store count)
  "Add COUNT sessions that each hold two tool results and an answer."
  (dotimes (index count)
    (let ((session (format nil "work-~D" index)))
      (enchiridion.memory.store:record-turn
       store :session session :role "tool" :body "ran a command")
      (enchiridion.memory.store:record-turn
       store :session session :role "tool" :body "ran another command")
      (enchiridion.memory.store:record-turn
       store :session session :role "assistant" :body "answered from the result"))))

(deftest the-bearing-starts-by-emulating-and-fades-with-both-terms ()
  (with-scratch-world (store supervisor)
    (let ((enchiridion.kernel::+adaptation-memory-full+ 6)
          (enchiridion.kernel::+adaptation-experience-full+ 2))
      (testing "a fresh agent borrows the operator's style"
        (ok (search "Emulate the operator"
                    (enchiridion.kernel:adaptation-bearing
                     (enchiridion.kernel:adaptation-maturity store)))))
      (add-user-turns store 6)
      (testing "memory alone does not age it"
        (ok (search "Emulate the operator"
                    (enchiridion.kernel:adaptation-bearing
                     (enchiridion.kernel:adaptation-maturity store)))))
      (add-experienced-sessions store 2)
      (testing "memory and corroborated experience together reach its own defaults"
        (ok (search "your own defaults"
                    (enchiridion.kernel:adaptation-bearing
                     (enchiridion.kernel:adaptation-maturity store)))))
      (testing "and elapsed time is not a term"
        (add-user-turns store 1 :ts 0)
        (ok (search "your own defaults"
                    (enchiridion.kernel:adaptation-bearing
                     (enchiridion.kernel:adaptation-maturity store))))))))

(deftest sleep-output-does-not-age-the-bearing ()
  (with-scratch-world (store supervisor)
    (let ((enchiridion.kernel::+adaptation-memory-full+ 2)
          (enchiridion.kernel::+adaptation-experience-full+ 1))
      (let ((before (enchiridion.kernel:adaptation-maturity store)))
        (dotimes (index 10)
          (enchiridion.memory.store:record-turn
           store :session "sleep" :role "assistant" :body "consolidated"
           :channel :sleep))
        (ok (= before (enchiridion.kernel:adaptation-maturity store)))))))

(deftest the-bearing-line-moves-in-adapt-md ()
  (with-scratch-world (store supervisor)
    (let ((enchiridion.kernel::+adaptation-memory-full+ 4)
          (enchiridion.kernel::+adaptation-experience-full+ 2))
      (let ((directory (enchiridion.supervisor:supervisor-directory supervisor))
            (agent (agent-of supervisor)))
        (enchiridion.kernel:adaptation-begin agent store)
        (testing "the first file carries the early bearing"
          (ok (search "Emulate the operator" (adaptation-text directory))))
        (add-user-turns store 4)
        (add-experienced-sessions store 2)
        (enchiridion.kernel:adaptation-begin agent store)
        (testing "and the next pass carries the late one"
          (ok (search "your own defaults" (adaptation-text directory))))))))

(deftest an-explicit-operator-correction-sticks-immediately ()
  (with-scratch-world (store supervisor)
    (let* ((directory (enchiridion.supervisor:supervisor-directory supervisor))
           (turn (first (add-user-turns store 1)))
           (result (enchiridion.kernel:adaptation-apply-proposal
                    store directory
                    (proposal "explicit" "style" "Answer in one paragraph."
                              (list turn) "operator turn"))))
      (ok (eq :applied (getf result :status)))
      (ok (search "Answer in one paragraph." (adaptation-text directory)))
      (testing "and the late bearing does not delete it"
        (let ((enchiridion.kernel::+adaptation-memory-full+ 1)
              (enchiridion.kernel::+adaptation-experience-full+ 1))
          (add-experienced-sessions store 1)
          (enchiridion.kernel:adaptation-begin (agent-of supervisor) store)
          (ok (search "Answer in one paragraph." (adaptation-text directory)))
          (ok (search "your own defaults" (adaptation-text directory))))))))

(deftest an-inferred-preference-needs-separate-operator-turns ()
  (with-scratch-world (store supervisor)
    (let* ((directory (enchiridion.supervisor:supervisor-directory supervisor))
           (ids (add-user-turns store 3)))
      (testing "two turns are an incident"
        (let ((result (enchiridion.kernel:adaptation-apply-proposal
                       store directory
                       (proposal "inferred" "style" "Prefer terse replies."
                                 (subseq ids 0 2)))))
          (ok (eq :refused (getf result :status)))
          (ng (search "Prefer terse replies." (adaptation-text directory)))))
      (testing "three separate turns are a pattern"
        (let ((result (enchiridion.kernel:adaptation-apply-proposal
                       store directory
                       (proposal "inferred" "style" "Prefer terse replies."
                                 ids))))
          (ok (eq :applied (getf result :status)))
          (ok (search "Prefer terse replies." (adaptation-text directory)))))
      (testing "and a repeated id is not separate evidence"
        (let ((result (enchiridion.kernel:adaptation-apply-proposal
                       store directory
                       (proposal "inferred" "style" "Prefer numbered lists."
                                 (list (first ids) (first ids) (second ids))))))
          (ok (eq :refused (getf result :status))))))))

(deftest an-adaptation-cannot-name-an-enforced-bound ()
  (with-scratch-world (store supervisor)
    (let* ((directory (enchiridion.supervisor:supervisor-directory supervisor))
           (turn (first (add-user-turns store 1))))
      (dolist (category '("tools" "permissions" "refusals" "bootstrap"))
        (testing category
          (ok (eq :refused
                  (getf (enchiridion.kernel:adaptation-apply-proposal
                         store directory
                         (proposal "explicit" category "Change the rule."
                                   (list turn) "operator turn"))
                        :status)))))
      (testing "and the text cannot rename a bound as a style"
        (ok (eq :refused
                (getf (enchiridion.kernel:adaptation-apply-proposal
                       store directory
                       (proposal "explicit" "style" "Change tool access."
                                 (list turn) "operator turn"))
                      :status))))
      (testing "an explicit correction still needs its quote"
        (ok (eq :refused
                (getf (enchiridion.kernel:adaptation-apply-proposal
                       store directory
                       (proposal "explicit" "style" "Answer briefly."
                                 (list turn)))
                      :status)))))))

(deftest one-change-per-pass-and-a-direct-write-is-reverted ()
  (with-scratch-world (store supervisor)
    (let ((enchiridion.kernel::+adaptation-memory-full+ 2)
          (enchiridion.kernel::+adaptation-experience-full+ 1)
          (directory (enchiridion.supervisor:supervisor-directory supervisor))
          (agent (agent-of supervisor)))
      (add-user-turns store 2)
      (add-experienced-sessions store 1)
      (adaptation-write-for-test
       directory
       (enchiridion.kernel::adaptation-template
        (enchiridion.kernel:adaptation-bearing 0)))
      (let ((state (enchiridion.kernel:adaptation-begin agent store)))
        (testing "the bearing moved, so it is this pass's one change"
          (ok (enchiridion.kernel::adaptation-pass-changed-p state))
          (let ((turn (first (add-user-turns store 1))))
            (write-proposal directory "explicit" "style" "Answer in one paragraph."
                            (list turn) "operator turn"))
          (let ((result (enchiridion.kernel:adaptation-finish state store)))
            (ok (eq :bearing (getf result :status)))
            (let ((rows (enchiridion.kernel:adaptation-rows store)))
              (ok (= 1 (length rows)))
              (ok (string= "bearing"
                           (enchiridion.memory.store:field (first rows) "kind")))
              (ok (search "memory"
                          (enchiridion.memory.store:field (first rows) "evidence"))))
            (ng (search "Answer in one paragraph." (adaptation-text directory))))))
      (testing "a pass with a settled bearing may apply one proposal"
        (let* ((state (enchiridion.kernel:adaptation-begin agent store))
               (turn (first (add-user-turns store 1))))
          (write-proposal directory "explicit" "style" "Answer in one paragraph."
                          (list turn) "operator turn")
          (let ((result (enchiridion.kernel:adaptation-finish state store)))
            (ok (eq :applied (getf result :status)))
            (ok (search "Answer in one paragraph." (adaptation-text directory)))
            (let ((rows (enchiridion.kernel:adaptation-rows store)))
              (ok (= 2 (length rows)))
              (ok (string= "explicit"
                           (enchiridion.memory.store:field (first rows) "kind")))))))
      (testing "a direct write bypasses the evidence and is put back"
        (let ((state (enchiridion.kernel:adaptation-begin agent store)))
          (adaptation-write-for-test
           directory
           (concatenate 'string (adaptation-text directory)
                        "- [explicit, style, turn 1] Direct write." (string #\Newline)))
          (let ((result (enchiridion.kernel:adaptation-finish state store)))
            (ok (eq :direct-reverted (getf result :status)))
            (ng (search "Direct write." (adaptation-text directory)))))))))

(deftest an-adaptation-can-be-reverted ()
  (with-scratch-world (store supervisor)
    (let* ((directory (enchiridion.supervisor:supervisor-directory supervisor))
           (turn (first (add-user-turns store 1)))
           (before (adaptation-text directory))
           (result (enchiridion.kernel:adaptation-apply-proposal
                    store directory
                    (proposal "explicit" "style" "Answer in one paragraph."
                              (list turn) "operator turn"))))
      (ok (eq :applied (getf result :status)))
      (let ((revert (enchiridion.kernel:revert-adaptation
                     store directory (getf result :id))))
        (ok (getf revert :reverted-p))
        (ok (string= before (adaptation-text directory))))
      (testing "and it cannot be reverted twice"
        (ng (getf (enchiridion.kernel:revert-adaptation
                   store directory (getf result :id))
                  :reverted-p))))))

(deftest one-tool-session-is-not-corroborated-experience ()
  (with-scratch-world (store supervisor)
    (let ((enchiridion.kernel::+adaptation-memory-full+ 10)
          (enchiridion.kernel::+adaptation-experience-full+ 1))
      (enchiridion.memory.store:record-turn
       store :session "single" :role "tool" :body "ran once")
      (enchiridion.memory.store:record-turn
       store :session "single" :role "assistant" :body "answered once")
      (ok (zerop (enchiridion.kernel::adaptation-experience-count store)))
      (testing "a second result in the same session corroborates it"
        (enchiridion.memory.store:record-turn
         store :session "single" :role "tool" :body "ran again")
        (ok (= 1 (enchiridion.kernel::adaptation-experience-count store)))))))

(deftest the-adaptation-block-reaches-the-prompt ()
  (with-scratch-world (store supervisor)
    (let ((directory (enchiridion.supervisor:supervisor-directory supervisor)))
      (enchiridion.kernel:adaptation-begin (agent-of supervisor) store)
      (let ((fresh (enchiridion.kernel:make-agent
                    :directory directory :store store)))
        (ok (search "Bearing:" (enchiridion.kernel:prompt-text
                                (enchiridion.kernel:agent-snapshot fresh))))
        (ok (search "enforced in code" (enchiridion.kernel:prompt-text
                                        (enchiridion.kernel:agent-snapshot fresh))))))))

(deftest adaptation-is-silent-in-the-tick-report ()
  (with-scratch-world (store supervisor)
    (add-user-turns store 1)
    (let ((report (getf (enchiridion.kernel:heartbeat supervisor) :report)))
      (ok (search "maintenance pass" report))
      (testing "the adaptation work is inside the one maintenance call"
        (ok (= 1 (calls-made supervisor))))
      (dolist (word '("adapt" "bearing" "emulat" "preference"))
        (testing word
          (ng (search word (string-downcase report))))))))
