;;;; gates.lsp --- Checks for promoting a memory generation.

(in-package #:enchiridion.memory)

;;;; ------------------------------------------------------------------
;;;; 5. The gates
;;;; ------------------------------------------------------------------

(defun binomial (n k)
  "Return N choose K, exactly."
  (if (or (< k 0) (> k n))
      0
      (let ((k (min k (- n k))) (result 1))
        (loop for i from 1 to k
              do (setf result (/ (* result (- n (- k i))) i)))
        result)))

(defun sign-test-p (wins n)
  "Return the one-sided sign test's p for WINS of N non-tied pairs: the chance
of at least WINS heads in N fair coin flips, as an exact rational."
  (if (zerop n)
      1
      (/ (loop for i from wins to n sum (binomial n i))
         (expt 2 n))))

(defun paired-outcomes (store generation-id &key (task-hashes :all))
  "Return GENERATION-ID's outcome pairs as a list of (RETENTION . CANDIDATE),
one per task both arms scored, from the latest row of each.

The rows are the ones RUN-ARM wrote under the candidate's id and each task's
hash, so a pair is the same question asked of the two arms. TASK-HASHES is
:ALL or a list of tasks to keep. An empty list matches nothing."
  (when (null task-hashes)
    (return-from paired-outcomes nil))
  (let ((by-task (make-hash-table :test #'equal)))
    (dolist (row (enchiridion.memory.store:query-rows
                  store
                  "SELECT g.task_hash, g.arm, g.value
                     FROM gate_log g
                     JOIN (SELECT MAX(id) AS id FROM gate_log
                            WHERE generation_id = ? AND metric = 'outcome'
                              AND arm IN ('retention', 'candidate')
                              AND task_hash <> ''
                            GROUP BY task_hash, arm) latest
                       ON latest.id = g.id"
                  (list generation-id)))
      (let ((hash (enchiridion.memory.store:field row "task_hash")))
        (when (or (eq task-hashes :all) (member hash task-hashes :test #'string=))
          (let ((pair (or (gethash hash by-task) (cons nil nil)))
                (value (enchiridion.memory.store:field row "value")))
            (if (string= (enchiridion.memory.store:field row "arm") "retention")
                (setf (car pair) value)
                (setf (cdr pair) value))
            (setf (gethash hash by-task) pair)))))
    (loop for pair being the hash-values of by-task
          when (and (car pair) (cdr pair)) collect pair)))

(defun utility-gate (store generation-id &key (margin *memory-gate-margin*)
                                              (min-n *memory-gate-min-n*)
                                              (alpha *memory-gate-alpha*)
                                              (task-hashes :all))
  "Return two values: T when GENERATION-ID beats retention-only, and a report.

Compare candidate and retention-only on paired tasks at
matched budget, a mean delta of at least MARGIN, at least MIN-N non-tied
pairs, and a one-sided sign test below ALPHA.  The pairs are read from the
gate log, which COMPARE-ARMS writes: the step that decides is not the step
that measures.  Too little evidence is a failure, which is the correct
default: an unmeasured candidate is not promoted."
  (let* ((pairs (paired-outcomes store generation-id :task-hashes task-hashes))
         ;; Exact arithmetic, and the configured margin read as the decimal
         ;; it was written as: a mean of exactly 0.05 meets a margin of 0.05,
         ;; which a single-float 0.05 compared with a double would not.
         (deltas (mapcar (lambda (pair) (- (rational (cdr pair)) (rational (car pair))))
                         pairs))
         (non-tied (count-if-not #'zerop deltas))
         (wins (count-if #'plusp deltas))
         (mean (if deltas (/ (reduce #'+ deltas) (length deltas)) 0.0))
         (p (sign-test-p wins non-tied)))
    (values (and (>= non-tied min-n) (>= mean (rationalize margin)) (< p (rationalize alpha)))
            (list :pairs (length pairs) :non-tied non-tied :wins wins
                  :mean-delta (float mean) :p (float p)))))

(defun tail-gate (store generation-id task-hashes &key (margin *memory-tail-margin*)
                                                       (min-n *tail-min-n*))
  "Return two values: T when GENERATION-ID's recall on TASK-HASHES, the tasks
with rare answers, is no more than MARGIN below retention-only's, and a report.
Fewer than MIN-N scored tail tasks is a failure: a tail nobody measured is not
a tail that survived.

Tail recall counts an outcome as one
when the answer reached the pack at all, whatever its position: the utility
outcomes are graded, and a rare answer moved down the pack is still recalled."
  (flet ((recall (outcome) (if (plusp outcome) 1 0)))
    (let* ((pairs (paired-outcomes store generation-id :task-hashes task-hashes))
           (n (length pairs))
           (retention (if pairs (/ (reduce #'+ pairs :key (lambda (p) (recall (car p)))) n) 0))
           (candidate (if pairs (/ (reduce #'+ pairs :key (lambda (p) (recall (cdr p)))) n) 0)))
      (values (and (>= n min-n) (>= candidate (- retention (rationalize margin))))
              (list :n n :retention (float retention) :candidate (float candidate))))))

(defun provenance-gate (store generation-id)
  "Return two values: T when every assertion GENERATION-ID holds names a span
of an episode still in the log, and a report.  A semantic item with no
surviving source cannot be checked against what was said, so it cannot be
promoted."
  (let ((bad (or (enchiridion.memory.store:field
                  (first (enchiridion.memory.store:query-rows
                          store
                          "SELECT COUNT(*) AS n FROM assertions a
                             LEFT JOIN episodes e ON e.id = a.episode_id
                            WHERE a.generation_id = ?
                              AND (e.id IS NULL OR a.span_start < 0
                                   OR a.span_end <= a.span_start
                                   OR a.span_end > length(e.body))"
                          (list generation-id)))
                  "n")
                 0)))
    (values (zerop bad) (list :unsourced bad))))

(defun build-assertion-count (store generation-id)
  "Return the assertions GENERATION-ID's own build wrote: its rows whose run is
itself, so the rows it copied from its parent are not counted."
  (or (enchiridion.memory.store:field
       (first (enchiridion.memory.store:query-rows
               store "SELECT COUNT(*) AS n FROM assertions WHERE generation_id = ? AND run_id = ?"
               (list generation-id generation-id)))
       "n")
      0))

(defun volume-gate (store generation-id &key (per-episode *memory-writes-per-episode*))
  "Return T when GENERATION-ID's build wrote at most PER-EPISODE assertions for
each episode it derived itself.

The cap exists because interference is constantly present: what a system
writes between encoding a record and retrieving it determines whether the
record survives, with no deletion policy in play.  High-volume passive
learning therefore degrades older records by competition alone.

It counts claims, the build's own assertion rows, and not conflict rows or
closed intervals: those are bookkeeping about claims, and on the trial log one
list-valued relation alone opened 1,806 conflict rows, which would have
quarantined a candidate writing 4.2 claims an episode.  The allowance is per
episode derived, because a measured deriver writes about five an episode."
  (let ((row (first (enchiridion.memory.store:query-rows
                     store "SELECT episodes_derived FROM generations WHERE id = ?"
                     (list generation-id)))))
    (and row
         (<= (build-assertion-count store generation-id)
             (* per-episode (or (enchiridion.memory.store:field row "episodes_derived") 0))))))

(defun record-gate-row (store arm metric value &key (n 0) (detail "")
                                                 (generation-id 0) (task-hash "")
                                                 (now (get-universal-time)))
  "Append one measurement to gate_log.  GENERATION-ID is the candidate the row
was measured for, on both arms, and TASK-HASH names the task, so the utility
gate can pair the two arms task by task."
  (enchiridion.memory.store:exec
   store
   "INSERT INTO gate_log (arm, metric, value, n, detail, ts, generation_id, task_hash)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
   (list arm metric (coerce value 'double-float) n detail now
         generation-id task-hash)))

(defun task-cue-text (cue)
  "Return CUE as retrieval text: a task's cue is a string or a list of terms."
  (if (listp cue) (format nil "~{~A~^ ~}" cue) cue))

(defun task-hash (task)
  "Return the stable name of TASK that pairs its rows across the two arms."
  (content-hash (or (getf task :name) (task-cue-text (getf task :cue)))))

(defun run-arm (store arm tasks scorer &key (push nil) (generation :live)
                                            (generation-id 0))
  "Run TASKS under one ARM and return a result plist.

SCORER is a function of (STORE TASK PUSHED ROWS) returning a number.  ROWS are
what RETRIEVE-ROWS-FOR-TURN ranks for the cue when GENERATION is the semantic
layer read -- :LIVE, a generation id, or NIL for the log alone -- and PUSHED is
the push pack when PUSH is true.  It is the caller's job to make the scorer
measure OUTCOME rather than action difference.  That distinction is the
correction the extension's first draft got wrong: a paired audit found 24 of
24 audits changing the action while the selected branch never changed, so a
change signal does not track whether the memory did the work.

Records one gate_log row per task, under GENERATION-ID and the task's hash, so
the gate has evidence rather than memory.  A scorer that signals scores 0."
  (let ((outcomes '()))
    (dolist (task tasks)
      (let* ((cue (getf task :cue))
             (pushed (if push (push-pack store cue :state (getf task :state)) ""))
             (rows (handler-case
                       (retrieve-rows-for-turn store (task-cue-text cue)
                                               :generation generation)
                     (error () nil)))
             (value (handler-case (funcall scorer store task pushed rows)
                      (error () 0.0))))
        (push value outcomes)
        (record-gate-row store arm "outcome" value :n 1
                         :detail (or (getf task :name) "")
                         :generation-id generation-id
                         :task-hash (task-hash task))))
    (list :arm arm :n (length outcomes)
          :mean (if outcomes (/ (reduce #'+ outcomes) (length outcomes)) 0.0)
          :outcomes (nreverse outcomes))))

(defun compare-arms (store generation-id tasks scorer &key (margin *memory-gate-margin*))
  "Run the retention-only arm and GENERATION-ID's candidate arm over TASKS and
return the comparison.

The retention-only arm reads the log alone; the candidate arm reads the log
with the candidate's semantic layer.  Both record their rows under
GENERATION-ID, so the gate compares this candidate and no other.  This is the
utility gate's evidence-producing step, deliberately separate from the gate
that reads it: the step that decides must not be the step that measures."
  (let ((ret (run-arm store "retention" tasks scorer
                      :generation nil :generation-id generation-id))
        (con (run-arm store "candidate" tasks scorer
                      :generation generation-id :generation-id generation-id)))
    (list :retention ret :candidate con
          :delta (- (getf con :mean) (getf ret :mean))
          :passes (>= (- (getf con :mean) (getf ret :mean)) margin)
          :margin margin)))

(defun push-ab (store tasks scorer &key (margin 0.0))
  "Run the push-disabled and push-enabled arms and return the comparison.

Measures OUTCOME, at matched difficulty and matched budget, over the live
layer.  The prediction it tests is P13 of model-unified.md: a push channel's
outcome effect is positive.  The failure condition is that the effect is
indistinguishable from zero, in which case the channel is retired."
  (let ((off (run-arm store "push-off" tasks scorer :push nil))
        (on (run-arm store "push-on" tasks scorer :push t)))
    (list :off off :on on
          :delta (- (getf on :mean) (getf off :mean))
          :passes (> (- (getf on :mean) (getf off :mean)) margin)
          :margin margin)))

;;;; ------------------------------------------------------------------
;;;; 7. The utility task set and the tail sampler
;;;; ------------------------------------------------------------------

(defparameter +tool-result-roles+ '("tool" "function" "tool_result")
  "The episode roles that mark a tool result.

A turn's final answer is the last assistant round after the last of these, so a
preamble that asked for a tool is not mistaken for the reply the operator read.
The live kernel writes TOOL; the other two are names imported logs use.")

(defparameter +tail-max-tasks+ 400
  "The most rare answers one tail sample scores.

The rarity fraction scales with the log, and an imported log's rarest tenth can
be thousands of answers. The sample is bounded so a preflight scores a fixed
number of retrieval packs rather than a share of the whole log.")

(defun pair-scope-sql ()
  "Return the common table expression that pairs a question with its final
answer in one scan.

A turn starts at a user episode and ends before the next one. Inside it, an
explicit FINAL_P marker wins: 1 names the reply a live turn returned, and 0
names an interim round. An interrupted live turn with no final marker has no
answer. For legacy or imported turns, the answer is the last assistant round
after the turn's last tool result."
  (format nil "WITH scoped AS (
     SELECT e.id, e.session, e.role, e.final_p,
            MAX(CASE WHEN e.role = 'user' THEN e.id END)
              OVER (PARTITION BY e.session ORDER BY e.id
                    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS turn_key
       FROM episodes e
      WHERE e.role <> 'memory' AND e.channel <> 'sleep'),
   turn_facts AS (
     SELECT turn_key,
            MAX(CASE WHEN role = 'assistant' AND final_p = 1 THEN id END) AS exact_id,
            MAX(CASE WHEN role = 'assistant' AND final_p = 0 THEN id END) AS interim_id,
            MAX(CASE WHEN role IN (~{'~A'~^, ~}) THEN id END) AS tool_id,
            MAX(CASE WHEN role = 'assistant' THEN id END) AS last_assistant_id
       FROM scoped
      WHERE turn_key IS NOT NULL
      GROUP BY turn_key),
   answers AS (
     SELECT turn_key, exact_id, interim_id, last_assistant_id, tool_id,
            CASE WHEN exact_id IS NOT NULL THEN exact_id
                 WHEN interim_id IS NOT NULL THEN NULL
                 WHEN last_assistant_id IS NOT NULL
                  AND last_assistant_id > COALESCE(tool_id, 0)
                 THEN last_assistant_id
                 ELSE NULL END AS answer_id
       FROM turn_facts)"
          +tool-result-roles+))

(defun pair-row-task (row)
  "Return ROW, one paired turn, as a utility task."
  (let ((cue-id (enchiridion.memory.store:field row "cue_id")))
    (list :name (format nil "answer-~D" cue-id)
          :cue (enchiridion.memory.store:field row "cue")
          :cue-episode cue-id
          :expect-episode (enchiridion.memory.store:field row "answer_id"))))

(defun utility-tasks (store &key (limit *utility-max-tasks*))
  "Return up to LIMIT tasks derived from the log, newest first.

A task is a question the operator asked and the reply that answered it. A live
turn marks the reply with FINAL_P; a legacy or imported turn has no marker, and
its answer is the last assistant round after the turn's last tool result and
before the next question. A round that asked for a tool is never taken for the
reply, and a turn that stopped on a tool result has no task.

Every exchange in the log is one, so the set grows with use and needs nobody to
write it. The sleep channel's own turns are not exchanges and are left out."
  (mapcar #'pair-row-task
          (enchiridion.memory.store:query-rows
           store
           (format nil "~A
             SELECT a.turn_key AS cue_id, u.body AS cue, a.answer_id
               FROM answers a
               JOIN episodes u ON u.id = a.turn_key
              WHERE a.answer_id IS NOT NULL
              ORDER BY a.turn_key DESC
              LIMIT ?"
                   (pair-scope-sql))
           (list limit))))

(defun answer-hit-p (rows episode-id)
  "Return T when ROWS bring back EPISODE-ID itself or an assertion derived
from it: either way the answer reached the pack."
  (some (lambda (row)
          (let ((item (getf row :item)))
            (if (equal (getf item :kind) "assertion")
                (eql (getf item :episode-id) episode-id)
                (eql (getf item :id) episode-id))))
        rows))

(defun pack-position (store rows cue episode-id &key (budget *gate-pack-chars*)
                                                      skip-episode)
  "Return where EPISODE-ID's answer sits in the pack ROWS render at BUDGET
characters, counting from 0, or NIL when it did not fit. The pack is built the
way a turn builds it, through SELECT-PACK-ROWS and RENDER-PACK, so the gate
measures what a model would be shown and not the ranking behind it.

SKIP-EPISODE, the turn the cue was taken from, still takes its room in the
pack but is not counted as a place: it is the question repeated, it leads both
arms' packs, and counting it made every other row cost a whole rank."
  (let ((included (remove-if (lambda (row)
                               (let ((item (getf row :item)))
                                 (and skip-episode
                                      (equal (getf item :kind) "episode")
                                      (eql (getf item :id) skip-episode))))
                             (nth-value 1 (render-pack (select-pack-rows store cue rows)
                                                       :budget budget :cue cue)))))
    (position-if (lambda (row) (answer-hit-p (list row) episode-id)) included)))

(defun answer-scorer (store task pushed rows)
  "Score TASK by where its answer reached the gate's pack: 1 first, 1/2
second, 1/N at position N, and 0 when it did not fit in *GATE-PACK-CHARS*.
The turn the cue came from is not counted as a place.

A graded score and not hit or miss, because a log already brings back most
answers to its own questions: scored as hits, nearly every pair ties and the
sign test has nothing to count. The small pack is the matched budget, and it
is what lets a short claim beat a long answer that no longer fits."
  (declare (ignore pushed))
  (let ((position (pack-position store rows (task-cue-text (getf task :cue))
                                 (getf task :expect-episode)
                                 :skip-episode (getf task :cue-episode))))
    (if position (/ 1.0 (+ 1 position)) 0.0)))

(defun rare-episode-ids (store &key (fraction *tail-rarity-fraction*))
  "Return the ids of the rarest FRACTION of the derived episodes, as a hash
set. Rarity is maintenance's RARITY_RAW, so an episode maintenance has not
reached yet is neither rare nor common."
  (let* ((total (or (enchiridion.memory.store:field
                     (first (enchiridion.memory.store:query-rows
                             store
                             "SELECT COUNT(*) AS n FROM episodes
                               WHERE derived_ts IS NOT NULL
                                 AND channel <> 'sleep' AND role <> 'memory'"))
                     "n")
                    0))
         (count (ceiling (* fraction total)))
         (ids (make-hash-table)))
    (when (plusp count)
      (dolist (row (enchiridion.memory.store:query-rows
                    store
                    "SELECT id FROM episodes
                      WHERE derived_ts IS NOT NULL
                        AND channel <> 'sleep' AND role <> 'memory'
                      ORDER BY rarity_raw DESC, id
                      LIMIT ?"
                    (list count)))
        (setf (gethash (enchiridion.memory.store:field row "id") ids) t)))
    ids))

(defun tail-tasks (store tasks &key (fraction *tail-rarity-fraction*))
  "Return the TASKS whose answer is among the rarest FRACTION of the answers
TASKS name. A task whose answer maintenance has not derived is not ranked.

This filters a bounded task list. TAIL-SAMPLE reads the whole log's eligible
answers instead, because the rare records are wherever the log put them and a
tail drawn from the newest utility tasks can miss them."
  (let ((ids (remove-duplicates
              (remove nil (mapcar (lambda (task) (getf task :expect-episode)) tasks))))
        (rare (make-hash-table)))
    (when ids
      (let* ((rows (enchiridion.memory.store:query-rows
                    store
                    (format nil "SELECT id FROM episodes
                                  WHERE id IN (~{~A~^,~}) AND derived_ts IS NOT NULL
                                  ORDER BY rarity_raw DESC, id"
                            (make-list (length ids) :initial-element "?"))
                    ids))
             (count (ceiling (* fraction (length rows)))))
        (dolist (row (subseq rows 0 (min count (length rows))))
          (setf (gethash (enchiridion.memory.store:field row "id") rare) t))))
    (remove-if-not (lambda (task) (gethash (getf task :expect-episode) rare))
                   tasks)))

(defun tail-pair-rows (store)
  "Return the rarest eligible answer pairs and their rarity coverage."
  (enchiridion.memory.store:query-rows
   store
   (format nil "~A, sample AS (
     SELECT a.turn_key AS cue_id, a.answer_id, ans.rarity_raw AS rarity,
            ans.derived_ts IS NULL AS unscored,
            COUNT(*) OVER () AS eligible, COUNT(ans.derived_ts) OVER () AS ranked
       FROM answers a JOIN episodes ans ON ans.id = a.answer_id
      ORDER BY unscored, rarity DESC, a.answer_id
      LIMIT ?)
     SELECT s.cue_id, u.body AS cue, s.answer_id, s.eligible, s.ranked
       FROM sample s JOIN episodes u ON u.id = s.cue_id
      ORDER BY s.unscored, s.rarity DESC, s.answer_id"
           (pair-scope-sql))
   (list +tail-max-tasks+)))

(defun tail-sample (store)
  "Return the rarest scored answer pairs, unscored count, and eligible count."
  (let* ((rows (tail-pair-rows store))
         (eligible (or (enchiridion.memory.store:field (first rows) "eligible") 0))
         (ranked (or (enchiridion.memory.store:field (first rows) "ranked") 0))
         (wanted (max *tail-min-n* (ceiling (* *tail-rarity-fraction* ranked))))
         (size (min (length rows) ranked wanted)))
    (values (mapcar #'pair-row-task (subseq rows 0 size)) (- eligible ranked) eligible)))

(defun score-pending-tail-answers (store)
  "Score at most one maintenance batch of eligible answers."
  (score-rarity-rows
   store
   (enchiridion.memory.store:query-rows
    store
    (format nil "~A
      SELECT e.id, e.body, e.ts FROM answers a JOIN episodes e ON e.id = a.answer_id
       WHERE e.derived_ts IS NULL ORDER BY e.id LIMIT ?"
            (pair-scope-sql))
    (list (max 1 *memory-maintenance-batch*)))))

;;;; ------------------------------------------------------------------
;;;; 8. The T2 preflight
;;;; ------------------------------------------------------------------

(defun t2-preflight (store &key (canaries *memory-canaries*))
  "Return readiness counts and the current tail sample without writing or calling a model."
  (multiple-value-bind (tail pending eligible) (tail-sample store)
    (multiple-value-bind (families covered-p) (canary-coverage (append canaries (approved-canaries)))
      (let* ((utility (if (minusp *utility-max-tasks*) eligible (min eligible *utility-max-tasks*)))
             (missing (append
                       (unless *assertion-deriver* (list :deriver))
                       (unless covered-p (list :canary-coverage))
                       (when (< utility *memory-gate-min-n*) (list :utility-task-set))
                       (when (< (min eligible +tail-max-tasks+) *tail-min-n*) (list :tail-sampler)))))
        (values (list :ready-p (and (null missing) (zerop pending))
                      :reason (cond (missing :instrument-missing)
                                    ((plusp pending) :maintenance-pending))
                      :missing missing
                      :families families
                      :utility-tasks utility
                      :tail-tasks (length tail)
                      :tail-pending pending)
                tail)))))

;;;; ------------------------------------------------------------------
;;;; 9. The gate pipeline
;;;; ------------------------------------------------------------------

(defun promotion-sum (store generation-id column)
  "Return COLUMN summed over every generation built since the live one, up to
and including GENERATION-ID: what reaching this promotion took, quarantined
attempts included."
  (or (enchiridion.memory.store:field
       (first (enchiridion.memory.store:query-rows
               store
               (format nil "SELECT COALESCE(SUM(~A), 0) AS n FROM generations
                             WHERE id > ? AND id <= ?" column)
               (list (live-generation-id store) generation-id)))
       "n")
      0))

(defun promotion-tokens (store generation-id)
  "Return the tokens the generations since the live one have cost, up to and
including GENERATION-ID."
  (promotion-sum store generation-id "tokens_used"))

(defun promotion-episodes (store generation-id)
  "Return the episodes the generations since the live one derived themselves,
up to and including GENERATION-ID."
  (promotion-sum store generation-id "episodes_derived"))

(defun cost-gate (store generation-id &key (per-episode *memory-writes-per-episode*)
                                           (tokens-per-episode *t2-max-tokens-per-episode*))
  "Return two values: T when GENERATION-ID wrote at most PER-EPISODE rows for
each episode it derived, and the generations since the last promotion cost at
most TOKENS-PER-EPISODE for each episode they derived; and a report.

The cost is per episode and not one number per promotion, because a first
build derives the whole log: a fixed 600,000 quarantined the first build of
any log over about 400 episodes after its tokens were already spent. What
bounds the money is the rolling day cap on T2 spend; this gate bounds how
much each episode's semantics may cost, so a wasteful deriver still fails."
  (let ((tokens (promotion-tokens store generation-id))
        (episodes (promotion-episodes store generation-id)))
    (values (and (volume-gate store generation-id :per-episode per-episode)
                 (<= tokens (* tokens-per-episode episodes)))
            (let ((row (generation-row store generation-id)))
              (list :tokens tokens
                    :episodes-since-promotion episodes
                    :writes (enchiridion.memory.store:field row "writes")
                    :assertions (build-assertion-count store generation-id)
                    :episodes (enchiridion.memory.store:field row "episodes_derived"))))))

(defun record-check (store generation-id kind pass-p report &key (now (get-universal-time)))
  "Write one generation_checks row for KIND and return PASS-P."
  (enchiridion.memory.store:exec
   store
   "INSERT INTO generation_checks (generation_id, kind, result, value, detail, ts)
      VALUES (?, ?, ?, ?, ?, ?)"
   (list generation-id kind (if pass-p "pass" "fail")
         (let ((value (or (getf report :p) (getf report :candidate)
                          (getf report :tokens) (getf report :passed))))
           (and (realp value) (coerce value 'double-float)))
         (prin1-to-string report) now))
  pass-p)

(defun record-shadow-canaries (store generation-id approvals)
  "Report candidate and live results without affecting promotion."
  (handler-case
      (dolist (check (canary-proposals store))
        (let ((id (getf check :name)))
          (unless (find id approvals :test #'equal :key (lambda (row) (getf row :name)))
            (flet ((outcome (target)
                     (handler-case (if (proposal-check-p store check target) :pass :fail)
                       (error () :error))))
              (let ((live (outcome :live))
                    (candidate (outcome generation-id)))
                (record-check store generation-id "shadow-canary" (eq candidate :pass)
                              (list :id id :live live :candidate candidate)))))))
    (error () nil)))

(defun canary-step (store generation-id canaries &optional (approvals (approved-canaries)))
  "Run the canary check for GENERATION-ID and return two values: whether the
suite covered its families and every canary held, and a report.  An unchecked
or uncovered suite fails, because it freezes promotion."
  (let* ((checks (append canaries approvals))
         (blocking (canary-predicate store checks generation-id)))
    (sync-canaries store checks)
    (multiple-value-bind (families covered-p) (canary-coverage checks)
      (let ((result (canary-check store :predicate blocking :checks checks)))
        (values (and covered-p (getf result :ok-p) (plusp (getf result :total)))
                (list :families families :passed (getf result :passed)
                      :failed (getf result :failed) :failures (getf result :failures)))))))

(defun measure-candidate (store generation-id scorer tail)
  "Score the utility tasks and the tail sample under both arms for
GENERATION-ID, and return two values: the tail tasks' hashes and the utility
tasks' hashes, so each gate reads only its own pairs."
  (let* ((tasks (utility-tasks store))
         (tail (if (eq tail :current) (tail-sample store) tail))
         (utility-hashes (mapcar #'task-hash tasks))
         (scored (append tasks (remove-if (lambda (task)
                                            (member (task-hash task) utility-hashes
                                                    :test #'string=))
                                          tail))))
    (compare-arms store generation-id scored scorer)
    (values (mapcar #'task-hash tail) utility-hashes)))

(defun set-promotion-result (store generation-id result &key (reason "")
                                                            (now (get-universal-time)))
  "Record what the gates decided for GENERATION-ID."
  (enchiridion.memory.store:exec
   store
   "UPDATE generations
       SET promotion_result = ?, promotion_checked_ts = ?,
           quarantine_reason = ?,
           status = CASE WHEN ? IN ('quarantined', 'held') THEN ? ELSE status END
     WHERE id = ?"
   (list result now reason result result generation-id)))

(defun gate-candidate (store generation-id &key (canaries *memory-canaries*)
                                               (scorer #'answer-scorer) (tail :current))
  "Run GENERATION-ID through the promotion gates in order and return a report.

The order is provenance, canary, utility, tail, then
volume and cost.  Every gate writes a generation_checks row, and the first
that fails quarantines the candidate with its name as the reason and leaves
the live layer as it was.  A candidate that passes all five is promoted in
one transaction."
  (let ((row (generation-row store generation-id)))
    (unless (and row (string= (enchiridion.memory.store:field row "status") "candidate"))
      (return-from gate-candidate
        (list :promoted nil :reason :not-a-candidate
              :status (and row (enchiridion.memory.store:field row "status"))))))
  (let ((tail-hashes nil) (utility-hashes nil) (approvals (approved-canaries)))
    (flet ((gate (kind thunk)
             (multiple-value-bind (pass-p report) (funcall thunk)
               (record-check store generation-id kind pass-p report)
               (unless pass-p
                 (set-promotion-result store generation-id "quarantined" :reason kind)
                 (return-from gate-candidate
                   (list :promoted nil :reason :quarantined :failed kind :report report))))))
      (gate "provenance" (lambda () (provenance-gate store generation-id)))
      (record-shadow-canaries store generation-id approvals)
      (gate "canary" (lambda () (canary-step store generation-id canaries approvals)))
      (gate "utility" (lambda ()
                        (setf (values tail-hashes utility-hashes)
                              (measure-candidate store generation-id scorer tail))
                        (utility-gate store generation-id :task-hashes utility-hashes)))
      (gate "tail" (lambda () (tail-gate store generation-id tail-hashes)))
      (gate "cost" (lambda () (cost-gate store generation-id)))
      ;; Every gate passed. A freeze still holds the candidate back, and a held
      ;; candidate is not a quarantined one: it is what lowers the quarantine
      ;; rate and lifts that freeze.
      (let ((freeze (promotion-freeze store)))
        (if freeze
            (progn
              (set-promotion-result store generation-id "held"
                                    :reason (string-downcase (symbol-name freeze)))
              (list :promoted nil :reason :held :freeze freeze))
            (progn
              (promote-generation store generation-id)
              (set-promotion-result store generation-id "promoted")
              (list :promoted t :generation-id generation-id)))))))

(defun check-promoted (store generation-id &key (canaries *memory-canaries*)
                                               (scorer #'answer-scorer))
  "Re-run the canary and utility checks on GENERATION-ID, now live, and return
a report. A failure rolls back to the parent and freezes the next pass. The
post-check rows are what the freeze and promotion precision read."
  (let ((row (generation-row store generation-id)))
    (unless (and row (string= (enchiridion.memory.store:field row "status") "live"))
      (return-from check-promoted (list :held nil :reason :not-live))))
  (multiple-value-bind (canary-ok canary-report) (canary-step store generation-id canaries)
    (record-check store generation-id "post-canary" canary-ok canary-report)
    (let ((utility-ok
            (and canary-ok
                 (let ((utility-hashes (nth-value 1 (measure-candidate store generation-id scorer nil))))
                        (multiple-value-bind (ok report)
                            (utility-gate store generation-id :task-hashes utility-hashes)
                          (record-check store generation-id "post-utility" ok report))))))
      (if (and canary-ok utility-ok)
          (list :held t :generation-id generation-id)
          (progn
            (rollback-generation store generation-id)
            (list :held nil :reason :rolled-back
                  :failed (if canary-ok "post-utility" "post-canary")))))))

;;;; ------------------------------------------------------------------
;;;; 10. The autonomy controls
;;;; ------------------------------------------------------------------

(defun first-check-result (store generation-id kind)
  "Return the result of GENERATION-ID's first KIND check, or NIL."
  (enchiridion.memory.store:field
   (first (enchiridion.memory.store:query-rows
           store "SELECT result FROM generation_checks
                   WHERE generation_id = ? AND kind = ? ORDER BY id LIMIT 1"
           (list generation-id kind)))
   "result"))

(defun precision-reset-generation (store)
  "Return the generation id the operator last reset promotion precision at."
  (ensure-generation-state store)
  (or (enchiridion.memory.store:field
       (first (enchiridion.memory.store:query-rows
               store "SELECT precision_reset_generation AS g FROM memory_state WHERE id = 1"))
       "g")
      0))

(defun promotion-precision (store &key (window *precision-window*))
  "Return a plist of the last WINDOW promotions since the operator's reset:
:CHECKED, those that have had their post-promotion check, :PASSED, those
whose first canary and utility runs after promotion both passed, and
:PRECISION, PASSED over CHECKED or NIL when none is checked.
Precision is the share that pass the next canary and
utility run, so a promotion's first post-check is the one that counts."
  (let ((checked 0) (passed 0))
    (dolist (row (enchiridion.memory.store:query-rows
                  store
                  "SELECT id FROM generations
                    WHERE promoted_ts IS NOT NULL AND id > ?
                    ORDER BY id DESC LIMIT ?"
                  (list (precision-reset-generation store) window)))
      (let* ((id (enchiridion.memory.store:field row "id"))
             (canary (first-check-result store id "post-canary")))
        (when canary
          (incf checked)
          (when (and (string= canary "pass")
                     (equal (first-check-result store id "post-utility") "pass"))
            (incf passed)))))
    (list :checked checked :passed passed
          :precision (and (plusp checked) (/ passed checked)))))

(defun quarantine-rate (store &key (window *quarantine-window*))
  "Return a plist of the last WINDOW candidates the gates decided on: :N, how
many, :QUARANTINED, how many were, and :RATE, or NIL when none was gated.
A held candidate passed every gate, so it counts as gated and not quarantined."
  (let* ((rows (enchiridion.memory.store:query-rows
                store
                "SELECT promotion_result FROM generations
                  WHERE promotion_result IN ('promoted', 'quarantined', 'held')
                  ORDER BY promotion_checked_ts DESC, id DESC LIMIT ?"
                (list window)))
         (n (length rows))
         (quarantined (count "quarantined" rows
                             :key (lambda (r) (enchiridion.memory.store:field
                                               r "promotion_result"))
                             :test #'string=)))
    (list :n n :quarantined quarantined :rate (and (plusp n) (/ quarantined n)))))

(defun precision-frozen-p (store)
  "Return T when enough promotions have been checked and too few held up."
  (let ((report (promotion-precision store)))
    (and (>= (getf report :checked) *precision-min-checked*)
         (< (getf report :precision) (rationalize *precision-min*)))))

(defun quarantine-frozen-p (store)
  "Return T when enough candidates have been gated and too many quarantined."
  (let ((report (quarantine-rate store)))
    (and (>= (getf report :n) *quarantine-min-candidates*)
         (> (getf report :rate) (rationalize *quarantine-max*)))))

(defun promotion-freeze (store)
  "Return why promotion is frozen, :PRECISION or :QUARANTINE-RATE, or NIL.
A precision freeze holds until the operator resets it; a quarantine-rate
freeze lifts once held candidates bring the rate back under its ceiling."
  (cond ((precision-frozen-p store) :precision)
        ((quarantine-frozen-p store) :quarantine-rate)))

(defun reset-promotion-precision (store)
  "Start promotion precision afresh from the generations that come next, which
is how the operator lifts a precision freeze, and return the watermark."
  (ensure-generation-state store)
  (let ((watermark (or (enchiridion.memory.store:field
                        (first (enchiridion.memory.store:query-rows
                                store "SELECT COALESCE(MAX(id), 0) AS g FROM generations"))
                        "g")
                       0)))
    (enchiridion.memory.store:exec
     store "UPDATE memory_state SET precision_reset_generation = ? WHERE id = 1"
     (list watermark))
    watermark))

(defun t2-interval (store)
  "Return the seconds between T2 passes: the frozen interval while the
quarantine rate is over its ceiling, the ordinary one otherwise."
  (if (quarantine-frozen-p store) *t2-frozen-interval-seconds* *t2-interval-seconds*))

;;;; ------------------------------------------------------------------
;;;; 11. The T2 schedule and the pass
;;;; ------------------------------------------------------------------

(defun last-t2-ts (store)
  "Return the universal time the last T2 pass ended, or NIL before the first."
  (ensure-generation-state store)
  (enchiridion.memory.store:field
   (first (enchiridion.memory.store:query-rows
           store "SELECT last_t2_ts AS ts FROM memory_state WHERE id = 1"))
   "ts"))

(defconstant +t2-preflight-retry-seconds+ 300)

(defun t2-preflight-signature (canaries)
  "Return the settings key for a missing-instrument retry."
  (content-hash
   (with-standard-io-syntax
     (prin1-to-string
      (list canaries *canary-min-families* (not (null *assertion-deriver*))
            *memory-gate-min-n* *utility-max-tasks*
            *tail-min-n* *tail-rarity-fraction*)))))

(defun mark-t2-preflight-retry (store canaries now)
  "Throttle the next missing-instrument check with unchanged settings."
  (enchiridion.memory.store:exec
   store "INSERT OR REPLACE INTO t2_preflight_retry (id, ts, signature) VALUES (1, ?, ?)"
   (list now (t2-preflight-signature canaries))))

(defun t2-preflight-wait-p (store canaries now)
  "Return whether a recent preflight with the same settings found missing instruments."
  (let ((row (first (enchiridion.memory.store:query-rows
                     store "SELECT ts, signature FROM t2_preflight_retry WHERE id = 1"))))
    (and row
         (< (- now (enchiridion.memory.store:field row "ts"))
            +t2-preflight-retry-seconds+)
         (equal (enchiridion.memory.store:field row "signature")
                (t2-preflight-signature canaries)))))

(defun mark-t2-pass (store &key (now (get-universal-time)))
  "Record that a T2 pass ended at NOW, whatever it decided, with the newest
episode it ended at, and return NOW."
  (enchiridion.memory.store:with-store-transaction (store)
    (ensure-generation-state store)
    (enchiridion.memory.store:exec
     store "UPDATE memory_state
               SET last_t2_ts = ?,
                   last_t2_episode = (SELECT COALESCE(MAX(id), 0) FROM episodes)
             WHERE id = 1"
     (list now))
    (enchiridion.memory.store:exec store "DELETE FROM t2_preflight_retry WHERE id = 1"))
  now)

(defun new-episode-count (store)
  "Return how many episodes arrived after the last T2 pass ended."
  (ensure-generation-state store)
  (or (enchiridion.memory.store:field
       (first (enchiridion.memory.store:query-rows
               store
               "SELECT COUNT(*) AS n FROM episodes
                 WHERE id > (SELECT COALESCE(last_t2_episode, 0) FROM memory_state
                              WHERE id = 1)"))
       "n")
      0))

(defun t2-due-p (store &key (now (get-universal-time)) (canaries *memory-canaries*))
  "Return T when a T2 pass should run on this tick.
A building candidate always continues, because a pass spans as many ticks as
its episodes need. Otherwise it runs daily or after
*T2-EPISODE-THRESHOLD* new episodes, whichever comes first. While the
quarantine rate is over its ceiling the interval is weekly and the threshold
is off, or a busy log would make weekly mean nothing."
  (or (and (current-building-generation store) t)
      (let ((last (last-t2-ts store)))
        (and (or (null last)
                 (>= (- now last) (t2-interval store))
                 (and (not (quarantine-frozen-p store))
                      (>= (new-episode-count store) *t2-episode-threshold*)))
             (not (t2-preflight-wait-p store canaries now))))))

(defun t2-pass-spend (store &key (now (get-universal-time)))
  "Return the tokens T2 has spent in the rolling twenty-four hours before NOW."
  (getf (enchiridion.memory.store:usage-total-since store (- now 86400) :channel :t2)
        :total))

(defun t2-refusal (store &key (now (get-universal-time)))
  "Return why no T2 pass may run on this tick, or NIL."
  (cond
    ((or (not (enabled-p)) (not *t2-enabled-p*)) :disabled)
    ((not (t2-due-p store :now now)) :not-due)
    ;; Held candidates can lift a quarantine freeze, but only the operator lifts a precision freeze
    ((precision-frozen-p store) :frozen-precision)
    ((>= (t2-pass-spend store :now now) *t2-max-tokens-per-pass*) :pass-budget-spent)
    (t nil)))

(defun live-unchecked-p (store generation-id)
  "Return T when GENERATION-ID is live and has had no post-promotion check."
  (and (plusp generation-id)
       (null (first-check-result store generation-id "post-canary"))))

(defun gate-t2-candidate (store generation-id &key canaries scorer now tail (recovered nil))
  "Gate GENERATION-ID, end the pass, and return the plist RUN-T2-PASS returns.
RECOVERED says the candidate was built by an earlier pass and never gated."
  (let ((gate (gate-candidate store generation-id :canaries canaries :scorer scorer :tail tail)))
    (mark-t2-pass store :now (or now (get-universal-time)))
    (list :outcome (cond ((getf gate :promoted) :promoted)
                         ((eq (getf gate :reason) :held) :held)
                         ((eq (getf gate :reason) :quarantined) :quarantined)
                         (t :skipped))
          :generation-id generation-id
          :failed (getf gate :failed)
          :freeze (getf gate :freeze)
          :reason (getf gate :reason)
          :recovered recovered)))

(defun run-t2-pass (store &key (canaries *memory-canaries*)
                               (scorer #'answer-scorer)
                               (limit *memory-t2-episodes-per-tick*)
                               now)
  "Run one tick of a T2 pass and return a report plist whose :OUTCOME is one
of :ROLLED-BACK, :INSTRUMENT-MISSING, :MAINTENANCE-PENDING, :BUILDING,
:PROMOTED, :QUARANTINED, :HELD, or :SKIPPED. The caller has already asked T2-REFUSAL.

A pass that starts after a promotion first re-checks the live generation:
A failed post-promotion check rolls back and
freezes the next pass, so a rollback ends this pass with nothing built. A new
candidate is started only when the preflight finds every instrument, so no
tokens go to a candidate nobody could promote. A candidate an earlier pass built
and never gated is gated before a new build starts, so a crash between building
and gating does not waste its derivations. LAST_T2_TS is written when a pass
ends, not while a candidate is building or waiting for rarity."
  (let* ((live (live-generation-id store))
         (building (current-building-generation store))
         (unchecked (and (null building) (live-unchecked-p store live)))
         (caught-up nil))
    (flet ((prepare-tail (sample pending)
             (when (and (plusp pending) (not caught-up))
               (setf caught-up t)
               (score-pending-tail-answers store)
               (setf (values sample pending) (tail-sample store)))
             (when (plusp pending)
               (return-from run-t2-pass
                 (list :outcome :maintenance-pending :tail-pending pending)))
             sample))
      (when unchecked
        (let ((check (check-promoted store live :canaries canaries :scorer scorer)))
          (unless (getf check :held)
            (mark-t2-pass store :now (or now (get-universal-time)))
            (return-from run-t2-pass
              (list :outcome :rolled-back :generation-id live :failed (getf check :failed))))))
      (unless building
        (multiple-value-bind (preflight sample) (t2-preflight store :canaries canaries)
          (when (getf preflight :missing)
            (mark-t2-preflight-retry store canaries (or now (get-universal-time)))
            (return-from run-t2-pass (list* :outcome :instrument-missing preflight)))
          (let ((tail (prepare-tail sample (getf preflight :tail-pending)))
                (stranded (complete-candidate-generation store)))
            (when stranded
              (return-from run-t2-pass
                (gate-t2-candidate store stranded :canaries canaries :scorer scorer
                                   :now now :tail tail :recovered t))))))
      (let ((build (build-candidate store :limit limit)))
        (cond
          ((eq (getf build :reason) :claimed)
           (list :outcome :building
                 :generation-id (getf build :generation-id)
                 :remaining (getf build :remaining)
                 :claimed t))
          ((not (getf build :built))
           (list :outcome :skipped :reason (getf build :reason)))
          ((eq (getf build :status) :building)
           (list :outcome :building
                 :generation-id (getf build :generation-id)
                 :remaining (getf build :remaining)
                 :skipped (getf build :skipped)
                 :failed (getf build :failed)))
          (t
           (multiple-value-bind (sample pending) (tail-sample store)
             (gate-t2-candidate store (getf build :generation-id)
                                :canaries canaries :scorer scorer :now now
                                :tail (prepare-tail sample pending)))))))))
