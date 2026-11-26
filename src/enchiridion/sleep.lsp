;;;; sleep.lsp --- Heartbeat tick, sleep agent, session compaction, and budgets.
;;;;
;;;; Unattended work runs on heartbeat ticks, sharing the operator agent's lock
;;;; so ticks and live turns do not interleave on the store or workspace.
;;;; The sleep agent is built fresh per tick to pick up updated block files,
;;;; and phases are bounded by rolling 24-hour and per-tick token budgets.

(in-package #:enchiridion.kernel)

;;;; What a pass is told.

(defparameter +sleep-task-prompt+
  "The operator queued this task for you:"
  "Prefix prepended to a queued task body.")

(defparameter +sleep-maintenance-prompt+
  "Review what has happened since the last pass. Search the transcript if you need to. Update SOUL.md, OPERATOR.md or WORLD.md only where something new was actually learned, and add or patch nothing if nothing changed. Answer in one line with what you did, or with nothing to change."
  "Standing prompt for maintenance passes (instructs no-op when nothing changed).")

(defparameter +compaction-brief+
  "You compact an agent's session memory. You are given the previous summary and the most recent turns. Answer with the new session block only: plain prose, no headings, at most four hundred characters, about what the agent is doing and what it has learned."
  "System brief for incremental session compaction (replaces personality blocks).")

(defparameter +rebase-brief+
  "You rebuild an agent's session memory from its recent transcript alone. You are given only the raw turns, not any earlier summary. Answer with the new session block only: plain prose, no headings, at most four hundred characters, about what the agent is doing and what it has learned."
  "System brief for session rebase compaction (rebuilds from raw turns without prior summary).")

(defparameter +characters-per-token+ 4
  "Estimated characters per token, used to pre-check rebase token cost.")

(defparameter +compaction-turns+ 4
  "Minimum number of new non-sleep turns required before triggering compaction.")

(defparameter +task-prompt-limit+ 4000
  "Maximum characters of a task body included in the prompt (the stored row keeps the full body).")

(defparameter +recent-turn-limit+ 400
  "Maximum characters per turn included in a compaction prompt.")

;;;; The task queue, as the kernel promises it.

(declaim (ftype (function (t &key (:limit integer) (:status t)) list) task-queue))

(defun task-queue (store &key (limit 100) status)
  "Return queued tasks oldest first, optionally filtered by STATUS."
  (enchiridion.memory.store:list-tasks store :limit limit :status status))

(declaim (ftype (function (t string &key (:ts t)) t) enqueue-task))

(defun enqueue-task (store body &key (ts (get-universal-time)))
  "Add BODY to the queue as a pending task and return it as a task row."
  (enchiridion.memory.store:enqueue-task store body :ts ts))

(declaim (ftype (function (t) t) dequeue-task))

(defun dequeue-task (store)
  "Claim the oldest pending task (marking it running) and return its row, or NIL."
  (enchiridion.memory.store:dequeue-task store))

(declaim (ftype (function (t &key (:status t)) integer) task-queue-length))

(defun task-queue-length (store &key (status :pending))
  "Return how many tasks are waiting, or how many have STATUS."
  (enchiridion.memory.store:count-tasks store :status status))

;;;; Small helpers.

(declaim (ftype (function (string integer) string) shorten))

(defun shorten (text limit)
  "Return TEXT truncated to LIMIT characters with a trailing ellipsis if shortened."
  (if (<= (length text) limit)
      text
      (concatenate 'string (subseq text 0 (max 0 (- limit 3))) "...")))

(declaim (ftype (function (t) string) task-prompt))

(defun task-prompt (task)
  "Build the prompt text for TASK, truncating its body at +TASK-PROMPT-LIMIT+."
  (let ((body (enchiridion.memory.store:task-row-body task)))
    (format nil "~A~%~A~%When you are done, say in one line what you did."
            +sleep-task-prompt+
            (shorten body +task-prompt-limit+))))

;;;; The sleep agent.

(declaim (ftype (function (&key (:directory t) (:backend t) (:budget t)
                                (:broker t) (:store t) (:lock t)
                                (:tool-rounds (integer 0 *)))
                          agent)
                sleep-agent))

(defun sleep-agent (&key directory backend budget broker store (lock nil)
                         (tool-rounds (enchiridion:config-tool-rounds nil)))
  "Construct a fresh sleep agent with writable identity blocks (:persona, :operator, :world).
Shares LOCK with the operator agent to serialize store and workspace writes."
  (let ((agent (make-agent :name "sleep"
                           :backend backend
                           :directory directory
                           :budget budget
                           :broker broker
                           :store store
                           :tool-rounds tool-rounds
                           :lock lock)))
    (dolist (block (agent-blocks agent))
      (when (member (enchiridion.memory:block-label block)
                    '(:persona :operator :world)
                    :test #'eq)
        (setf (enchiridion.memory:block-writable-p block) t)))
    agent))

(declaim (ftype (function (agent &optional string) agent) compactor-agent))

(defun compactor-agent (agent &optional (brief +compaction-brief+))
  "Construct a tool-less summariser agent under BRIEF, sharing AGENT's lock and budget."
  (make-agent :name "compactor"
              :backend (agent-backend agent)
              :blocks (list (enchiridion.memory:make-block
                             :label :persona
                             :text brief))
              :tools-p nil
              :budget (agent-budget agent)
              ;; Share AGENT's lock because compaction reads transcripts and writes the session block.
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
  "Run one sleep pass (single TASK or maintenance turn) in an ephemeral session and return a result plist.
Checks the soft budget cap before each tool round using START-ROW (or START-TOTAL) and TICK-INDEX.
TEXT overrides the standing prompt when given."
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
               ;; Fail rather than requeue: earlier tool rounds may have already had side effects.
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
  "Rewrite the session block from recent non-sleep turns and return (values text refusal).
When REBASE-P is true, rebuilds from *COMPACTION-REBASE-TURNS* raw turns without the prior summary.
Records a projection row on success; returns (values NIL refusal) if the store rejects the block."
  (let* ((previous (if rebase-p "" (enchiridion.memory.store:session-block store)))
         (recent (enchiridion.memory.store:recent-turns
                  store
                  :limit (if rebase-p
                             enchiridion.memory:*compaction-rebase-turns*
                             +compaction-turns+)
                  :not-channel :sleep
                  ;; Fetch 1 char past limit so SHORTEN detects truncation without reading huge bodies.
                  :body-chars (1+ +recent-turn-limit+)))
         (user (format nil "~:[Previous summary:~%~A~%~%~;~*~]Recent turns:~%~{~A~%~}"
                       rebase-p
                       (if (plusp (length previous)) previous "(none)")
                       (mapcar (lambda (row)
                                 (format nil "~A: ~A"
                                         (enchiridion.memory.store:turn-row-role row)
                                         (shorten (enchiridion.memory.store:turn-row-body row)
                                                  +recent-turn-limit+)))
                               ;; RECENT-TURNS is newest first; reverse to chronological order.
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
             ;; Rejected summaries (overflow or scan failure) are no-ops and record no projection.
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
  "Record a session projection row for FROM-TURN..TO-TURN to track compaction cadence across restarts."
  (enchiridion.memory.store:exec
   store
   "INSERT INTO projections (block, from_turn, to_turn, rebased_p, model, hash, ts)
      VALUES ('session', ?, ?, ?, ?, ?, ?)"
   (list from-turn to-turn (if rebase-p 1 0) model
         (enchiridion.memory:content-hash text) now)))

(defparameter +session-fallback-block+ "session-fallback"
  "Block name storing the hash of the harness fallback line to distinguish it from real summaries.")

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
  "Return T when the session block is non-empty, not a fallback line, and has no projection rows."
  (let ((text (enchiridion.memory.store:session-block store)))
    (and (plusp (length text))
         (zerop (session-projection-count store))
         (not (fallback-session-block-p store text)))))

(defun compaction-rebase-due-p (store)
  "Return T when the next compaction should rebase from raw turns.
True for inherited summaries with no projections, or every *COMPACTION-REBASE-EVERY* passes."
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
  "Estimate token cost for a rebase pass from turn limits, brief length, and session block limit."
  (ceiling (+ (* enchiridion.memory:*compaction-rebase-turns* +recent-turn-limit+)
              (length +rebase-brief+)
              (enchiridion.memory:default-block-limit :session))
           +characters-per-token+))

;;;; The two harness blocks.

(declaim (ftype (function (t t) string) ledger-line))

(defun ledger-line (store session)
  "Format the compact one-line ledger block summarizing session and 24-hour token usage."
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
  "Populate an empty session block with a fallback queue summary and record its hash."
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
  "Return lifetime unattended (:sleep and :embed) tokens in STORE, or 0."
  (if store
      (handler-case (getf (enchiridion.memory.store:usage-total-since
                           store 0 :channels '(:sleep :embed))
                          :total)
        (error () 0))
      0))

(declaim (ftype (function (t) integer) usage-watermark))

(defun usage-watermark (store)
  "Return the newest usage row id, or 0 if empty (enables primary-key range checks)."
  (or (enchiridion.memory.store:field
       (first (enchiridion.memory.store:query-rows
               store "SELECT COALESCE(MAX(id), 0) AS n FROM usage"))
       "n")
      0))

(declaim (ftype (function (t integer) integer) store-tick-spend))

(defun store-tick-spend (store start-row)
  "Return unattended (:sleep, :embed) tokens in usage rows newer than START-ROW."
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
  "Return unattended (:sleep, :embed) tokens spent since this tick started.
Takes the max of store usage (via START-ROW range or START-TOTAL delta) and the
in-memory ledger since TICK-INDEX so failed store writes cannot hide spend."
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
  "Return total tokens spent across all channels in the rolling 24-hour window
(max of store and in-memory ledger)."
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
  "Return (values unattended-tick-spend rolling-24h-all-channel-spend)."
  (values (unattended-tick-spend agent store start-total tick-index
                                 :start-row start-row)
          (day-spend agent store)))

(declaim (ftype (function (agent t integer integer &key (:day-only t) (:start-row t))
                          (or null integer))
                budget-remaining))

(defun budget-remaining (agent store start-total tick-index &key (day-only nil)
                                                          start-row)
  "Return remaining token allowance for this tick (or day cap alone if DAY-ONLY), or NIL if uncapped."
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
  "Return a refusal reason if a model call would exceed tick or rolling 24h caps, else NIL.
RESERVE pre-checks expected pass cost against the tick cap; DAY-ONLY checks only the day cap (used by T2)."
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
  "Return a BUDGET-EXCEEDED condition if recorded tick or day spend has reached its soft cap, else NIL."
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
  "Return a pre-request callback for RUN-TURN that signals BUDGET-EXCEEDED between rounds when capped."
  (lambda (round)
    (declare (ignore round))
    (let ((condition (budget-stop-condition agent store start-total tick-index
                                            :start-row start-row)))
      (when condition
        (error condition)))))

(declaim (ftype (function (t t t) (or null string)) sleep-refusal))

(defun sleep-refusal (agent store directory)
  "Return a human-readable refusal reason if the sleep agent cannot run, else NIL."
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
  "Construct the per-tick sleep agent inheriting AGENT's turn lock and config."
  (sleep-agent :directory directory
               :backend (agent-backend agent)
               :budget (agent-budget agent)
               :broker (agent-broker agent)
               :store store
               :tool-rounds (agent-tool-rounds agent)
               :lock (agent-lock agent)))

(declaim (ftype (function (enchiridion.supervisor:supervisor t agent t
                                           &key (:start-row t))
                          string)
                run-sleep-phase))

(defun run-sleep-phase (supervisor store agent directory &key start-row)
  "Claim and run one queued task, run a maintenance pass if new turns exist, or return \"idle\"."
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
           ;; Pre-format optional suffixes so ~A arguments align unconditionally.
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
           (format nil "maintenance pass~@[ (~A)~]" (getf result :note))))
        (t "idle")))))

(declaim (ftype (function (enchiridion.supervisor:supervisor t agent &key (:rebase-p t))
                          (or null string))
                compact-when-due))

(defparameter +compaction-attempts-per-window+ 2
  "Maximum compaction attempts for the same newest-turn window before waiting for new turns.")

(defvar *compaction-window* nil
  "Process-local retry tracker (STORE-PATH NEWEST-TURN ATTEMPTS), or NIL.")

(defun compaction-window-key (store)
  "Return the store path string used as the compaction window cache key."
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
  "Compact or rebase the session block when at least +COMPACTION-TURNS+ new turns exist, else NIL.
Limits retries per turn window to +COMPACTION-ATTEMPTS-PER-WINDOW+ without advancing the cursor on failure."
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
          ;; Keep cursor unchanged on blank/refused output so turns are not dropped.
          ((null compacted)
           (if refusal
               (format nil "compaction produced nothing usable: ~A" refusal)
               "compaction produced no text"))
          (t
           (setf (enchiridion.supervisor:supervisor-last-compacted-turn supervisor)
                 (enchiridion.memory.store:turn-row-id (first recent)))
           (setf *compaction-window* nil)
           (if rebase-p
               "the session block was rebuilt from raw turns"
               "the session block was compacted")))))))

(defun t2-refusal-line (refusal)
  "Format a T2 refusal keyword as a human-readable phrase."
  (case refusal
    (:not-due "not due")
    (:disabled "memory is switched off")
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
              (:instrument-missing
               (format nil "T2 skipped: instruments missing (~{~(~A~)~^, ~}); utility pairs ~D/~D, tail pairs ~D/~D (~D answers awaiting rarity)"
                       (getf report :missing)
                       (getf report :utility-tasks) enchiridion.memory:*memory-gate-min-n*
                       (getf report :tail-tasks) enchiridion.memory:*tail-min-n*
                       (getf report :tail-pending)))
              (:maintenance-pending
               (format nil "T2 deferred: ~D eligible answer~:P still awaiting rarity"
                       (getf report :tail-pending)))
              (:skipped (format nil "T2 skipped: ~A"
                                (t2-refusal-line (getf report :reason)))))))
      (if (getf report :recovered)
          (format nil "~A (a candidate an earlier pass built and never gated)" line)
          line))))

(defun run-t2-phase (store agent start-total tick-index &key start-row)
  "Run one T2 pass when due and within day budget, returning a report line or NIL when disabled/not due."
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
  "Minimum interval in seconds between periodic store size reports.")

(defparameter +store-report-bytes+ (* 256 1024 1024)
  "Minimum store size in bytes before a tick includes size reporting.")

(defvar *store-reported-ts* 0
  "When this process last reported the store's size, or 0 for not yet.")

(defvar *store-failure-watermark* nil
  "Last reported persistence-failure count, or NIL before the first tick.")

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
  "Return a health/size summary line for STORE (new write failures, or daily size above +STORE-REPORT-BYTES+), else NIL."
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
  "Run one heartbeat tick and return (:ok-p bool :report string). Never signals.
Phases run independently in order: store health, task recovery, T1a maintenance,
compaction (first claim on tick cap), T2 (day cap only), embeddings, harness blocks, sleep agent."
  (let* ((store (enchiridion.supervisor:supervisor-store supervisor))
         (agent (enchiridion.supervisor:supervisor-agent supervisor))
         (directory (enchiridion.supervisor:supervisor-directory supervisor))
         (tick-index (if agent (spend-count agent) 0))
         ;; Row watermark lets per-request checks use a primary-key range; fall back to lifetime total on error.
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
        ;; T1a: model-free maintenance before compaction and sleep so both see fresh state.
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
                        (format nil "Rarity scored for ~D episode~:P"
                                (getf report :derived)))
                       (t nil))))))
      (when (and store agent)
        ;; Compaction runs before T2/embeddings/sleep so it gets first claim on the tick cap.
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
        ;; T2 runs after maintenance for fresh rarity; counts against day cap only.
        (attempt "memory T2"
                 (lambda () (run-t2-phase store agent start-total tick-index
                                          :start-row start-row))))
      (when (and store enchiridion.memory:*memory-embedder*)
        ;; Dense embeddings: bounded by remaining tick/day token allowance.
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
                         ;; Skip sleep rather than aborting the tick if the budget check fails.
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
