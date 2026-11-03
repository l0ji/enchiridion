;;;; gates.cl --- The canary set, the promotion gates, and the arms they measure.
;;;;
;;;; Split from cue.cl because measurement reads retrieval and generations,
;;;; and both load after the cue layer. The order of record for the gates is
;;;; docs/design/memory.md: provenance, canary, utility, tail, then volume and
;;;; cost. The legacy single-pass consolidation they once guarded is gone; a
;;;; generation becomes live only through PROMOTE-GENERATION.

(in-package #:enchiridion.memory)

;;;; ------------------------------------------------------------------
;;;; 4. The canary set (store 12)
;;;; ------------------------------------------------------------------

(defun register-canary (store name expect &key (family "") (now (get-universal-time)))
  "Add or replace one canary.  NAME identifies it; EXPECT is what must hold;
FAMILY is the kind of behaviour it checks.

EXPECT is stored as text because the check is deliberately not fixed here.
model-unified.md §6.4 requires that the check test BEHAVIOUR rather than
presence: CANARY-PREDICATE supplies the check for each family."
  (enchiridion.memory.store:exec
   store
   "INSERT INTO canary (name, expect, family, ts) VALUES (?, ?, ?, ?)
    ON CONFLICT(name) DO UPDATE SET expect = ?, family = ?, ts = ?"
   (list name expect family now expect family now)))

(defparameter +canary-families+ '("retrieval" "update" "safety" "tail")
  "The four canary families docs/design/memory.md requires: retrieval,
update or conflict, safety, and degradation or the tail.")

(defun canary-text (canary key)
  "Return CANARY's KEY as a non-empty string, or NIL."
  (let ((value (getf canary key)))
    (and (stringp value) (plusp (length value)) value)))

(defun valid-canary-p (canary)
  "Return T when CANARY names a known family and carries what its check reads:
a name, a cue, an expectation, and for the update family the stale value."
  (let ((family (canary-text canary :family)))
    (and (canary-text canary :name)
         family
         (member family +canary-families+ :test #'string-equal)
         (canary-text canary :cue)
         (canary-text canary :expect)
         (or (not (string-equal family "update"))
             (canary-text canary :stale))
         t)))

(defun canary-coverage (canaries)
  "Return two values: the families the valid CANARIES cover, and whether they
cover *CANARY-MIN-FAMILIES* of them."
  (let ((families (remove-duplicates
                   (mapcar (lambda (c) (string-downcase (getf c :family)))
                           (remove-if-not #'valid-canary-p canaries))
                   :test #'string=)))
    (values families (>= (length families) *canary-min-families*))))

(defun sync-canaries (store canaries)
  "Make the canary table hold exactly the valid CANARIES and return how many.
config.cl is the canaries' only source, so a canary the operator removed is
removed here too rather than lingering as one that never runs."
  (let ((valid (remove-if-not #'valid-canary-p canaries)))
    (enchiridion.memory.store:with-store-transaction (store)
      (dolist (canary valid)
        (register-canary store (getf canary :name) (getf canary :expect)
                         :family (string-downcase (getf canary :family))))
      (dolist (row (enchiridion.memory.store:query-rows store "SELECT name FROM canary"))
        (let ((name (enchiridion.memory.store:field row "name")))
          (unless (find name valid :key (lambda (c) (getf c :name)) :test #'string=)
            (enchiridion.memory.store:exec store "DELETE FROM canary WHERE name = ?"
                                           (list name))))))
    (length valid)))

(defun canary-behaviour-p (store canary generation)
  "Return T when CANARY's behaviour holds in a retrieval reading GENERATION.

Each family asserts behaviour under a controlled cue, never mere presence in
the store: retrieval and tail, that the cue brings back a record holding the
expectation; update, that the newer value ranks above the stale one; safety,
that no record holding the forbidden text reaches the pack."
  (let* ((rows (retrieve-rows-for-turn store (getf canary :cue) :generation generation))
         (bodies (mapcar (lambda (row) (format nil "~{~A~^~%~}" (row-texts row))) rows))
         (expect (getf canary :expect)))
    (flet ((rank (text)
             (position-if (lambda (body) (search text body :test #'char-equal)) bodies)))
      (let ((family (string-downcase (getf canary :family))))
        (cond
          ((member family '("retrieval" "tail") :test #'string=)
           (not (null (rank expect))))
          ((string= family "safety")
           (null (rank expect)))
          ((string= family "update")
           (let ((new (rank expect)) (old (rank (getf canary :stale))))
             (and new (or (null old) (< new old)))))
          (t (error "~A is not a canary family." family)))))))

(defun canary-predicate (store canaries generation)
  "Return the CANARY-CHECK predicate that checks each of CANARIES against a
retrieval reading GENERATION. A canary the table holds but CANARIES does not
name fails, because a check with nothing to run must not pass."
  (lambda (name expect)
    (declare (ignore expect))
    (let ((canary (find name canaries :key (lambda (c) (getf c :name)) :test #'equal)))
      (and canary (valid-canary-p canary)
           (canary-behaviour-p store canary generation)))))

(defun canary-check (store &key (predicate nil) (now (get-universal-time)))
  "Run every canary through PREDICATE and return a report plist.

PREDICATE is called with (NAME EXPECT) and must return non-NIL when the
behaviour still holds.  When PREDICATE is NIL every canary is reported as
:unchecked rather than as passing -- a canary suite that reports success when
it has not run is worse than no suite, because it supplies false assurance.
That is the same failure the measured presence-check result identifies."
  (let ((rows (enchiridion.memory.store:query-rows
               store "SELECT id, name, expect FROM canary ORDER BY id"))
        (passed 0) (failed 0) (unchecked 0) (failures '()))
    (dolist (row rows)
      (let* ((name (enchiridion.memory.store:field row "name"))
             (expect (enchiridion.memory.store:field row "expect"))
             (id (enchiridion.memory.store:field row "id"))
             (ok (if predicate
                     (handler-case (not (null (funcall predicate name expect)))
                       (error () nil))
                     :unchecked)))
        (cond ((eq ok :unchecked) (incf unchecked))
              (ok (incf passed)
                  (enchiridion.memory.store:exec
                   store "UPDATE canary SET last_pass = ?, last_checked = ? WHERE id = ?"
                   (list now now id)))
              (t (incf failed) (push name failures)
                 (enchiridion.memory.store:exec
                  store "UPDATE canary SET last_checked = ? WHERE id = ?"
                  (list now id))))))
    (list :ok-p (and predicate (zerop failed))
          :passed passed :failed failed :unchecked unchecked
          :failures (nreverse failures)
          :total (length rows))))

(defun canary-report (result)
  "Return a one-line report for RESULT, as SUPERVISOR-TICK expects."
  (format nil "canary: ~D pass, ~D fail, ~D unchecked of ~D"
          (getf result :passed) (getf result :failed)
          (getf result :unchecked) (getf result :total)))

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

(defun paired-outcomes (store generation-id &key task-hashes)
  "Return GENERATION-ID's outcome pairs as a list of (RETENTION . CANDIDATE),
one per task both arms scored, from the latest row of each.

The rows are the ones RUN-ARM wrote under the candidate's id and each task's
hash, so a pair is the same question asked of the two arms. TASK-HASHES, when
given, keeps only those tasks."
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
        (when (or (null task-hashes) (member hash task-hashes :test #'string=))
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
                                              (task-hashes nil))
  "Return two values: T when GENERATION-ID beats retention-only, and a report.

docs/design/memory.md: candidate versus retention-only on paired tasks at
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

docs/design/memory.md states the tail as recall, so an outcome counts as one
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

(defun utility-tasks (store &key (limit *utility-max-tasks*))
  "Return up to LIMIT tasks derived from the log, newest first.

A task is a question the operator asked and the reply that answered it: the
user episode is the cue, and the assistant episode that came next in the same
session is the record a good memory brings back. Every exchange in the log is
one, so the set grows with use and needs nobody to write it. The sleep
channel's own turns are not exchanges and are left out."
  (mapcar (lambda (row)
            (list :name (format nil "answer-~D"
                                (enchiridion.memory.store:field row "cue_id"))
                  :cue (enchiridion.memory.store:field row "cue")
                  :cue-episode (enchiridion.memory.store:field row "cue_id")
                  :expect-episode (enchiridion.memory.store:field row "answer_id")))
          (enchiridion.memory.store:query-rows
           store
           "SELECT u.id AS cue_id, u.body AS cue, a.id AS answer_id
              FROM episodes u
              JOIN episodes a
                ON a.id = (SELECT MIN(x.id) FROM episodes x
                            WHERE x.session = u.session AND x.id > u.id
                              AND x.channel <> 'sleep' AND x.role <> 'memory')
             WHERE u.role = 'user' AND u.channel <> 'sleep'
               AND a.role = 'assistant'
             ORDER BY u.id DESC
             LIMIT ?"
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

(defun tail-tasks (store tasks)
  "Return the TASKS whose answer is one of the rarest episodes.
The tail gate scores these: what a consolidation loses first is the rare
record, so its recall is measured on the questions whose answers are rare."
  (let ((rare (rare-episode-ids store)))
    (remove-if-not (lambda (task) (gethash (getf task :expect-episode) rare))
                   tasks)))

(defun tail-sample (store)
  "Return the tasks with a rare answer from every question and answer in the
log, not only the newest :UTILITY-MAX-TASKS.

The utility set is the newest pairs because it bounds a run's size. The tail
is not: the rare records are wherever the log put them, and on an imported log
of 1,094 pairs the newest 400 held 6 rare answers where the whole log held
111, so a tail drawn from the utility set kept the tail sampler missing for
good. Scoring the tail is retrieval only and calls no model."
  (tail-tasks store (utility-tasks store :limit most-positive-fixnum)))

;;;; ------------------------------------------------------------------
;;;; 8. The T2 preflight
;;;; ------------------------------------------------------------------

(defun t2-preflight (store &key (canaries *memory-canaries*))
  "Return a plist saying whether a T2 pass has every instrument it needs.

docs/design/memory.md: a pass with a missing deriver, canary coverage,
utility task set, or tail sampler is a reported no-op with reason
:INSTRUMENT-MISSING, so it never spends tokens on a candidate nobody could
promote. :MISSING names each absent instrument, so the report says what the
operator has to supply rather than only that something is wrong."
  (let* ((tasks (utility-tasks store))
         (tail (tail-sample store)))
    (multiple-value-bind (families covered-p) (canary-coverage canaries)
      (let ((missing
              (append
               (unless *assertion-deriver* (list :deriver))
               (unless covered-p (list :canary-coverage))
               (unless (>= (length tasks) *memory-gate-min-n*) (list :utility-task-set))
               (unless (>= (length tail) *tail-min-n*) (list :tail-sampler)))))
        (list :ready-p (null missing)
              :reason (and missing :instrument-missing)
              :missing missing
              :families families
              :utility-tasks (length tasks)
              :tail-tasks (length tail))))))

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

(defun canary-step (store generation-id canaries)
  "Run the canary check for GENERATION-ID and return two values: whether the
suite covered its families and every canary held, and a report.  An unchecked
or uncovered suite fails, because it freezes promotion."
  (sync-canaries store canaries)
  (multiple-value-bind (families covered-p) (canary-coverage canaries)
    (let ((result (canary-check store
                                :predicate (canary-predicate store canaries generation-id))))
      (values (and covered-p (getf result :ok-p) (plusp (getf result :total)))
              (list :families families :passed (getf result :passed)
                    :failed (getf result :failed) :failures (getf result :failures))))))

(defun measure-candidate (store generation-id scorer)
  "Score the utility tasks and the tail sample under both arms for
GENERATION-ID, and return two values: the tail tasks' hashes and the utility
tasks' hashes, so each gate reads only its own pairs."
  (let* ((tasks (utility-tasks store))
         (tail (tail-sample store))
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
                                               (scorer #'answer-scorer))
  "Run GENERATION-ID through the promotion gates in order and return a report.

docs/design/memory.md fixes the order: provenance, canary, utility, tail, then
volume and cost.  Every gate writes a generation_checks row, and the first
that fails quarantines the candidate with its name as the reason and leaves
the live layer as it was.  A candidate that passes all five is promoted in
one transaction."
  (let ((row (generation-row store generation-id)))
    (unless (and row (string= (enchiridion.memory.store:field row "status") "candidate"))
      (return-from gate-candidate
        (list :promoted nil :reason :not-a-candidate
              :status (and row (enchiridion.memory.store:field row "status"))))))
  (let ((tail-hashes nil) (utility-hashes nil))
    (flet ((gate (kind thunk)
             (multiple-value-bind (pass-p report) (funcall thunk)
               (record-check store generation-id kind pass-p report)
               (unless pass-p
                 (set-promotion-result store generation-id "quarantined" :reason kind)
                 (return-from gate-candidate
                   (list :promoted nil :reason :quarantined :failed kind :report report))))))
      (gate "provenance" (lambda () (provenance-gate store generation-id)))
      (gate "canary" (lambda () (canary-step store generation-id canaries)))
      (gate "utility" (lambda ()
                        (setf (values tail-hashes utility-hashes)
                              (measure-candidate store generation-id scorer))
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
a report.  A failure rolls it back to its parent: docs/design/memory.md says a
failed post-promotion check rolls back and freezes the next pass, and the
post-check rows are what the freeze and promotion precision read."
  (let ((row (generation-row store generation-id)))
    (unless (and row (string= (enchiridion.memory.store:field row "status") "live"))
      (return-from check-promoted (list :held nil :reason :not-live))))
  (multiple-value-bind (canary-ok canary-report) (canary-step store generation-id canaries)
    (record-check store generation-id "post-canary" canary-ok canary-report)
    (let ((utility-ok
            (and canary-ok
                 (let ((utility-hashes (nth-value 1 (measure-candidate store generation-id scorer))))
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
docs/design/memory.md: precision is the share that pass the next canary and
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

(defun mark-t2-pass (store &key (now (get-universal-time)))
  "Record that a T2 pass ended at NOW, whatever it decided, with the newest
episode it ended at, and return NOW."
  (ensure-generation-state store)
  (enchiridion.memory.store:exec
   store "UPDATE memory_state
             SET last_t2_ts = ?,
                 last_t2_episode = (SELECT COALESCE(MAX(id), 0) FROM episodes)
           WHERE id = 1"
   (list now))
  now)

(defun new-episode-count (store)
  "Return how many episodes arrived after the last T2 pass ended.
It counts from the pass and not from what any build derived: a pass that built
nothing, for a missing instrument, would otherwise leave the threshold crossed,
and T2 would run on every tick."
  (ensure-generation-state store)
  (or (enchiridion.memory.store:field
       (first (enchiridion.memory.store:query-rows
               store
               "SELECT COUNT(*) AS n FROM episodes
                 WHERE id > (SELECT COALESCE(last_t2_episode, 0) FROM memory_state
                              WHERE id = 1)"))
       "n")
      0))

(defun t2-due-p (store &key (now (get-universal-time)))
  "Return T when a T2 pass should run on this tick.
A building candidate always continues, because a pass spans as many ticks as
its episodes need. Otherwise docs/design/memory.md: daily or after
*T2-EPISODE-THRESHOLD* new episodes, whichever comes first. While the
quarantine rate is over its ceiling the interval is weekly and the threshold
is off, or a busy log would make weekly mean nothing."
  (let ((last (last-t2-ts store)))
    (or (and (current-building-generation store) t)
        (null last)
        (>= (- now last) (t2-interval store))
        (and (not (quarantine-frozen-p store))
             (>= (new-episode-count store) *t2-episode-threshold*)))))

(defun t2-pass-spend (store &key (now (get-universal-time)))
  "Return the tokens T2 has spent in the rolling twenty-four hours before NOW."
  (getf (enchiridion.memory.store:usage-total-since store (- now 86400) :channel :t2)
        :total))

(defun maintenance-backlog (store)
  "Return how many episodes maintenance has not derived yet."
  (or (enchiridion.memory.store:field
       (first (enchiridion.memory.store:query-rows
               store "SELECT COUNT(*) AS n FROM episodes WHERE derived_ts IS NULL"))
       "n")
      0))

(defun t2-refusal (store &key (now (get-universal-time)))
  "Return why no T2 pass may run on this tick, as a keyword, or NIL.
A missing instrument is not a refusal here: the pass reports it with the list
of what is missing, and spends nothing doing so.

A maintenance backlog is: the tail sample reads rarity, which maintenance
derives a batch per tick, so after a large import the preflight would find too
few rare answers, call the instruments missing, and end the pass for a whole
interval although a few more ticks would have supplied them. A refusal ends no
pass, so T2 runs on the first tick the backlog is clear."
  (cond
    ((or (not (enabled-p)) (not *t2-enabled-p*)) :disabled)
    ((not (t2-due-p store :now now)) :not-due)
    ((plusp (maintenance-backlog store)) :maintenance-pending)
    ;; Only the operator lifts a precision freeze, so a pass during one could
    ;; only spend. A quarantine-rate freeze is not refused: held candidates
    ;; are what lift it, and T2-INTERVAL already slows it to weekly.
    ((precision-frozen-p store) :frozen-precision)
    ((>= (t2-pass-spend store :now now) *t2-max-tokens-per-pass*) :pass-budget-spent)
    (t nil)))

(defun live-unchecked-p (store generation-id)
  "Return T when GENERATION-ID is live and has had no post-promotion check."
  (and (plusp generation-id)
       (null (first-check-result store generation-id "post-canary"))))

(defun run-t2-pass (store &key (canaries *memory-canaries*)
                               (scorer #'answer-scorer)
                               (limit *memory-t2-episodes-per-tick*)
                               (now (get-universal-time)))
  "Run one tick of a T2 pass and return a report plist whose :OUTCOME is one
of :ROLLED-BACK, :INSTRUMENT-MISSING, :BUILDING, :PROMOTED, :QUARANTINED,
:HELD, or :SKIPPED. The caller has already asked T2-REFUSAL.

A pass that starts after a promotion first re-checks the live generation:
docs/design/memory.md says a failed post-promotion check rolls back and
freezes the next pass, so a rollback ends this pass with nothing built. A new
candidate is started only when the preflight finds every instrument, so no
tokens go to a candidate nobody could promote. LAST_T2_TS is written whenever
a pass ends, and not while a candidate is still building."
  (let ((live (live-generation-id store))
        (building (current-building-generation store)))
    (when (and (null building) (live-unchecked-p store live))
      (let ((check (check-promoted store live :canaries canaries :scorer scorer)))
        (unless (getf check :held)
          (mark-t2-pass store :now now)
          (return-from run-t2-pass
            (list :outcome :rolled-back :generation-id live :failed (getf check :failed))))))
    (unless building
      (let ((preflight (t2-preflight store :canaries canaries)))
        (unless (getf preflight :ready-p)
          (mark-t2-pass store :now now)
          (return-from run-t2-pass
            (list :outcome :instrument-missing :missing (getf preflight :missing))))))
    (let ((build (build-candidate store :limit limit)))
      (cond
        ((not (getf build :built))
         (list :outcome :skipped :reason (getf build :reason)))
        ((eq (getf build :status) :building)
         (list :outcome :building
               :generation-id (getf build :generation-id)
               :remaining (getf build :remaining)
               :skipped (getf build :skipped)
               :failed (getf build :failed)))
        (t
         (let* ((generation-id (getf build :generation-id))
                (gate (gate-candidate store generation-id
                                      :canaries canaries :scorer scorer)))
           (mark-t2-pass store :now now)
           (list :outcome (cond ((getf gate :promoted) :promoted)
                                ((eq (getf gate :reason) :held) :held)
                                ((eq (getf gate :reason) :quarantined) :quarantined)
                                (t :skipped))
                 :generation-id generation-id
                 :failed (getf gate :failed)
                 :freeze (getf gate :freeze)
                 :reason (getf gate :reason))))))))
