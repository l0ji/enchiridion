;;;; sleep.cl --- The heartbeat, the sleep agent, and compaction.
;;;;
;;;; Unattended work happens on a tick. A tick claims one queued task and runs
;;;; it, or runs one maintenance turn when there is something new to look at,
;;;; and it rewrites the two harness blocks on the way through. Nothing here
;;;; runs in the reply path: the operator's turn and a tick share the agent
;;;; and the store, and the agent's own lock is what keeps them from
;;;; interleaving.
;;;;
;;;; The sleep agent is a second agent over the same directory and the same
;;;; broker. It exists because identity files and the prompt are two different
;;;; jobs: the operator's agent answers, and this one consolidates. It is built
;;;; fresh on every tick, so the prompt it compiles contains the block files as
;;;; the last tick left them; a cached snapshot would hide the pass's own work.
;;;;
;;;; A tick is bounded by the same budget caps as any other unattended work. A
;;;; phase the cap cannot afford is skipped with a reason rather than started
;;;; and abandoned, and the day window is the rolling twenty-four hours the
;;;; ledger uses, so a burst across midnight still counts in full.

(in-package #:enchiridion.kernel)

;;;; What a pass is told.

(defparameter +sleep-task-prompt+
  "The operator queued this task for you:"
  "The line that turns a task body into a turn.")

(defparameter +sleep-maintenance-prompt+
  "Review what has happened since the last pass. Search the transcript if you need to. Update SOUL.md, OPERATOR.md or WORLD.md only where something new was actually learned, and add or patch nothing if nothing changed. Answer in one line with what you did, or with nothing to change."
  "The standing instruction a maintenance pass runs with. It is deliberately
short and it says do nothing when nothing changed: a pass that always writes is
a pass that spends tokens to churn the files.")

(defparameter +compaction-brief+
  "You compact an agent's session memory. You are given the previous summary and the most recent turns. Answer with the new session block only: plain prose, no headings, at most four hundred characters, about what the agent is doing and what it has learned."
  "The system brief the compactor agent runs under. It replaces the personality
blocks rather than adding to them: a summariser does not need to know who it
is, and every block is tokens in every compaction call.")

(defparameter +compaction-turns+ 4
  "How many new turns make compaction worth a model call.
Fewer than this is the ordinary case after one exchange, and a summary of two
turns is a worse session block than no summary at all.")

(defparameter +task-prompt-limit+ 4000
  "How much of a task body reaches the prompt. The row keeps the whole body;
only the text sent to the model is cut, and the cut is reported.")

(defparameter +recent-turn-limit+ 400
  "How much of one turn reaches a compaction prompt.")

;;;; The task queue, as the kernel promises it.

(declaim (ftype (function (t &key (:limit integer) (:status t)) list) task-queue))

(defun task-queue (store &key (limit 100) status)
  "Return the queued tasks oldest first, or only the ones with STATUS.
A thin wrapper over the store, because the kernel exports these names and the
storage belongs in one place."
  (enchiridion.memory.store:list-tasks store :limit limit :status status))

(declaim (ftype (function (t string &key (:ts t)) t) enqueue-task))

(defun enqueue-task (store body &key (ts (get-universal-time)))
  "Add BODY to the queue as a pending task and return it as a task row."
  (enchiridion.memory.store:enqueue-task store body :ts ts))

(declaim (ftype (function (t) t) dequeue-task))

(defun dequeue-task (store)
  "Claim the oldest pending task and return it as a task row, or NIL.
A claim, not a completion: the row is running while the work runs, so a
process that dies mid-task leaves evidence rather than a task marked done."
  (enchiridion.memory.store:dequeue-task store))

(declaim (ftype (function (t &key (:status t)) integer) task-queue-length))

(defun task-queue-length (store &key (status :pending))
  "Return how many tasks are waiting, or how many have STATUS."
  (enchiridion.memory.store:count-tasks store :status status))

;;;; Small helpers.

(declaim (ftype (function (string integer) string) shorten))

(defun shorten (text limit)
  "Return TEXT cut to LIMIT characters, with an ellipsis when it was cut.
A summary prompt that carries whole turns is a prompt that grows with the
transcript, which is the thing summarising exists to prevent."
  (if (<= (length text) limit)
      text
      (concatenate 'string (subseq text 0 (max 0 (- limit 3))) "...")))

(declaim (ftype (function (t) string) task-prompt))

(defun task-prompt (task)
  "Return the user text one queued task is run with.
The body is cut at +TASK-PROMPT-LIMIT+; the row keeps all of it, and the
heartbeat reports that the cut happened."
  (let ((body (enchiridion.memory.store:task-row-body task)))
    (format nil "~A~%~A~%When you are done, say in one line what you did."
            +sleep-task-prompt+
            (shorten body +task-prompt-limit+))))

;;;; The sleep agent.

(declaim (ftype (function (&key (:directory t) (:backend t) (:budget t)
                                (:broker t) (:store t))
                          agent)
                sleep-agent))

(defun sleep-agent (&key directory backend budget broker store)
  "Return an agent for one sleep pass.

It is built fresh on every tick so that the prompt is compiled from the block
files as the last pass left them. The three seed-backed blocks are writable
here, which is the one difference from the operator's agent: this agent owns
identity after handover and the operator's agent only reads it."
  (let ((agent (make-agent :name "sleep"
                           :backend backend
                           :directory directory
                           :budget budget
                           :broker broker
                           :store store)))
    (dolist (block (agent-blocks agent))
      (when (member (enchiridion.memory:block-label block)
                    '(:persona :operator :world)
                    :test #'eq)
        (setf (enchiridion.memory:block-writable-p block) t)))
    agent))

(declaim (ftype (function (agent) agent) compactor-agent))

(defun compactor-agent (agent)
  "Return an agent that only summarises: no personality, no tools.

No tools because a summariser that can call tools can change the thing it is
summarising, and the tool schemas are tokens paid on every compaction call for
a capability the pass does not use."
  (make-agent :name "compactor"
              :backend (agent-backend agent)
              :blocks (list (enchiridion.memory:make-block
                             :label :persona
                             :text +compaction-brief+))
              :tools-p nil
              :budget (agent-budget agent)))

;;;; One sleep pass.

(declaim (ftype (function (agent t &key (:task t) (:channel keyword) (:model t)) list)
                run-sleep-pass))

(defun run-sleep-pass (agent store &key task (channel :sleep)
                                        (model (enchiridion:model-for :sleep)))
  "Run one sleep pass and return a plist describing what happened.

One task per pass. The tick cap is a few thousand tokens and a task is a full
turn with tools, so draining the queue in one pass would make a single tick
unbounded and the cap meaningless.

The session is the pass's own and is closed afterwards: the operator's session
is never written to by unattended work, and the transcript still records every
turn under the channel that made it."
  (let ((session (make-session :agent agent))
        (text (if task (task-prompt task) +sleep-maintenance-prompt+)))
    (unwind-protect
         (handler-case
             (let ((completion (run-turn agent text
                                         :model model
                                         :session session
                                         :store store
                                         :channel channel)))
               (when task
                 (enchiridion.memory.store:complete-task store (enchiridion.memory.store:task-row-id task)))
               (list :ran-p t
                     :task-id (and task (enchiridion.memory.store:task-row-id task))
                     :status (if task :done :idle)
                     :reply (enchiridion.llm:completion-text completion)))
           (error (condition)
             (when task
               (enchiridion.memory.store:fail-task store (enchiridion.memory.store:task-row-id task)))
             (list :ran-p t
                   :task-id (and task (enchiridion.memory.store:task-row-id task))
                   :status :failed
                   :note (enchiridion.errors:condition-report-line condition)
                   :reply "")))
      (ignore-errors (end-session session)))))

;;;; Compaction.

(declaim (ftype (function (agent t &key (:model t)) (or null string))
                compact-session))

(defun compact-session (agent store &key (model (enchiridion:model-for :cheap)))
  "Rewrite the session block from the recent transcript and return it.

The previous block is the summary so far and the last few turns are verbatim:
that is the whole design, and it is why the prompt does not grow with the
transcript. The answer is scrubbed, scanned and checked against the block limit
by the store before it lands, so a model that answers with something oversized
or injected changes nothing and is reported instead."
  (let* ((previous (enchiridion.memory.store:session-block store))
         (recent (enchiridion.memory.store:recent-turns store
                                                        :limit +compaction-turns+
                                                        :not-channel :sleep))
         (user (format nil "Previous summary:~%~A~%~%Recent turns:~%~{~A~%~}"
                       (if (plusp (length previous)) previous "(none)")
                       (mapcar (lambda (row)
                                 (format nil "~A: ~A"
                                         (enchiridion.memory.store:turn-row-role row)
                                         (shorten (enchiridion.memory.store:turn-row-body row)
                                                  +recent-turn-limit+)))
                               recent)))
         (session (make-session :agent agent)))
    (unwind-protect
         (let* ((completion (run-turn agent user
                                      :model model
                                      :session session
                                      :store store
                                      :channel :sleep))
                (text (enchiridion.llm.secrets:scrub
                       (enchiridion.llm:completion-text completion))))
           (when (plusp (length text))
             (enchiridion.memory.store:set-session-block store text)
             text))
      (ignore-errors (end-session session)))))

;;;; The two harness blocks.

(declaim (ftype (function (t t) string) ledger-line))

(defun ledger-line (store session)
  "Return the one line the ledger block carries.

It is built to fit the block's limit by construction rather than truncated: the
line is in every prompt, and a block that silently loses its tail is a block
that lies about the spend."
  (let ((mine (enchiridion.memory.store:usage-session-total
               store (and session (session-id session))))
        (day (enchiridion.memory.store:usage-total-since
              store (- (get-universal-time) 86400))))
    (format nil "session in ~D out ~D cache r ~D w ~D calls ~D · day ~D"
            (getf mine :input) (getf mine :output)
            (getf mine :cache-read) (getf mine :cache-write)
            (getf mine :calls) (getf day :total))))

(declaim (ftype (function (enchiridion.supervisor:supervisor t) string)
                write-ledger-block))

(defun write-ledger-block (supervisor store)
  "Write the ledger block for this session and return it."
  (enchiridion.memory.store:set-ledger-block
   store (ledger-line store (enchiridion.supervisor:supervisor-session supervisor))))

(declaim (ftype (function (enchiridion.supervisor:supervisor t) (or null string))
                write-session-fallback))

(defun write-session-fallback (supervisor store)
  "Put one line of state in the session block when nothing has compacted it.
An empty session block is a blank line in every prompt; one sentence about the
queue is cheaper than the confusion. Compaction overwrites this."
  (when (zerop (length (enchiridion.memory.store:session-block store)))
    (enchiridion.memory.store:set-session-block
     store
     (format nil "Tick ~D. ~D task~:P waiting, ~D failed."
             (enchiridion.supervisor:supervisor-ticks supervisor)
             (enchiridion.memory.store:count-tasks store :status :pending)
             (enchiridion.memory.store:count-tasks store :status :failed)))))

;;;; The budget.

(declaim (ftype (function (agent t integer) (or null string)) budget-refusal))

(defun budget-refusal (agent store tick-start)
  "Return why no model call may start, or NIL.

Both the in-memory ledger and the store are consulted. The ledger only sees
this process; the store spans restarts, and a cap that resets every restart is
not a cap. The tick window starts where the caller says, which is the top of
this tick, so a long pass cannot pay for the next one."
  (let ((tick-cap (getf (agent-budget agent) :max-tokens-per-tick))
        (day-cap (getf (agent-budget agent) :max-tokens-per-day)))
    (cond
      ((budget-exhausted-p agent :window :tick) "the tick cap is spent")
      ((budget-exhausted-p agent :window :day) "the day cap is spent")
      ((and tick-cap store
            (>= (getf (enchiridion.memory.store:usage-total-since store tick-start)
                      :total)
                tick-cap))
       "the tick cap is spent")
      ((and day-cap store
            (>= (getf (enchiridion.memory.store:usage-total-since
                       store (- (get-universal-time) 86400))
                      :total)
                day-cap))
       "the day cap is spent")
      (t nil))))

(declaim (ftype (function (t t t) (or null string)) sleep-refusal))

(defun sleep-refusal (agent store directory)
  "Return why the sleep agent must not run, or NIL.
Each answer is a sentence the operator reads in `health`, so a pass that did
not happen is never silent."
  (cond
    ((null store) "no memory store is open")
    ((null agent) "no agent is attached")
    ((null (agent-backend agent)) "no model backend is configured")
    ((and directory (enchiridion.memory:bootstrap-refuse-writes-p directory))
     "bootstrap has not handed over, so the identity files are still the operator's")
    (t nil)))

;;;; The tick.

(declaim (ftype (function (enchiridion.supervisor:supervisor t agent t) string)
                run-sleep-phase))

(defun run-sleep-phase (supervisor store agent directory)
  "Claim one task, or run a maintenance pass when there is something new.

A tick with an empty queue and an unchanged transcript does nothing at all.
Idle work that calls a model anyway is a subscription to spending tokens on
nothing, and the honest report for it is one word."
  (let* ((task (dequeue-task store))
         (cursor (enchiridion.supervisor:supervisor-last-sleep-turn supervisor))
         (recent (enchiridion.memory.store:recent-turns store :limit 1
                                                              :not-channel :sleep))
         (newest (and recent (enchiridion.memory.store:turn-row-id (first recent)))))
    (flet ((pass (&key task)
             (run-sleep-pass (sleep-agent :directory directory
                                          :backend (agent-backend agent)
                                          :budget (agent-budget agent)
                                          :broker (agent-broker agent)
                                          :store store)
                             store :task task)))
      (cond
        (task
         (let ((result (pass :task task)))
           (format nil "task ~D ~(~A~)~@[: ~A~]"
                   (getf result :task-id) (getf result :status) (getf result :note))))
        ((and newest (> newest cursor))
         (let ((result (pass)))
           (setf (enchiridion.supervisor:supervisor-last-sleep-turn supervisor) newest)
           (format nil "maintenance pass~@[ (~A)~]" (getf result :note))))
        (t "idle")))))

(declaim (ftype (function (enchiridion.supervisor:supervisor t agent)
                          (or null string))
                compact-when-due))

(defun compact-when-due (supervisor store agent)
  "Rewrite the session block when enough new turns have arrived, else NIL.

The cursor lives on the supervisor rather than in a file: it is a position in
this process's reading of the transcript, and a restart re-reads the last few
turns once, which is harmless and bounded."
  (let ((cursor (enchiridion.supervisor:supervisor-last-compacted-turn supervisor))
        (recent (enchiridion.memory.store:recent-turns store
                                                       :limit +compaction-turns+
                                                       :not-channel :sleep)))
    (when (and (= (length recent) +compaction-turns+)
               (> (enchiridion.memory.store:turn-row-id (first recent)) cursor))
      (let ((compacted (compact-session (compactor-agent agent) store)))
        (setf (enchiridion.supervisor:supervisor-last-compacted-turn supervisor)
              (enchiridion.memory.store:turn-row-id (first recent)))
        (if compacted
            "the session block was compacted"
            nil)))))

(declaim (ftype (function (enchiridion.supervisor:supervisor) list) heartbeat))

(defun heartbeat (supervisor)
  "Run one heartbeat tick and return a plist of :OK-P and :REPORT.

The phases run in order and each one is guarded on its own: a failed phase is
reported and the later ones still run, because a store that refuses one write
should not also stop the queue. Nothing here signals, for the reason
SUPERVISOR-TICK gives.

Phase order is the design. Recovery first, so a task a dead process left
running is failed before anything looks at the queue. Then the ledger, so the
sleep agent's own prompt carries the spend of the pass before it. Then the
sleep agent. Then compaction, which is the only phase that may rewrite the
session block."
  (let* ((store (enchiridion.supervisor:supervisor-store supervisor))
         (agent (enchiridion.supervisor:supervisor-agent supervisor))
         (directory (enchiridion.supervisor:supervisor-directory supervisor))
         (tick-start (get-universal-time))
         (notes '())
         (ok-p t))
    (labels ((say (control &rest arguments)
               (push (apply #'format nil control arguments) notes))
             (attempt (name thunk)
               (handler-case (let ((line (funcall thunk)))
                               (when (and line (plusp (length line)))
                                 (say "~A" line)))
                 (error (condition)
                   (setf ok-p nil)
                   (say "~A failed: ~A" name
                        (enchiridion.errors:condition-report-line condition))))))
      (when store
        (attempt "task recovery"
                 (lambda ()
                   (let ((recovered (enchiridion.memory.store:recover-tasks store)))
                     (if (plusp recovered)
                         (format nil "~D interrupted task~:P failed" recovered)
                         nil)))))
      (when store
        (attempt "the harness blocks"
                 (lambda ()
                   (write-ledger-block supervisor store)
                   (write-session-fallback supervisor store)
                   nil)))
      (let ((refusal (or (sleep-refusal agent store directory)
                         (and store (budget-refusal agent store tick-start)))))
        (if refusal
            (say "sleep skipped: ~A" refusal)
            (attempt "the sleep agent"
                     (lambda () (run-sleep-phase supervisor store agent directory)))))
      (when (and store agent (null (budget-refusal agent store tick-start)))
        (attempt "compaction" (lambda () (compact-when-due supervisor store agent))))
      (list :ok-p ok-p
            :report (if notes (format nil "~{~A~^; ~}" (nreverse notes)) "idle")))))
