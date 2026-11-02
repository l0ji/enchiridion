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
         (bodies (mapcar (lambda (row) (or (getf (getf row :item) :body) "")) rows))
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

(defun utility-gate (store &key (margin *memory-gate-margin*)
                                     (min-n *memory-gate-min-n*))
  "Return T when consolidation beats retention-only by at least MARGIN.

Reads the gate log, which RUN-ARM writes.  Returns NIL when there is not
enough evidence, which is the correct default: an unmeasured consolidation
does not run.

The comparison is against a retention-only baseline at matched difficulty and
budget, not against nothing.  That is the harder test the adverse result
demands."
  (let ((rows (enchiridion.memory.store:query-rows
               store
               "SELECT arm, AVG(value) AS mean, COUNT(*) AS n
                  FROM gate_log
                 WHERE metric = 'outcome'
                 GROUP BY arm")))
    (let ((cons (find "consolidate" rows
                      :key (lambda (r) (enchiridion.memory.store:field r "arm"))
                      :test #'string=))
          (ret (find "retention" rows
                     :key (lambda (r) (enchiridion.memory.store:field r "arm"))
                     :test #'string=)))
      (and cons ret
           (>= (or (enchiridion.memory.store:field cons "n") 0) min-n)
           (>= (or (enchiridion.memory.store:field ret "n") 0) min-n)
           (>= (- (or (enchiridion.memory.store:field cons "mean") 0.0)
                  (or (enchiridion.memory.store:field ret "mean") 0.0))
               margin)))))

(defun volume-gate (store generation-id &key (max-writes *memory-write-cap*))
  "Return T when GENERATION-ID's build wrote at most MAX-WRITES semantic rows.

The cap exists because interference is constantly present: what a system
writes between encoding a record and retrieving it determines whether the
record survives, with no deletion policy in play.  High-volume passive
learning therefore degrades older records by competition alone.  The count is
the generation's own WRITES column, which BUILD-CANDIDATE keeps, so the gate
measures the candidate it is asked about and not a run that never happened."
  (let ((row (first (enchiridion.memory.store:query-rows
                     store "SELECT writes FROM generations WHERE id = ?"
                     (list generation-id)))))
    (and row
         (<= (or (enchiridion.memory.store:field row "writes") 0) max-writes))))

;;;; ------------------------------------------------------------------
;;;; 6. Measurement
;;;; ------------------------------------------------------------------

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

(defun answer-scorer (store task pushed rows)
  "Score TASK 1 when its answer reached ROWS and 0 when it did not."
  (declare (ignore store pushed))
  (if (answer-hit-p rows (getf task :expect-episode)) 1.0 0.0))

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
         (tail (tail-tasks store tasks)))
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
