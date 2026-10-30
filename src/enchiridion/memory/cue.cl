;;;; cue.lisp --- The cue, push, and gate layer.
;;;;
;;;; Ported from research/human-like-agent-memory/build/cue.lisp.
;;;; The specification of record is model-unified.md plus
;;;; docs/design/memory.md. The sketch predates the autonomous-memory
;;;; amendment and is reference material only.
;;;;
;;;; This file adds the cue index, the push channels, the canary set, the
;;;; promotion gates, and the measurement harness. It rewrites nothing in the
;;;; core. The package is the core package; the extension is a layer, not a
;;;; second package, so the two halves share one export list.

(in-package #:enchiridion.memory)

;;;; ------------------------------------------------------------------
;;;; 0. Constants
;;;; ------------------------------------------------------------------

(defparameter +working-set-budget+ 4450
  "The cue pack budget in characters. The five resident blocks are charged
separately (4,150 characters), so this is not the whole prompt. The figure is
the amended specification's 4,450; the audit showed that number is the host's
block sum, so this profile uses it as the pack budget and states the
divergence in docs/design/memory.md. Push competes for half of it.")

(defparameter +push-max-fraction+ 0.5
  "The most of the working set that push may occupy.  INVENTED-DESIGN.  The
justification is structural rather than measured: push must not be able to
evict a retrieved record the cue ranked above it, and capping push at half the
budget makes that guarantee enforceable rather than aspirational.")

;;;; ------------------------------------------------------------------
;;;; 1. Schema for the three new stores
;;;; ------------------------------------------------------------------

(defun ensure-ext-schema (store)
  "Create the extension's three tables on STORE and return the count run."
  (let ((count 0))
    (dolist (statement +ext-schema+ count)
      (enchiridion.memory.store:exec store statement)
      (incf count))))

;;;; ------------------------------------------------------------------
;;;; 2. The cue index
;;;; ------------------------------------------------------------------

(defun cue-terms (terms)
  "Return TERMS, a string or a list of strings, as a de-duplicated token list.

The core's NORMALISE-TERMS operates on TERMS structs, not on strings, so it
cannot be reused here.  This is the string-side counterpart, and it uses the
core's own TOKENISE and stop-word list so that a cue recorded at write time and
a cue computed at read time are comparable by construction rather than by
convention."
  (let ((seen (make-hash-table :test #'equal))
        (out '()))
    (dolist (text (ensure-list terms) (nreverse out))
      (dolist (tok (tokenise (string text)))
        (unless (or (gethash tok seen)
                    (member tok +stop-words+ :test #'string=)
                    (< (length tok) 2))
          (setf (gethash tok seen) t)
          (push tok out))))))

(defun index-cue (store terms kind ref &key (used nil) (now (get-universal-time)))
  "Record that TERMS were the live cue when KIND/REF was used, or not used.

One row per (term, kind, ref).  A repeat sighting raises USES rather than
inserting, so a fact seen a hundred times stays one row -- the same discipline
the harness's neighbour documents as recall-loop prevention.

USED says whether the record was actually referenced.  The distinction is the
whole point of the index: a cue that reliably precedes USE is a cue worth
pushing, and a cue that precedes mere presence is not."
  (let ((n 0))
    (dolist (term (cue-terms terms) n)
      (when (plusp (length term))
        (enchiridion.memory.store:exec
         store
         "INSERT INTO cue_index (term, kind, ref, uses, last_used)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(term, kind, ref)
            DO UPDATE SET uses = uses + ?,
                          last_used = ?"
         (list term (string-downcase (string kind)) ref
               (if used 1 0) now
               (if used 1 0) now))
        (incf n)))))

(defun cue-index-for (store term &key (limit 20) (min-uses 1))
  "Return (KIND . REF) pairs whose cue is TERM and which have been USED.

Ranked by USES descending then recency, which is a frequency-and-recency
ordering rather than a similarity one.  A record enters the cue index only
because it was USED under that cue before, so this channel is keyed on
demonstrated prior usefulness by construction."
  (mapcar (lambda (row)
            (cons (enchiridion.memory.store:field row "kind")
                  (enchiridion.memory.store:field row "ref")))
          (enchiridion.memory.store:query-rows
           store
           "SELECT kind, ref, uses, last_used
              FROM cue_index
             WHERE term = ? AND uses >= ?
             ORDER BY uses DESC, last_used DESC
             LIMIT ?"
           (list term min-uses limit))))

(defun cue-index-many (store terms &key (limit 20) (min-uses 1))
  "Union CUE-INDEX-FOR over every term in TERMS, best first, de-duplicated.

Defined before PUSH-PACK, which calls it: a forward reference would compile
with a style warning that this project's own build treats as a failure."
  (let ((seen (make-hash-table :test #'equal))
        (out '()))
    (dolist (term (cue-terms terms) (nreverse out))
      (dolist (pair (cue-index-for store term :limit limit :min-uses min-uses))
        (unless (gethash pair seen)
          (setf (gethash pair seen) t)
          (push pair out))))))

(defun cue-index-size (store)
  "Return the number of rows in the cue index."
  (let ((row (first (enchiridion.memory.store:query-rows
                     store "SELECT COUNT(*) AS n FROM cue_index"))))
    (or (enchiridion.memory.store:field row "n") 0)))

(defun prune-cue-index (store &key (older-than 7776000) (now (get-universal-time)))
  "Drop cue rows unused for OLDER-THAN seconds (default 90 days).  Return count.

Pruning is safe because the index is derived: a pruned row is rebuilt the next
time its cue and its record co-occur and the record is used."
  (enchiridion.memory.store:exec
   store "DELETE FROM cue_index WHERE last_used < ?" (list (- now older-than))))

;;;; ------------------------------------------------------------------
;;;; 3. The four push channels (T1)
;;;; ------------------------------------------------------------------

(defun precondition-surfacing (store state &key (limit 4))
  "Return procedures whose APPLICABLE-WHEN conditions all hold in STATE.

STATE is a list of observable keywords (tool names available, the working
directory's basename, the last tool's outcome, world-block terms).  This is the
structural counterpart of the hint: the system supplies the cue rather than
waiting for a request.

A procedure is surfaced when every whitespace-separated term in its
APPLICABLE_WHEN appears in STATE, and it has been admitted (ADMITTED_TS is not
null).  No model is called: the check is set containment over upcased strings."
  (let ((rows (handler-case
                  (enchiridion.memory.store:query-rows
                   store
                   "SELECT id, name, applicable_when FROM procedures
                     WHERE admitted_ts IS NOT NULL AND retired_ts IS NULL
                     ORDER BY evidence_count DESC
                     LIMIT ?"
                   (list limit))
                (error () nil)))
        (have (let ((h (make-hash-table :test #'equal)))
                (dolist (k (ensure-list state) h)
                  (setf (gethash (string-upcase (string k)) h) t)))))
    (loop for row in rows
          for pre = (enchiridion.memory.store:field row "applicable_when")
          when (and pre (plusp (length pre)))
            when (every (lambda (k) (gethash (string-upcase k) have))
                        (split-string pre))
              collect (list :kind :procedure
                            :ref (enchiridion.memory.store:field row "id")
                            :name (enchiridion.memory.store:field row "name")))))

(defun split-string (text &optional (separator #\Space))
  "Split TEXT on SEPARATOR, dropping empty fields."
  (loop for start = 0 then (1+ end)
        for end = (position separator text :start start)
        for piece = (subseq text start (or end (length text)))
        unless (zerop (length piece)) collect piece
        while end))

(defun learned-state-block (store &key (limit 12) (char-budget 1200)
                                      (now (get-universal-time)))
  "Return the compiled learned-state block: the highest-importance live assertions.

This is structurally the harness's operator blocks, except its content is
derived from the log rather than written by the operator, which is what makes
it passive.  It is refreshed only at T1, so a turn never sees it change
mid-flight and the prompt prefix cache survives.

\"Live\" means the validity interval is open (VALID_TO IS NULL) or still running.
Importance comes from the activation summary, which is where write-time
importance lives in this schema.

Returns a string, possibly empty.  It never signals."
  (let ((rows (handler-case
                  (enchiridion.memory.store:query-rows
                   store
                   "SELECT a.subject, a.relation, a.object, a.polarity
                      FROM assertions a
                      JOIN activation v ON v.kind = 'assertion' AND v.id = a.id
                     WHERE a.valid_to IS NULL OR a.valid_to > ?
                     ORDER BY v.imp DESC, a.valid_from DESC
                     LIMIT ?"
                   (list now limit))
                (error () nil))))
    (with-output-to-string (s)
      (let ((used 0))
        (dolist (row rows)
          (when (< used char-budget)
            (let* ((pol (enchiridion.memory.store:field row "polarity"))
                   (line (format nil "- ~A ~A ~A~A~%"
                                 (enchiridion.memory.store:field row "subject")
                                 (enchiridion.memory.store:field row "relation")
                                 (if (and pol (eql pol 0)) "not " "")
                                 (enchiridion.memory.store:field row "object"))))
              (write-string line s)
              (incf used (length line)))))))))

(defun fire-intentions (store state &key (limit 3) (now (get-universal-time)))
  "Return intentions whose trigger holds in STATE and which are still pending.

The prospective store already exists in the core; this makes it FIRE rather
than wait to be retrieved.  Measured support is the strongest of the four
channels: a prospective term raised recall@5 on the hard stratum from 0.000 to
0.955, bounded by the same source's finding that it matters on only 17 to 29
per cent of naturally phrased cases.

A pending intention with an empty trigger_expr fires unconditionally, which is
the right reading of \"no condition recorded\": it is due."
  (let ((rows (handler-case
                  (enchiridion.memory.store:query-rows
                   store
                   "SELECT id, text, trigger_expr FROM intentions
                     WHERE state = 'pending' AND expiry > ?
                     ORDER BY expiry ASC
                     LIMIT ?"
                   (list now limit))
                (error () nil)))
        (have (let ((h (make-hash-table :test #'equal)))
                (dolist (k (ensure-list state) h)
                  (setf (gethash (string-upcase (string k)) h) t)))))
    (loop for row in rows
          for trig = (enchiridion.memory.store:field row "trigger_expr")
          when (or (null trig) (zerop (length trig))
                   (some (lambda (k) (gethash (string-upcase k) have))
                         (split-string trig)))
            collect (list :kind :intention
                          :ref (enchiridion.memory.store:field row "id")
                          :body (enchiridion.memory.store:field row "text")))))

(defun push-pack (store cue &key (state nil) (limit 4) (char-budget 1200)
                                (now (get-universal-time)))
  "Assemble the pushed pack for CUE.  Returns a string, possibly empty.

Four channels in priority order, and the order is the design: cue-indexed
preloading first because it is keyed on demonstrated usefulness, then
precondition surfacing and intention firing because they are structural hints
whose precondition has just become true, then the learned-state block last
because it is the least specific.

No model call.  No retrieval of anything the agent did not ask for by cue."
  (declare (ignore now))
  (let ((lines '())
        (used 0))
    (flet ((add (text)
             (when (and text (plusp (length text)) (< used char-budget))
               (let ((line (format nil "~A~%" text)))
                 (push line lines)
                 (incf used (length line))))))
      ;; Channel 1: cue-indexed preloading.
      (dolist (pair (cue-index-many store cue :limit limit))
        (let ((body (handler-case
                        (let ((row (first (enchiridion.memory.store:query-rows
                                           store
                                           "SELECT body FROM episodes WHERE id = ?"
                                           (list (cdr pair))))))
                          (and row (enchiridion.memory.store:field row "body")))
                      (error () nil))))
          (when body
            (add (format nil "[recalled] ~A"
                         (subseq body 0 (min 240 (length body))))))))
      ;; Channel 2: precondition surfacing.
      (dolist (p (precondition-surfacing store state :limit limit))
        (add (format nil "[applicable] procedure ~A" (getf p :name))))
      ;; Channel 3: intention firing.
      (dolist (i (fire-intentions store state :limit limit))
        (add (format nil "[intention] ~A" (getf i :body))))
      ;; Channel 4: the learned-state block, last.
      (let ((block (learned-state-block store :limit 6 :char-budget 400)))
        (when (plusp (length block)) (add block))))
    (with-output-to-string (s)
      (dolist (line (nreverse lines))
        (write-string line s)))))

(defun assemble-pack (retrieved pushed &key (char-budget +working-set-budget+))
  "Assemble the final pack: retrieved first and whole, then push in what is left.

The hard bound from model-unified.md §5.2 is that push may not evict a
retrieved record the cue ranked above it.  This function enforces that by
ORDER OF PRIORITY, and the first version got it backwards: it truncated the
retrieved side to make room for the push, which is precisely the eviction the
bound forbids.  The test caught it, which is the argument for writing the test
before believing the docstring.

Retrieved material is therefore never truncated by push.  Push is capped at
+PUSH-MAX-FRACTION+ of the budget and then further truncated to whatever
remains, and if nothing remains, the pack is the retrieved material alone."
  (let* ((push-cap (floor (* char-budget +push-max-fraction+)))
         (pushed (if (> (length pushed) push-cap)
                     (subseq pushed 0 push-cap)
                     pushed))
         (separator (if (plusp (length pushed)) 1 0))
         ;; Room left for push once retrieved and the separator are charged.
         (room (- char-budget (length retrieved) separator))
         (pushed (cond ((<= room 0) "")
                       ((> (length pushed) room) (subseq pushed 0 room))
                       (t pushed))))
    (concatenate 'string
                 retrieved
                 (if (plusp (length pushed))
                     (concatenate 'string (string #\Newline) pushed)
                     ""))))

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

(defparameter *retention-first* t
  "When true, consolidation is off unless the utility gate passes.  This is
the single most important default in v2 and it is evidence-driven: the only
measured machine result on consolidating a text store reports that utility
\"first rises, then degrades, and can fall below the no-memory baseline\",
with agents that preserve raw episodes achieving double the accuracy of
forced-consolidation counterparts.")

(defun retention-first-p (&key (override nil))
  "Return T when consolidation must pass the utility gate before running."
  (if (null override) *retention-first* override))

(defun utility-gate (store &key (margin 0.02) (min-n 20))
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

(defun volume-gate (store &key (max-writes 400) (run-id nil))
  "Return T when the last consolidation pass stayed within the write cap.

The cap exists because interference is constantly present: what a system
writes between encoding a record and retrieving it determines whether the
record survives, with no deletion policy in play.  High-volume passive
learning therefore degrades older records by competition alone."
  (let ((row (first (enchiridion.memory.store:query-rows
                     store
                     "SELECT COUNT(*) AS n FROM assertions
                       WHERE run_id = ?"
                     (list (or run-id -1))))))
    (<= (or (enchiridion.memory.store:field row "n") 0) max-writes)))

(defun consolidate-if-gated (store &key (canary-predicate nil)
                                       (margin 0.02) (min-n 20)
                                       (max-writes 400) (now (get-universal-time)))
  "Run consolidation only if all three gates pass.  Return a report plist.

The order is load-bearing.  The canary gate runs first, because a failing
canary must freeze consolidation rather than be discovered afterwards, and
because a suite that has not run must not be treated as passing."
  (let* ((canary (canary-check store :predicate canary-predicate :now now))
         (ok-canary (getf canary :ok-p))
         (ok-utility (and ok-canary (utility-gate store :margin margin :min-n min-n)))
         (ok-volume (and ok-utility (volume-gate store :max-writes max-writes))))
    (cond
      ((not ok-canary)
       (list :ran nil :reason :canary-frozen :canary canary))
      ((not ok-utility)
       (list :ran nil :reason :utility-gate-failed :canary canary))
      ((not ok-volume)
       (list :ran nil :reason :volume-gate-failed :canary canary))
      (t
       (list :ran t :reason :gates-passed :canary canary
             :report (consolidate store :now now))))))

;;;; ------------------------------------------------------------------
;;;; 6. Measurement
;;;; ------------------------------------------------------------------

(defun record-gate-row (store arm metric value &key (n 1) (detail "")
                                          (now (get-universal-time)))
  "Append one measurement row for the utility gate."
  (enchiridion.memory.store:exec
   store
   "INSERT INTO gate_log (arm, metric, value, n, detail, ts) VALUES (?, ?, ?, ?, ?, ?)"
   (list arm metric (coerce value 'double-float) n detail now)))

(defun run-arm (store arm tasks scorer &key (push nil) (consolidating nil))
  "Run TASKS under one ARM and return a result plist.

SCORER is a function of (STORE CUE PUSHED-STRING) returning a number, and it
is the caller's job to make it measure OUTCOME rather than action difference.
That distinction is the correction the extension's first draft got wrong: a
paired audit found 24 of 24 audits changing the action while the selected
branch never changed, so a change signal does not track whether the memory did
the work.

Records one gate_log row per task, so the gate has evidence rather than
memory."
  (declare (ignore consolidating))
  (let ((outcomes '()))
    (dolist (task tasks)
      (let* ((cue (getf task :cue))
             (pushed (if push (push-pack store cue :state (getf task :state)) ""))
             (value (handler-case (funcall scorer store cue pushed)
                      (error () 0.0))))
        (push value outcomes)
        (record-gate-row store arm "outcome" value :n 1
                         :detail (or (getf task :name) ""))))
    (list :arm arm :n (length outcomes)
          :mean (if outcomes (/ (reduce #'+ outcomes) (length outcomes)) 0.0)
          :outcomes (nreverse outcomes))))

(defun compare-arms (store tasks scorer &key (margin 0.02))
  "Run the retention-only and consolidation arms and return the comparison.

This is the utility gate's evidence-producing step.  It is deliberately
separate from UTILITY-GATE, which only reads the log: the step that decides
must not be the step that measures."
  (let ((ret (run-arm store "retention" tasks scorer :push nil :consolidating nil))
        (con (run-arm store "consolidate" tasks scorer :push nil :consolidating t)))
    (list :retention ret :consolidate con
          :delta (- (getf con :mean) (getf ret :mean))
          :passes (>= (- (getf con :mean) (getf ret :mean)) margin)
          :margin margin)))

(defun push-ab (store tasks scorer &key (margin 0.0))
  "Run the push-disabled and push-enabled arms and return the comparison.

Measures OUTCOME, at matched difficulty and matched budget.  The prediction it
tests is P13 of model-unified.md: a push channel's outcome effect is positive.
The failure condition is that the effect is indistinguishable from zero, in
which case the channel is retired."
  (let ((off (run-arm store "push-off" tasks scorer :push nil))
        (on (run-arm store "push-on" tasks scorer :push t)))
    (list :off off :on on
          :delta (- (getf on :mean) (getf off :mean))
          :passes (> (- (getf on :mean) (getf off :mean)) margin)
          :margin margin)))
