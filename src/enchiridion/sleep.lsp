;;;; sleep.lsp --- The heartbeat, the sleep agent, and compaction.
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

(defparameter +rebase-brief+
  "You rebuild an agent's session memory from its recent transcript alone. You are given only the raw turns, not any earlier summary. Answer with the new session block only: plain prose, no headings, at most four hundred characters, about what the agent is doing and what it has learned."
  "The brief a rebase pass runs under. It differs from the compaction brief in
one fact: there is no previous summary, which is the point of a rebase.")

(defparameter +characters-per-token+ 4
  "The characters a token is estimated to hold, for sizing a rebase before it
runs. A provider's own count is only known after the call, and a rebase is the
one compaction pass large enough that the estimate decides whether it starts.")

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
The body is cut at +TASK-PROMPT-LIMIT+ and the row keeps all of it. RUN-SLEEP-
PASS returns :CUT-P for the cut, and the tick report says so: a task answered
from its first four thousand characters of a hundred thousand is something the
operator has to be able to see."
  (let ((body (enchiridion.memory.store:task-row-body task)))
    (format nil "~A~%~A~%When you are done, say in one line what you did."
            +sleep-task-prompt+
            (shorten body +task-prompt-limit+))))

;;;; The sleep agent.

(declaim (ftype (function (&key (:directory t) (:backend t) (:budget t)
                                (:broker t) (:store t) (:lock t))
                          agent)
                sleep-agent))

(defun sleep-agent (&key directory backend budget broker store (lock nil))
  "Return an agent for one sleep pass.

It is built fresh on every tick so that the prompt is compiled from the block
files as the last pass left them. The three seed-backed blocks are writable
here, which is the one difference from the operator's agent: this agent owns
identity after handover and the operator's agent only reads it.

LOCK is the operator agent's lock when a tick has one. The sleep pass shares
the store, the directory, and the repository with an operator turn, so it must
share their lock; otherwise the two write in an order neither chose."
  (let ((agent (make-agent :name "sleep"
                           :backend backend
                           :directory directory
                           :budget budget
                           :broker broker
                           :store store
                           :lock lock)))
    (dolist (block (agent-blocks agent))
      (when (member (enchiridion.memory:block-label block)
                    '(:persona :operator :world)
                    :test #'eq)
        (setf (enchiridion.memory:block-writable-p block) t)))
    agent))

(declaim (ftype (function (agent &optional string) agent) compactor-agent))

(defun compactor-agent (agent &optional (brief +compaction-brief+))
  "Return an agent that only summarises under BRIEF: no personality, no tools.

No tools because a summariser that can call tools can change the thing it is
summarising, and the tool schemas are tokens paid on every compaction call for
a capability the pass does not use."
  (make-agent :name "compactor"
              :backend (agent-backend agent)
              :blocks (list (enchiridion.memory:make-block
                             :label :persona
                             :text brief))
              :tools-p nil
              :budget (agent-budget agent)
              ;; Compaction reads the transcript an operator turn writes and
              ;; rewrites the session block, so it takes the same lock.
              :lock (agent-lock agent)))

;;;; One sleep pass.

(declaim (ftype (function (agent t &key (:task t) (:channel keyword)
                                       (:model t) (:text t)
                                       (:start-total t) (:tick-index t)
                                       (:start-row t))
                          list)
                run-sleep-pass))

(defun run-sleep-pass (agent store &key task (channel :sleep)
                                        (model (enchiridion:model-for :sleep))
                                        text
                                        (start-total nil start-total-p)
                                        (tick-index nil tick-index-p)
                                        (start-row nil start-row-p))
  "Run one sleep pass and return a plist describing what happened.

One task per pass. The tick cap is a few thousand tokens and a task is a full
turn with tools, so draining the queue in one pass would make a single tick
unbounded and the cap meaningless.

The budget is checked before every round, not only before the pass. A task
with tools makes several requests, and checking once let the later rounds
spend far past the cap. START-ROW is the usage watermark when the heartbeat
began, so the store side is a row-id range rather than a scan of the ledger;
START-TOTAL is the lifetime fallback for a caller with no watermark. TICK-INDEX
is this agent's own ledger count at the pass's start, because the sleep agent
is built fresh and its ledger is not the supervisor's. The check uses the
usage the previous rounds actually recorded, so a request already in flight
can still finish over the cap. That is a soft cap and the stop reports the
real spend against it.

TEXT replaces the standing prompt for a maintenance pass. The maintenance pass
uses it to carry the evidence turns the adaptation rules cite.

The session is the pass's own and is closed afterwards: the operator's session
is never written to by unattended work, and the transcript still records every
turn under the channel that made it."
  (let* ((maintenance-p (null task))
         (start-total (cond (start-total-p start-total)
                            (start-row-p 0)
                            (t (store-total store))))
         (tick-index (if tick-index-p tick-index (if agent (spend-count agent) 0)))
         (pre-request (and agent
                           (sleep-pre-request agent store start-total tick-index
                                              :start-row (and start-row-p start-row))))
         (session (make-session :agent agent))
         (cut-p (and task (> (length (enchiridion.memory.store:task-row-body task))
                             +task-prompt-limit+)))
         (adaptation (and maintenance-p
                          (handler-case (adaptation-begin agent store)
                            (error () nil))))
         (prompt (or text (if task (task-prompt task) +sleep-maintenance-prompt+))))
    (unwind-protect
         (handler-case
             (let ((completion (run-turn agent prompt
                                         :model model
                                         :session session
                                         :store store
                                         :channel channel
                                         :pre-request pre-request)))
               (when task
                 (enchiridion.memory.store:complete-task store (enchiridion.memory.store:task-row-id task)))
               (list :ran-p t
                     :task-id (and task (enchiridion.memory.store:task-row-id task))
                     :status (if task :done :idle)
                     :cut-p cut-p
                     :adaptation (and maintenance-p
                                      (handler-case
                                          (adaptation-finish adaptation store
                                                             :success-p t)
                                        (error () nil)))
                     :reply (enchiridion.llm:completion-text completion)))
           (enchiridion.errors:budget-exceeded (condition)
             (when maintenance-p
               (ignore-errors (adaptation-finish adaptation store
                                                :success-p nil)))
             (when task
               ;; A budget stop is not a completion. The task failed with the
               ;; spend it had already made, and it is not requeued: a tool
               ;; earlier in the turn may already have run its side effect.
               (enchiridion.memory.store:fail-task store (enchiridion.memory.store:task-row-id task)))
             (list :ran-p t
                   :task-id (and task (enchiridion.memory.store:task-row-id task))
                   :status :failed
                   :budget-stopped-p t
                   :cut-p cut-p
                   :note (format nil "~A The task was failed and not retried."
                                 (enchiridion.errors:condition-report-line condition))
                   :reply ""))
           (error (condition)
             (when maintenance-p
               (ignore-errors (adaptation-finish adaptation store
                                                :success-p nil)))
             (when task
               (enchiridion.memory.store:fail-task store (enchiridion.memory.store:task-row-id task)))
             (list :ran-p t
                   :task-id (and task (enchiridion.memory.store:task-row-id task))
                   :status :failed
                   :cut-p cut-p
                   :note (enchiridion.errors:condition-report-line condition)
                   :reply "")))
      (ignore-errors (end-session session)))))

;;;; Compaction.

(declaim (ftype (function (agent t &key (:model t) (:rebase-p t))
                          (values (or null string) (or null string)))
                compact-session))

(defun compact-session (agent store &key (model (enchiridion:model-for :cheap))
                                         (rebase-p nil))
  "Rewrite the session block from the recent transcript and return the text.

The previous block is the summary so far and the last few turns are verbatim:
that is the whole design, and it is why the prompt does not grow with the
transcript. A REBASE-P pass reads the last *COMPACTION-REBASE-TURNS* turns and
no previous summary, so a summary of a summary cannot drift forever. The answer
is scrubbed, scanned and checked against the block limit by the store before it
lands, so a model that answers with something oversized or injected changes
nothing and is reported instead. A pass that lands records a projections row.
A refused block returns NIL and the refusal."
  (let* ((previous (if rebase-p "" (enchiridion.memory.store:session-block store)))
         (recent (enchiridion.memory.store:recent-turns
                  store
                  :limit (if rebase-p
                             enchiridion.memory:*compaction-rebase-turns*
                             +compaction-turns+)
                  :not-channel :sleep
                  ;; One character past the display limit: SHORTEN then cuts
                  ;; the same 397 characters and adds the ellipsis, and the
                  ;; prompt never reads a whole tool result to show 400.
                  :body-chars (1+ +recent-turn-limit+)))
         (user (format nil "~:[Previous summary:~%~A~%~%~;~*~]Recent turns:~%~{~A~%~}"
                       rebase-p
                       (if (plusp (length previous)) previous "(none)")
                       (mapcar (lambda (row)
                                 (format nil "~A: ~A"
                                         (enchiridion.memory.store:turn-row-role row)
                                         (shorten (enchiridion.memory.store:turn-row-body row)
                                                  +recent-turn-limit+)))
                               ;; RECENT-TURNS is newest first; a transcript
                               ;; reads oldest first.
                               (reverse recent))))
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
             ;; A summary the store refuses (over the block limit or tripping
             ;; the scan) is a reported no-op, and it records no projection.
             (multiple-value-bind (stored refusal)
                 (handler-case (enchiridion.memory.store:set-session-block store text)
                   (enchiridion.errors:block-overflow (condition)
                     (values nil (enchiridion.errors:condition-report-line condition)))
                   (enchiridion.errors:configuration-error (condition)
                     (values nil (enchiridion.errors:condition-report-line condition))))
               (if stored
                   (progn
                     (when recent
                       (record-projection store
                                          :from-turn (enchiridion.memory.store:turn-row-id
                                                      (car (last recent)))
                                          :to-turn (enchiridion.memory.store:turn-row-id
                                                    (first recent))
                                          :rebase-p rebase-p
                                          :model (enchiridion.llm:completion-model completion)
                                          :text text))
                     (values text nil))
                   (values nil refusal)))))
      (ignore-errors (progn (end-session session) nil)))))

(defun record-projection (store &key from-turn to-turn rebase-p model text
                                     (now (get-universal-time)))
  "Record that the session block was rebuilt from turns FROM-TURN..TO-TURN.
The row is what counts compaction passes across a restart, and what lets an
operator see whether the block was last rebuilt from raw turns."
  (enchiridion.memory.store:exec
   store
   "INSERT INTO projections (block, from_turn, to_turn, rebased_p, model, hash, ts)
      VALUES ('session', ?, ?, ?, ?, ?, ?)"
   (list from-turn to-turn (if rebase-p 1 0) model
         (enchiridion.memory:content-hash text) now)))

(defparameter +session-fallback-block+ "session-fallback"
  "The blocks row that remembers the harness's own fallback text.
It is a hash and not the text: the session block itself already holds the
words. Its only job is to let a later pass tell a fallback line, which is not a
summary, from a summary an earlier life left behind.")

(defun session-projection-count (store)
  "Return how many session-block projections have landed in STORE."
  (or (enchiridion.memory.store:field
       (first (enchiridion.memory.store:query-rows
               store "SELECT COUNT(*) AS n FROM projections
                       WHERE block = 'session'"))
       "n")
      0))

(defun fallback-session-block-p (store text)
  "Return T when TEXT is the harness's own fallback line, not a summary."
  (let ((row (first (enchiridion.memory.store:query-rows
                     store "SELECT body FROM blocks WHERE name = ?"
                     (list +session-fallback-block+)))))
    (and row
         (string= (enchiridion.memory.store:field row "body")
                  (enchiridion.memory:content-hash text)))))

(defun inherited-session-summary-p (store)
  "Return T when the session block holds text no projection here wrote.

A store imported from an earlier life, or one whose projections were lost, can
start with a summary and no row saying how it was made. Compacting from that
text would feed a stale summary back into the new block. The first pass reads
the raw turns instead, and the projection it records puts the store back on
the configured cadence."
  (let ((text (enchiridion.memory.store:session-block store)))
    (and (plusp (length text))
         (zerop (session-projection-count store))
         (not (fallback-session-block-p store text)))))

(defun compaction-rebase-due-p (store)
  "Return T when the next compaction pass should be a rebase.

A first pass over a nonempty block with no projection is a rebase: there is no
record that the text came from this transcript. Otherwise the cadence asks for
one rebase every *COMPACTION-REBASE-EVERY* ordinary passes, counted from
projections, so a restart keeps the position. An empty block is the normal
first compaction, not a rebase: there is no stale summary to avoid."
  (or (inherited-session-summary-p store)
      (let* ((every enchiridion.memory:*compaction-rebase-every*)
             (row (first (enchiridion.memory.store:query-rows
                          store
                          "SELECT COUNT(*) AS n FROM projections
                            WHERE block = 'session'
                              AND id > COALESCE((SELECT MAX(id) FROM projections
                                                  WHERE block = 'session'
                                                    AND rebased_p = 1), 0)"))))
        (and (integerp every) (plusp every)
             (>= (or (enchiridion.memory.store:field row "n") 0)
                 (1- every))))))

(defun rebase-token-estimate ()
  "Return the tokens a rebase pass is estimated to cost: its turns at their
display limit, its brief, and a full session block of answer."
  (ceiling (+ (* enchiridion.memory:*compaction-rebase-turns* +recent-turn-limit+)
              (length +rebase-brief+)
              (enchiridion.memory:default-block-limit :session))
           +characters-per-token+))

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
    (let ((text (format nil "Tick ~D. ~D task~:P waiting, ~D failed."
                        (enchiridion.supervisor:supervisor-ticks supervisor)
                        (enchiridion.memory.store:count-tasks store :status :pending)
                        (enchiridion.memory.store:count-tasks store :status :failed))))
      (enchiridion.memory.store:set-session-block store text)
      (enchiridion.memory.store:exec
       store
       "INSERT OR REPLACE INTO blocks (name, body, ts) VALUES (?, ?, ?)"
       (list +session-fallback-block+
             (enchiridion.memory:content-hash text)
             (get-universal-time)))
      nil)))

;;;; The budget.

(declaim (ftype (function (t) integer) store-total))

(defun store-total (store)
  "Return the tokens unattended work has spent, or zero.

Only the channels unattended work writes count: the sleep agent's own calls and
the embeddings the tick paid for. The tick's spend is the difference in this
number across the tick, and an operator turn answered on another channel while
the tick runs is the operator's spend, not the tick's: counting it let a busy
webhook use up the tick cap and stop the sleep agent."
  (if store
      (handler-case (getf (enchiridion.memory.store:usage-total-since
                           store 0 :channels '(:sleep :embed))
                          :total)
        (error () 0))
      0))

(declaim (ftype (function (t) integer) usage-watermark))

(defun usage-watermark (store)
  "Return the newest usage row id, or 0 when the ledger is empty.
A tick takes this before its first phase. Counting rows newer than it is a
primary-key range rather than a scan of the whole ledger, which is what a
check before every model request needs."
  (or (enchiridion.memory.store:field
       (first (enchiridion.memory.store:query-rows
               store "SELECT COALESCE(MAX(id), 0) AS n FROM usage"))
       "n")
      0))

(declaim (ftype (function (t integer) integer) store-tick-spend))

(defun store-tick-spend (store start-row)
  "Return the unattended tokens in usage rows newer than START-ROW.
The channel filter is the same one STORE-TOTAL uses, so a T2 pass and an
operator turn do not spend the tick cap."
  (let ((row (first (enchiridion.memory.store:query-rows
                     store
                     "SELECT SUM(input) AS input, SUM(output) AS output
                        FROM usage
                       WHERE id > ? AND channel IN ('sleep', 'embed')"
                     (list start-row)))))
    (+ (or (enchiridion.memory.store:field row "input") 0)
       (or (enchiridion.memory.store:field row "output") 0))))

(declaim (ftype (function (agent t integer integer &key (:start-row t)) integer)
                unattended-tick-spend))

(defun unattended-tick-spend (agent store start-total tick-index &key start-row)
  "Return the tokens unattended work has recorded since this tick began.

The store rows and the in-memory ledger are the same spend seen twice: the
store is what PERSIST-USAGE wrote, the ledger is what RECORD-SPEND kept. The
larger number is a lower bound on the real spend, not an exact sum: when a
store write fails the row survives only in memory, and a row a previous
surface recorded only in the store is not in this agent's ledger. It is still
conservative in the direction that matters, because either surface reaching
the cap refuses the next request.

START-ROW, when given, reads the store side as a row-id range, which is what
a per-request check uses. START-TOTAL is the lifetime total at the tick's
start and remains the fallback for callers that have no watermark. TICK-INDEX
is the in-memory ledger's count at the same moment, and only :SLEEP and :EMBED
rows count, because an operator turn on another channel is not the tick's."
  (let ((stored (if store
                    (if start-row
                        (store-tick-spend store start-row)
                        (max 0 (- (store-total store) start-total)))
                    0))
        (remembered 0))
    (dolist (row (spend-since agent tick-index))
      (when (member (spend-row-channel row) '(:sleep :embed) :test #'eq)
        (incf remembered (+ (spend-row-input row) (spend-row-output row)))))
    (max stored remembered)))

(declaim (ftype (function (agent t) integer) day-spend))

(defun day-spend (agent store)
  "Return the tokens every channel has spent in the last twenty-four hours.
The store is the history and the in-memory ledger is this process's recent
tail; taking the larger survives a store write that failed without counting
the same spend twice."
  (let ((stored (if store
                    (handler-case
                        (getf (enchiridion.memory.store:usage-total-since
                               store (- (get-universal-time) 86400))
                              :total)
                      (error () 0))
                    0)))
    (max stored (spend-total agent :window :day))))

(declaim (ftype (function (agent t integer integer &key (:start-row t))
                          (values integer integer))
                spend-pair))

(defun spend-pair (agent store start-total tick-index &key start-row)
  "Return two values: the tokens this tick has spent, and the last day's.

The tick's share counts the channels unattended work writes, on both surfaces
it can be read from, and is a lower bound when a write failed. The day window
counts every channel, so it bounds the process rather than one tick."
  (values (unattended-tick-spend agent store start-total tick-index
                                 :start-row start-row)
          (day-spend agent store)))

(declaim (ftype (function (agent t integer integer &key (:day-only t) (:start-row t))
                          (or null integer))
                budget-remaining))

(defun budget-remaining (agent store start-total tick-index &key (day-only nil)
                                                          start-row)
  "Return the most tokens this tick may still spend, or NIL when no cap binds.
DAY-ONLY asks the day cap alone, the way the T2 phase does. The answer is what
a phase that spends without a turn, such as the embedder, may offer one call."
  (multiple-value-bind (tick-spend day-spend)
      (spend-pair agent store start-total tick-index :start-row start-row)
    (let* ((tick-cap (and (not day-only)
                          (getf (agent-budget agent) :max-tokens-per-tick)))
           (day-cap (getf (agent-budget agent) :max-tokens-per-day))
           (tick-room (and tick-cap (max 0 (- tick-cap tick-spend))))
           (day-room (and day-cap (max 0 (- day-cap day-spend)))))
      (cond ((and tick-room day-room) (min tick-room day-room))
            (tick-room tick-room)
            (day-room day-room)
            (t nil)))))

(declaim (ftype (function (agent t integer integer &key (:reserve integer)
                                                         (:day-only t) (:start-row t))
                          (or null string))
                budget-refusal))

(defun budget-refusal (agent store start-total tick-index &key (reserve 0) (day-only nil)
                                                          start-row)
  "Return why no model call may start, or NIL. RESERVE is what the call is
expected to cost, so a large pass is refused before it can overrun the tick
cap rather than after.

START-TOTAL is the store's token total when this tick began, so what this tick
has spent is the difference. Measuring from a timestamp instead put a one
second window around the tick in which an operator's own turn counted as
unattended spend: with the shipped cap, a busy second disabled the sleep agent.

TICK-INDEX is the same idea for the in-memory ledger, which is the fallback
when no store is open. Both windows are this tick and not the life of the
process. The day window is the rolling twenty-four hours either way, because a
cap that resets at midnight is a cap that can be spent twice in a minute.

The day window counts every channel, T2 derivation on :t2 included, so the day
cap bounds the process's spend as a whole. The tick window counts the
unattended channels (:sleep and :embed), because a T2 pass is held to its own
pass and promotion caps and is designed to be larger than one tick. DAY-ONLY
asks the day window alone, which is how the T2 phase asks."
  (let ((tick-cap (and (not day-only) (getf (agent-budget agent) :max-tokens-per-tick)))
        (day-cap (getf (agent-budget agent) :max-tokens-per-day)))
    (multiple-value-bind (tick-spend day-spend)
        (spend-pair agent store start-total tick-index :start-row start-row)
      (cond
        ((and tick-cap (>= tick-spend tick-cap)) "the tick cap is spent")
        ((and tick-cap (plusp reserve) (> (+ tick-spend reserve) tick-cap))
         (format nil "the tick cap cannot cover a ~D token pass" reserve))
        ((and day-cap (>= day-spend day-cap)) "the day cap is spent")
        (t nil)))))

(declaim (ftype (function (agent t integer integer &key (:start-row t))
                          (or null condition))
                budget-stop-condition))

(defun budget-stop-condition (agent store start-total tick-index &key start-row)
  "Return a BUDGET-EXCEEDED condition when the next model request must not
start, or NIL.

The numbers come from BUDGET-REFUSAL's accounting, so the store and the
in-memory ledger are both read and the larger actual spend wins. A cap cannot
know what a reply will cost before it arrives: a request already in flight
finishes, its usage is recorded, and the next one is refused with the real
spend against the cap. That overshoot is visible in the condition rather than
hidden, which is the honest limit of a soft cap."
  (multiple-value-bind (tick-spend day-spend)
      (spend-pair agent store start-total tick-index :start-row start-row)
    (let ((tick-cap (getf (agent-budget agent) :max-tokens-per-tick))
          (day-cap (getf (agent-budget agent) :max-tokens-per-day)))
      (cond
        ((and tick-cap (>= tick-spend tick-cap))
         (make-condition 'enchiridion.errors:budget-exceeded
                         :spent tick-spend :cap tick-cap :window :tick))
        ((and day-cap (>= day-spend day-cap))
         (make-condition 'enchiridion.errors:budget-exceeded
                         :spent day-spend :cap day-cap :window :day))
        (t nil)))))

(defun sleep-pre-request (agent store start-total tick-index &key start-row)
  "Return the function RUN-TURN calls before each round of a sleep pass.

It signals BUDGET-EXCEEDED when the spend the previous rounds actually
recorded has reached a cap. The check is between requests, which is the only
place it can be: the call in flight still finishes and is billed, so a pass
can finish one request over the cap. A task stopped between rounds is failed
rather than requeued, because a tool earlier in the same turn may already have
run and repeating it would repeat its side effects."
  (lambda (round)
    (declare (ignore round))
    (let ((condition (budget-stop-condition agent store start-total tick-index
                                            :start-row start-row)))
      (when condition
        (error condition)))))

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

(declaim (ftype (function (agent t t) agent) sleep-pass-agent))

(defun sleep-pass-agent (agent directory store)
  "Return the sleep agent one tick runs, carrying AGENT's turn lock.
The lock is the operator's: the tick and a turn share the store, the directory,
and the repository."
  (sleep-agent :directory directory
               :backend (agent-backend agent)
               :budget (agent-budget agent)
               :broker (agent-broker agent)
               :store store
               :lock (agent-lock agent)))

(declaim (ftype (function (enchiridion.supervisor:supervisor t agent t
                                           &key (:start-row t))
                          string)
                run-sleep-phase))

(defun run-sleep-phase (supervisor store agent directory &key start-row)
  "Claim one task, or run a maintenance pass when there is something new.

A tick with an empty queue and an unchanged transcript does nothing at all.
Idle work that calls a model anyway is a subscription to spending tokens on
nothing, and the honest report for it is one word."
  (let* ((task (dequeue-task store))
         (cursor (enchiridion.supervisor:supervisor-last-sleep-turn supervisor))
         (recent (enchiridion.memory.store:recent-turns store :limit 1
                                                              :not-channel :sleep))
         (newest (and recent (enchiridion.memory.store:turn-row-id (first recent)))))
    (flet ((pass (&key task text)
             (run-sleep-pass (sleep-pass-agent agent directory store)
                             store :task task :text text
                                   :start-row start-row)))
      (cond
        (task
         (let ((result (pass :task task)))
           ;; Build the optional pieces as strings. A ~@[ clause takes its
           ;; argument from the argument list only when it is true, so passing
           ;; the cut limit unconditionally made an uncut report print the
           ;; limit as if it were the note.
           (format nil "task ~D ~(~A~)~A~A"
                   (getf result :task-id) (getf result :status)
                   (if (getf result :cut-p)
                       (format nil " (body cut to ~D characters)" +task-prompt-limit+)
                       "")
                   (if (getf result :note)
                       (format nil ": ~A" (getf result :note))
                       ""))))
        ((and newest (> newest cursor))
         (let* ((prompt (adaptation-maintenance-prompt
                         +sleep-maintenance-prompt+ directory store))
                (result (pass :text prompt)))
           (setf (enchiridion.supervisor:supervisor-last-sleep-turn supervisor) newest)
           ;; The adaptation status is internal. A pass reports that it ran,
           ;; not that the bearing moved or a preference was learned.
           (format nil "maintenance pass~@[ (~A)~]" (getf result :note))))
        (t "idle")))))

(declaim (ftype (function (enchiridion.supervisor:supervisor t agent &key (:rebase-p t))
                          (or null string))
                compact-when-due))

(defparameter +compaction-attempts-per-window+ 2
  "How many times one window of turns may be offered to the summariser.
A blank or over-limit answer is often transient, so one retry is worth paying.
After that the window waits for a newer turn, and the cursor does not advance,
so no turn is dropped.")

(defvar *compaction-window* nil
  "The window compaction last tried: (STORE-PATH NEWEST-TURN ATTEMPTS), or NIL.
Process local, like the cursor on the supervisor; a restart re-reads once.")

(defun compaction-window-key (store)
  "Return the key a compaction window is remembered under.
A reopened store is the same transcript; a test's scratch store is not."
  (let ((path (ignore-errors (enchiridion.memory.store:store-path store))))
    (if (pathnamep path) (namestring path) "")))

(defun compaction-window-attempts (store newest)
  "Return how many times the window ending at NEWEST has been offered."
  (let ((remembered *compaction-window*))
    (if (and remembered
             (equal (first remembered) (compaction-window-key store))
             (= (second remembered) newest))
        (third remembered)
        0)))

(defun note-compaction-attempt (store newest)
  "Record one attempt at the window ending at NEWEST and return the count."
  (let ((attempts (1+ (compaction-window-attempts store newest))))
    (setf *compaction-window* (list (compaction-window-key store) newest attempts))
    attempts))

(defun compaction-window-exhausted-p (store newest)
  "Return T when the window ending at NEWEST has used its attempts."
  (>= (compaction-window-attempts store newest) +compaction-attempts-per-window+))

(defun compact-when-due (supervisor store agent &key (rebase-p nil))
  "Rewrite the session block when enough new turns have arrived, else NIL.
REBASE-P makes the pass a rebase from raw turns.

The cursor lives on the supervisor rather than in a file: it is a position in
this process's reading of the transcript, and a restart re-reads the last few
turns once, which is harmless and bounded. A window that produced nothing is
offered at most +COMPACTION-ATTEMPTS-PER-WINDOW+ times."
  (let* ((cursor (enchiridion.supervisor:supervisor-last-compacted-turn supervisor))
         (recent (enchiridion.memory.store:recent-turns store
                                                        :limit +compaction-turns+
                                                        :not-channel :sleep))
         (newest (if recent (enchiridion.memory.store:turn-row-id (first recent)) 0)))
    (when (and (= (length recent) +compaction-turns+)
               (> (enchiridion.memory.store:turn-row-id (car (last recent))) cursor)
               (not (compaction-window-exhausted-p store newest)))
      (note-compaction-attempt store newest)
      (multiple-value-bind (compacted refusal)
          (compact-session (compactor-agent agent (if rebase-p
                                                      +rebase-brief+
                                                      +compaction-brief+))
                           store
                           :rebase-p rebase-p)
        (cond
          ;; A blank or refused answer spends the call and summarises nothing.
          ;; The cursor stays where it was, so the turns are not dropped and
          ;; the operator sees the paid retry.
          ((null compacted)
           (if refusal
               (format nil "compaction produced nothing usable: ~A" refusal)
               "compaction produced no text"))
          (t
           (setf (enchiridion.supervisor:supervisor-last-compacted-turn supervisor)
                 (enchiridion.memory.store:turn-row-id (first recent)))
           ;; The block moved: the next window is a new question.
           (setf *compaction-window* nil)
           (if rebase-p
               "the session block was rebuilt from raw turns"
               "the session block was compacted")))))))

(defun t2-refusal-line (refusal)
  "Return the sentence one T2 refusal is reported with.
A keyword is a reason and not a sentence: printing one with its leading colon
puts a Lisp symbol in a line the operator reads."
  (case refusal
    (:not-due "not due")
    (:disabled "memory is switched off")
    (:maintenance-pending "maintenance has a backlog to derive first")
    (:frozen-precision "promotion precision is frozen; reset it to lift the freeze")
    (:pass-budget-spent "the pass budget is spent")
    (:no-store "no memory store is open")
    (:no-deriver "no assertion deriver is installed")
    (t (string-downcase (string refusal)))))

(defun t2-report-line (report)
  "Return the heartbeat's sentence for one T2 pass REPORT."
  (let ((id (getf report :generation-id)))
    (let ((line
            (ecase (getf report :outcome)
              (:building (format nil "T2 building generation ~D (~D episode~:P remaining~@[; ~D skipped after two failed calls~]~@[; a deriver call failed: ~A~]~:[~;; another builder holds it~])"
                                 id (getf report :remaining)
                                 (let ((skipped (getf report :skipped)))
                                   (and skipped (plusp skipped) skipped))
                                 (getf report :failed)
                                 (getf report :claimed)))
              (:promoted (format nil "T2 generation ~D promoted" id))
              (:quarantined (format nil "T2 generation ~D quarantined at the ~A gate"
                                    id (getf report :failed)))
              (:held (format nil "T2 generation ~D held: promotion is frozen (~(~A~))"
                             id (getf report :freeze)))
              (:rolled-back (format nil "T2 rolled back generation ~D: its ~A check failed"
                                    id (getf report :failed)))
              (:instrument-missing (format nil "T2 skipped: instruments missing (~{~(~A~)~^, ~})"
                                           (getf report :missing)))
              (:skipped (format nil "T2 skipped: ~A"
                                (t2-refusal-line (getf report :reason)))))))
      (if (getf report :recovered)
          (format nil "~A (a candidate an earlier pass built and never gated)" line)
          line))))

(defun run-t2-phase (store agent start-total tick-index &key start-row)
  "Run one tick of T2 when it is due and allowed, and return the report line,
or NIL when T2 is off or the pass is not due. Neither says anything, because
otherwise every tick between two passes, or every tick of an agent whose
operator switched T2 off, would say so."
  (let ((refusal (or (enchiridion.memory:t2-refusal store)
                     (let ((budget (budget-refusal agent store start-total tick-index
                                                   :day-only t
                                                   :start-row start-row)))
                       (and budget (list budget))))))
    (cond
      ((member refusal '(:not-due :disabled)) nil)
      ((consp refusal) (format nil "T2 skipped: ~A" (first refusal)))
      (refusal (format nil "T2 skipped: ~A" (t2-refusal-line refusal)))
      (t (t2-report-line (enchiridion.memory:run-t2-pass store))))))

;;;; The store's own health and size.

(defparameter +store-report-interval-seconds+ 86400
  "How often a tick says how large the store is and how old its log is.
Once a day is enough to see growth.")

(defparameter +store-report-bytes+ (* 256 1024 1024)
  "How large the store must be before a tick reports its size.
Below this it is not a disk problem; `enchiridion memory status' answers on
demand.")

(defvar *store-reported-ts* 0
  "When this process last reported the store's size, or 0 for not yet.")

(defvar *store-failure-watermark* nil
  "The persistence-failure count this process last reported, or NIL before its
first tick. Earlier failures were reported when they happened, so counting them
here would make an idle tick look broken.")

(defun byte-count-line (bytes)
  "Return BYTES as a short decimal with its unit, or a phrase when unknown."
  (cond ((null bytes) "an unknown size")
        ((< bytes 1024) (format nil "~D B" bytes))
        ((< bytes (* 1024 1024)) (format nil "~D KB" (round bytes 1024)))
        ((< bytes (* 1024 1024 1024))
         (format nil "~,1F MB" (/ bytes (* 1024.0 1024))))
        (t (format nil "~,2F GB" (/ bytes (* 1024.0 1024 1024))))))

(defun age-line (seconds)
  "Return SECONDS as a short age, or a phrase when unknown."
  (cond ((null seconds) "of unknown age")
        ((>= seconds 172800) (format nil "~D days old" (floor seconds 86400)))
        ((>= seconds 86400) "a day old")
        ((>= seconds 7200) (format nil "~D hours old" (floor seconds 3600)))
        ((>= seconds 3600) "an hour old")
        (t "under an hour old")))

(defun store-report-line (store &key (now (get-universal-time)))
  "Return a line about the store's health and size, or NIL when there is
nothing to say.

A write that failed since the last tick is reported here: on a full volume
turns still answer and the only sign is that the history stopped growing. The
size line appears once a day, once the store is past +STORE-REPORT-BYTES+, with
the age of the oldest episode and the space a VACUUM would return. It never
deletes."
  (when store
    (let* ((failures (persistence-failures))
           (previous (or *store-failure-watermark* failures))
           (fresh (- failures previous))
           (latest (last-persistence-failure))
           (lines '()))
      (setf *store-failure-watermark* failures)
      (when (and (plusp fresh) latest)
        (push (format nil "~D memory write~:P failed since the last tick; last: could not persist ~(~A~): ~A"
                      fresh (car latest) (cdr latest))
              lines))
      (let ((usage (ignore-errors (enchiridion.memory.store::store-usage store :now now))))
        (when (and usage
                   (let ((bytes (getf usage :bytes)))
                     (and bytes (>= bytes +store-report-bytes+)))
                   (or (zerop *store-reported-ts*)
                       (>= (- now *store-reported-ts*)
                           +store-report-interval-seconds+)))
          (setf *store-reported-ts* now)
          (push (format nil "the memory store holds ~A over ~D episode~:P~@[, oldest ~A~]~@[; ~A is reclaimable~]; nothing is deleted automatically"
                        (byte-count-line (getf usage :bytes))
                        (getf usage :episodes)
                        (and (plusp (getf usage :episodes))
                             (age-line (getf usage :oldest-age)))
                        (let ((reclaimable (getf usage :reclaimable-bytes)))
                          (and reclaimable (plusp reclaimable)
                               (byte-count-line reclaimable))))
                lines)))
      (when lines (format nil "~{~A~^; ~}" (nreverse lines))))))

(declaim (ftype (function (enchiridion.supervisor:supervisor) list) heartbeat))

(defun heartbeat (supervisor)
  "Run one heartbeat tick and return a plist of :OK-P and :REPORT.

The phases run in order and each one is guarded on its own: a failed phase is
reported and the later ones still run, because a store that refuses one write
should not also stop the queue. Nothing here signals, for the reason
SUPERVISOR-TICK gives.

Phase order is the design. The store's health comes first, because a failing
write looks like nothing from every other surface. Then recovery, so a task a
dead process left running is failed before anything looks at the queue. Then
memory maintenance, which is model-free. Then due compaction, which has the
first claim on what the tick cap can afford among the phases that call a
model: it is the only phase that rewrites the session block, and running it
last let the sleep agent spend the cap first, tick after tick, so a due
compaction never happened. Then T2, which reads the rarity maintenance just
wrote, then embedding, then the ledger, so the sleep agent's own prompt
carries the spend of the pass before it. Then the sleep agent."
  (let* ((store (enchiridion.supervisor:supervisor-store supervisor))
         (agent (enchiridion.supervisor:supervisor-agent supervisor))
         (directory (enchiridion.supervisor:supervisor-directory supervisor))
         (tick-index (if agent (spend-count agent) 0))
         ;; A row watermark is what a per-request check reads: counting rows
         ;; newer than it is a primary-key range, not a scan of the lifetime
         ;; ledger. The lifetime total is read only when the watermark cannot
         ;; be, so the normal tick never scans the whole ledger.
         (start-row (and store
                         (handler-case (usage-watermark store)
                           (error () nil))))
         (start-total (if (and store (null start-row))
                          (store-total store)
                          0))
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
        (attempt "the memory store" (lambda () (store-report-line store))))
      (when store
        (attempt "task recovery"
                 (lambda ()
                   (let ((recovered (enchiridion.memory.store:recover-tasks store)))
                     (if (plusp recovered)
                         (format nil "~D interrupted task~:P failed" recovered)
                         nil)))))
      (when store
        ;; T1a: copy new turns into the log and derive the scalars the cue
        ;; pack needs. This is model-free and runs before compaction and the
        ;; sleep agent so both see fresh state.
        (attempt "memory maintenance"
                 (lambda ()
                   (let ((report (enchiridion.memory:maintenance store)))
                     (cond
                       ((null report) nil)
                       ((getf report :failed)
                        (setf ok-p nil)
                        (format nil "memory maintenance failed: ~A"
                                (getf report :failed)))
                       ((plusp (getf report :derived 0))
                        (format nil "~D episode~:P derived"
                                (getf report :derived)))
                       (t nil))))))
      (when (and store agent)
        ;; Compaction goes before T2 and the embedder. It is the only phase
        ;; that rewrites the session block and it is due only after four new
        ;; turns; making it the last phase let a tool-heavy sleep pass spend
        ;; the tick cap first and leave the block stale.
        (let* ((rebase-p (handler-case (compaction-rebase-due-p store)
                           (error () nil)))
               (refusal (handler-case (budget-refusal agent store start-total
                                                      tick-index
                                                      :start-row start-row
                                                      :reserve (if rebase-p
                                                                   (rebase-token-estimate)
                                                                   0))
                          (error (condition)
                            (format nil "the budget is unreadable: ~A"
                                    (enchiridion.errors:condition-report-line
                                     condition))))))
          (if refusal
              (say "compaction skipped: ~A" refusal)
              (attempt "compaction"
                       (lambda () (compact-when-due supervisor store agent
                                                    :rebase-p rebase-p))))))
      (when (and store agent)
        ;; T2: after maintenance, so the tail sample reads fresh rarity. Its
        ;; spend counts toward the day cap but not the tick cap, because a
        ;; pass has its own caps.
        (attempt "memory T2"
                 (lambda () (run-t2-phase store agent start-total tick-index
                                          :start-row start-row))))
      (when (and store enchiridion.memory:*memory-embedder*)
        ;; Dense vectors, when an embedder is configured. This one calls a
        ;; model, so it asks the same budget as the sleep agent and hands the
        ;; embedder only the room that is left: a spent cap skips the phase
        ;; instead of starting work it cannot pay for.
        (let* ((refusal (and agent
                             (handler-case
                                 (budget-refusal agent store start-total tick-index
                                                 :start-row start-row)
                               (error (condition)
                                 (setf ok-p nil)
                                 (format nil "the budget is unreadable: ~A"
                                         (enchiridion.errors:condition-report-line
                                          condition))))))
               (room (and agent (null refusal)
                          (handler-case
                              (budget-remaining agent store start-total tick-index
                                                :start-row start-row)
                            (error () 0)))))
          (if refusal
              (say "memory embedding skipped: ~A" refusal)
              (attempt "memory embedding"
                       (lambda ()
                         (let ((written (enchiridion.memory:embed-pending
                                         store :max-tokens room)))
                           (when (plusp written)
                             (format nil "~D episode~:P embedded" written))))))))
      (when store
        (attempt "the harness blocks"
                 (lambda ()
                   (write-ledger-block supervisor store)
                   (write-session-fallback supervisor store)
                   nil)))
      (let ((refusal (or (sleep-refusal agent store directory)
                         ;; The refusal reads the store, so a store that
                         ;; refuses the read is a reason not to start, not a
                         ;; reason to abandon the rest of the tick.
                         (handler-case
                             (and store (budget-refusal agent store start-total
                                                        tick-index
                                                        :start-row start-row))
                           (error (condition)
                             (setf ok-p nil)
                             (format nil "the budget is unreadable: ~A"
                                     (enchiridion.errors:condition-report-line
                                      condition)))))))
        (if refusal
            (say "sleep skipped: ~A" refusal)
            (attempt "the sleep agent"
                     (lambda () (run-sleep-phase supervisor store agent directory
                                                 :start-row start-row)))))
      (list :ok-p ok-p
            :report (if notes (format nil "~{~A~^; ~}" (nreverse notes)) "idle")))))
