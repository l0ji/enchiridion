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

(defun register-canary (store name expect &key (now (get-universal-time)))
  "Add or replace one canary.  NAME identifies it; EXPECT is what must hold.

EXPECT is stored as text because the check is deliberately not fixed here.
model-unified.md §6.4 requires that the check test BEHAVIOUR rather than
presence, and behaviour is application-specific: an operator supplies the
predicate, not this file."
  (enchiridion.memory.store:exec
   store
   "INSERT INTO canary (name, expect, ts) VALUES (?, ?, ?)
    ON CONFLICT(name) DO UPDATE SET expect = ?, ts = ?"
   (list name expect now expect now)))

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

SCORER is a function of (STORE CUE PUSHED ROWS) returning a number.  ROWS are
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
             (value (handler-case (funcall scorer store cue pushed rows)
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
