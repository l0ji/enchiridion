;;;; episodic.lisp --- The episodic log and derived layer.
;;;;
;;;; Ported from the research executable sketch.
;;;; The specification of record is model-unified.md plus
;;;; docs/design/memory.md; the sketch this came from predates the
;;;; autonomous-memory amendment and is not authoritative.
;;;;
;;;; This file holds the pure mechanisms: records, text helpers, ACT-R
;;;; activation, the association graph, the retrieval score, candidate
;;;; generation, the encoding filter, the write path, conflict detection, the
;;;; calibrator, and the consolidation skeleton. Schema constants live in
;;;; episodic-ddl.cl, which loads before the store.
;;;;
;;;; The package is defined in packages.cl. It is not defined here because a
;;;; second definition would fork the export list from the one the system uses.

(in-package #:enchiridion.memory)

;;;; ---------------------------------------------------------------------
;;;; 1. Parameters.  One plist, so a caller can rebind one key and every
;;;; function that reads it sees the same value.  Every numeric default is
;;;; INVENTED-DESIGN and is a hyperparameter to be fitted: the ACT-R reference
;;;; manual states no numeric default for d or s, and the values in common use
;;;; are recorded only from Tier D teaching material.

(defparameter *memory-parameters*
  (list
   ;; The score weights. B, S and D are 0 and L is 1 because that is what the
   ;; LongMemEval-S benchmark measured (bench/README.md): over 470 questions,
   ;; BM25 alone ranked an answer turn in the top ten for 86.4% of questions
   ;; against 73.0% for the proposal's blend (McNemar p < 0.0001). Once every
   ;; episode carried its real age, B at weight 1.00 fell to 42.1%; at 0.05 it
   ;; changed nothing significant and at 0.20 it cost 7.9 points. S at 0.20
   ;; lowered NDCG@10 by 2.3 points. The proposal's values are kept in the
   ;; comments as the prior they replace. The other terms are constant across
   ;; the benchmark's episodes, so it says nothing about them and they keep
   ;; their invented values.
   :base-weight        0.00   ; proposal 1.00; the ACT-R base level, recency and frequency
   :spread-weight      0.00   ; proposal 0.80; priming over the lexical link graph
   :temporal-weight    0.60   ; the knowledge-update term the documented systems lose
   :importance-weight  0.50   ; write-time signal, down-weighted: least reliable class
   :cue-type-weight    0.50   ; transfer-appropriate processing
   :context-weight     0.40   ; helps when the cue is impoverished
   :inhibition-weight  0.35   ; a penalty; must be able to lose to activation
   :distinct-weight    0.00   ; proposal 0.30; a tie-breaker over the link graph
   :lexical-weight     1.00   ; L, the FTS5 BM25 relevance, rank-normalised
   ;; The base-level equation.
   :decay              0.50   ; d
   :encoding-weight    0.50   ; lambda_E: retrieval practice outranks re-reading
   :base-offset        0.00   ; beta
   :base-form          :power ; the form switch required by proposal D7
   :time-constant      2592000 ; tau for the non-power forms, in seconds
   ;; Spreading activation.
   :max-associative    2.00   ; S
   :max-hops           2      ; the proposal's hop bound
   :spread-decay       0.50   ; gamma, per-hop damping
   :edge-alpha         0.50   ; (1 + obs)^alpha
   :edge-beta          0.50   ; (1 + fan)^-beta
   :edge-half-life     2592000 ; 30 days, in seconds
   ;; Inhibition.
   :supp-increment     0.15   ; per competitive loss
   :supp-half-life     86400  ; one day
   ;; Retrieval.
   :link-fanout        4      ; lexical links written per new episode
   :top-k              12     ; the pack size, before the character budget cuts it
   :pack-line-chars    400    ; the characters one pack record shows
   :pack-excerpt       :cue   ; :CUE the cue's window, or :HEAD the first paragraph
   :pack-neighbours    0      ; turns either side of a hit, same session, to add
   :pack-header        t      ; prefix each record with its date and role; with the
                              ; cheap model answering, +9.4 points of LongMemEval-S
                              ; accuracy, temporal questions 0.394 -> 0.701
   :rerank-pool        30     ; candidates a configured reranker may reorder
   :dense-candidates   200    ; nearest episodes an embedder adds as candidates
   :rrf-k              60     ; reciprocal rank fusion constant, BM25 with dense
   :working-set-chars  8000   ; slot five's character budget
   :prune-below        -4.00  ; base level under which a DERIVED row retires
   :retained-kinds     (list "episode") ; never retired: the log is the substrate
   ;; Admission and calibration.
   :admission-reuse    3      ; successes required
   :admission-tasks    2      ; distinct task classes required
   :calibration-rate   0.25   ; step size for the fallback logistic
   :rely-threshold     0.80   ; P-hat at or above which memory is trusted
   :search-threshold   0.50   ; P-hat below which the agent searches externally
   ;; Consolidation.
   :episode-threshold  200    ; episodes since the last run that trigger one
   :idle-seconds       300    ; idle window that triggers a run
   :batch              400)   ; the per-run bound
  "Every tunable in one place.  See section 7 of the design for the rationale
and the provenance of each default.")

(defun parameter (key &optional (parameters *memory-parameters*))
  "Return the value of KEY in PARAMETERS, or signal when it is absent.
A key present with the value NIL returns NIL; only a missing key signals."
  (let ((value (getf parameters key '%absent)))
    (if (eq value '%absent)
        (error "The memory model has no parameter ~S." key)
        value)))

;;;; ---------------------------------------------------------------------
(defun table-names ()
  "Return the tables the memory model adds, index table first."
  *episodic-tables*)

(defun ensure-episodic-schema (store)
  "Create every memory table on STORE and return the number of statements run.

The statements are the same shape as the store's own: one per call, IF NOT
EXISTS, so a second call changes nothing."
  (let ((count 0))
    (dolist (statement +episodic-schema+ count)
      (enchiridion.memory.store:exec store statement)
      (incf count))))

;;;; ---------------------------------------------------------------------
;;;; 3. Records.  One struct per row, so no caller handles a raw plist whose
;;;; keys depend on how SQLite spelled a column.

(defstruct (episode (:constructor make-episode))
  (id 0 :type integer)
  (session "" :type string)
  (role "user" :type string)
  (body "" :type string)
  (ts 0 :type integer)
  (event-ts nil :type (or null integer))
  (channel :cli :type keyword)
  (provenance "untrusted" :type string)
  (origin "" :type string)
  (authority 1 :type (integer 1 5))
  (cue-type "episodic" :type string)
  (depth 0 :type (integer 0 2))
  (span "" :type string)
  (rarity-raw 0.0 :type real)
  (arousal-raw 0 :type integer)
  (context-key "" :type string)
  (scene-trace "" :type string)
  (horizon 2592000 :type integer)
  (run-id nil :type (or null integer)))

(defstruct (assertion (:constructor make-assertion))
  (id 0 :type integer)
  (subject "" :type string)
  (relation "" :type string)
  (object "" :type string)
  (polarity 1 :type integer)
  (episode-id 0 :type integer)
  (span-start 0 :type integer)
  (span-end 0 :type integer)
  (valid-from nil :type (or null integer))
  (valid-to nil :type (or null integer))
  (tx-from 0 :type integer)
  (tx-to nil :type (or null integer))
  (authority 1 :type (integer 1 5))
  (authority-basis "" :type string)
  (provenance "untrusted" :type string)
  (cue-type "semantic" :type string)
  (schema-id nil :type (or null integer))
  (run-id 0 :type integer))

(defstruct (link (:constructor make-link
                              (&key (src-kind "episode") (src 0)
                                    (dst-kind "episode") (dst 0)
                                    (type "co_occurs") (weight 1.0) (obs 1)
                                    (updated-ts 0))))
  (src-kind "episode" :type string)
  (src 0 :type integer)
  (dst-kind "episode" :type string)
  (dst 0 :type integer)
  (type "co_occurs" :type string)
  (weight 1.0 :type real)
  (obs 1 :type integer)
  (updated-ts 0 :type integer))

(defstruct (activation (:constructor make-activation
                                    (&key (kind "episode") (id 0) (n-enc 0)
                                          (last-enc nil) (n-ret 0) (last-ret nil)
                                          (created-ts 0) (supp 0.0)
                                          (supp-ts nil) (imp 5)
                                          (distinctness 0.0))))
  (kind "episode" :type string)
  (id 0 :type integer)
  (n-enc 0 :type integer)
  (last-enc nil :type (or null integer))
  (n-ret 0 :type integer)
  (last-ret nil :type (or null integer))
  (created-ts 0 :type integer)
  (supp 0.0 :type real)
  (supp-ts nil :type (or null integer))
  (imp 5 :type (integer 1 10))
  (distinctness 0.0 :type real))

(defstruct (conflict (:constructor make-conflict
                                   (&key (kind "cpc") (left-id 0) (right-id 0)
                                         (detected-ts 0) (basis "")
                                         (resolution-state "unresolved")
                                         (resolution nil) (resolved-ts nil)
                                         (resolver nil) (acting-query "")
                                         (run-id 0))))
  (id 0 :type integer)
  (kind "cpc" :type string)
  (left-id 0 :type integer)
  (right-id 0 :type integer)
  (detected-ts 0 :type integer)
  (basis "" :type string)
  (resolution-state "unresolved" :type string)
  (resolution nil :type (or null string))
  (resolved-ts nil :type (or null integer))
  (resolver nil :type (or null string))
  (acting-query "" :type string)
  (run-id 0 :type integer))

(defstruct (intention (:constructor make-intention
                                    (&key (text "") (trigger-kind "time")
                                          (trigger-expr "") (scope "session")
                                          (state "pending") (budget 3)
                                          (cooldown 86400) (expiry 0)
                                          (created-ts 0))))
  (id 0 :type integer)
  (text "" :type string)
  (trigger-kind "time" :type string)
  (trigger-expr "" :type string)
  (scope "session" :type string)
  (state "pending" :type string)
  (budget 3 :type integer)
  (cooldown 86400 :type integer)
  (expiry 0 :type integer)
  (created-ts 0 :type integer))

;;;; ---------------------------------------------------------------------
;;;; 4. Text helpers.  Lexical only: nothing on this path calls a model.

(defparameter +token-scanner+ (cl-ppcre:create-scanner "[a-z0-9_]+")
  "A run of letters, digits, or underscore, lowercased before the match.")

(defparameter +stop-words+
  '("the" "a" "an" "and" "or" "of" "to" "in" "is" "it" "that" "for" "on"
    "with" "as" "at" "by" "be" "this" "are" "was" "from" "not" "but" "if")
  "Words a cue almost always contains.  Left in, they would make every record
match every cue a little, which is the opposite of what the fan term is for.")

(defun tokenise (text)
  "Return the content tokens of TEXT as a list of lowercase strings."
  (when (stringp text)
    (remove-if (lambda (token) (member token +stop-words+ :test #'string=))
               (cl-ppcre:all-matches-as-strings +token-scanner+
                                                (string-downcase text)))))

(defun term-coverage (cue-tokens text)
  "Return the fraction of CUE-TOKENS that occur in TEXT, in 0..1.

This is the Calibrator's cue-coverage feature and the seed weight for
spreading.  Coverage is used rather than SQLite's BM25 because BM25's sign
convention is a property of the index rather than of the record, and because
coverage is computable from the stored body with no second query.  The design
records BM25 as the alternative and requires the two to be compared."
  (if (null cue-tokens)
      0.0
      (let* ((unique (remove-duplicates cue-tokens :test #'string=))
             (body (tokenise text)))
        (if (null body)
            0.0
            (/ (count-if (lambda (token) (member token body :test #'string=))
                         unique)
               (float (length unique)))))))

(defun jaccard (left right &key (test #'string=))
  "Return the Jaccard similarity of the sets LEFT and RIGHT, in 0..1."
  (let ((l (remove-duplicates left :test test))
        (r (remove-duplicates right :test test)))
    (if (and (null l) (null r))
        0.0
        (let ((shared (count-if (lambda (x) (member x r :test test)) l)))
          (/ (float shared)
             (float (- (+ (length l) (length r)) shared)))))))

(defun context-match (item-context current-context)
  "Return C-hat_i, the context match between an item and the current turn.

The proposal's scale is 1 for the same project and session, 0.5 for the same
project only, and 0 otherwise.  A context key is the triple
project, session, channel, so the comparison reads the first two components
and ignores the channel."
  (let* ((item (ensure-list item-context))
         (current (ensure-list current-context))
         (same-project (and (string= (or (first item) "") (or (first current) ""))
                            (or (first item) "")))
         (same-session (and (string= (or (second item) "") (or (second current) ""))
                            (or (second item) ""))))
    (cond ((and same-project same-session) 1.0)
          (same-project 0.5)
          (t 0.0))))

(defparameter +cue-compatibility+
  '(("semantic" . ("identity")) ("identity" . ("semantic"))
    ("episodic" . ("temporal")) ("temporal" . ("episodic"))
    ("procedural" . ("episodic" "temporal")))
  "Cue types that are not equal but are in the same compatibility class.
The classes are INVENTED-DESIGN: the transfer-appropriate-processing finding
licenses matching the retrieval cue to the encoding operation, and does not
supply a taxonomy of operations.")

(defun cue-type-match (stored implied)
  "Return P-hat_i: 1 when the cue types agree, 0.5 in one class, else 0."
  (let ((left (string-downcase (string stored)))
        (right (string-downcase (string implied))))
    (cond ((string= left right) 1.0)
          ((member right (cdr (assoc left +cue-compatibility+ :test #'string=))
                   :test #'string=)
           0.5)
          (t 0.0))))

(defun temporal-match (valid-from valid-to query-time)
  "Return T-hat_i: +1 inside the interval, 0 when no time is named, -1 outside.

The half-open convention is used, so VALID-TO is the first instant the
assertion stops holding.  A NULL bound is an open end.  The term is signed and
is therefore NOT rank-normalised, which is a correction to the proposal: a
rank normalisation onto [0, 1] would destroy the sign and remove the penalty
for an assertion whose interval the query falls outside."
  (if (null query-time)
      0.0
      (let ((from (or valid-from 0))
            (to (or valid-to most-positive-fixnum)))
        (if (and (<= from query-time) (< query-time to)) 1.0 -1.0))))

;;;; ---------------------------------------------------------------------
;;;; 5. ACT-R base level, with the two event populations the design requires
;;;; and the functional-form switch the design requires.
;;;;
;;;; ACT-R counts a presentation as a presentation.  The human evidence does
;;;; not: retrieval practice produced about 80% recall at one week against
;;;; about 36% for repeated study.  Collapsing the two populations into one
;;;; count would discard the largest effect in the evidence base, so encoding
;;;; events carry weight LAMBDA-E and retrieval-practice events carry 1.

(defparameter +base-level-forms+ '(:power :exponential :logarithmic :exponential-power)
  "The four forms the switch admits.  The default is :POWER.  The proposal
requires the switch because the functional form is contested: a survey of 916
data sets found the power function was not the best-fitting form most often.")

(defun base-level-forms ()
  "Return the functional forms BASE-LEVEL accepts."
  +base-level-forms+)

(defun base-level-exact (encoding-refs retrieval-refs now
                         &key (d 0.5) (lambda-e 0.5) (beta 0.0))
  "Return B_i = ln( lambda-E * sum_E t_j^-d + sum_R t_k^-d ) + beta_i.

ENCODING-REFS and RETRIEVAL-REFS are lists of universal times, one per event.
This is the exact two-population form.  A reference in the future is clamped
to one second of age so the power term stays finite."
  (let ((encoding (reduce (lambda (sum reference)
                            (+ sum (expt (max 1 (- now reference)) (- d))))
                          encoding-refs :initial-value 0.0))
        (retrieval (reduce (lambda (sum reference)
                             (+ sum (expt (max 1 (- now reference)) (- d))))
                           retrieval-refs :initial-value 0.0)))
    (let ((total (+ (* lambda-e encoding) retrieval)))
      (if (plusp total) (+ beta (log total)) beta))))

(defun base-level-approx (n-enc n-ret lifetime now
                          &key (d 0.5) (lambda-e 0.5) (beta 0.0)
                            (form :power) (time-constant 2592000))
  "Return B_i from the reference summary, under the selected functional form.

N-ENC and N-RET are the two counts and LIFETIME is the age of the record at
NOW.  The effective count is n = lambda-E * n-enc + n-ret, which is what makes
the two-population form collapse to the manual's lifetime approximation
B_i = ln( n / (1 - d) ) - d * ln(L) + beta_i when lambda-E is 1.

The four forms are all anchored so that a record with no history returns BETA,
and so that they agree in sign and rough magnitude.  Their absolute values are
NOT comparable across forms, which is why the form is a switch on the whole
score and not a per-record field: a candidate set scored under two forms at
once would not be ordered correctly.  The exponential and exponential-power
forms use the record's own horizon as their time constant, because an
exponential decay implies a characteristic scale and the record's horizon is
the only scale the design has."
  (declare (ignore now))
  (let ((n (+ (* (float lambda-e) (float n-enc)) (float n-ret)))
        (life (float (max 1 lifetime)))
        (tau (float (max 1 time-constant))))
    (if (zerop n)
        beta
        (+ beta
           (ecase form
             (:power (- (log (/ n (- 1.0 d))) (* d (log life))))
             (:exponential (- (log n) (/ life tau)))
             (:logarithmic (- (log n) (* d (log (+ 1.0 (/ life tau))))))
             (:exponential-power (- (log (/ n (- 1.0 d)))
                                    (* d (log life))
                                    (/ life tau))))))))

(defun base-level (activation now &key (d 0.5) (beta 0.0) (lambda-e 0.5)
                                      (form :power) (time-constant 2592000))
  "Return B_i for ACTIVATION at NOW, from the summary the table stores.

A record with no reference at all returns BETA, which is the offset and not a
positive activation."
  (let* ((n-enc (activation-n-enc activation))
         (n-ret (activation-n-ret activation))
         (created (activation-created-ts activation))
         (lifetime (max 1 (- now (if (plusp created) created now)))))
    (base-level-approx n-enc n-ret lifetime now
                       :d d :lambda-e lambda-e :beta beta
                       :form form :time-constant time-constant)))

(defun decay-update (activation now &key (parameters *memory-parameters*))
  "Recompute ACTIVATION's base level at NOW and return two values.

The first value is B_i under the configured functional form.  The second is T
when the record is a *derived* record that has fallen below the prune floor.

Nothing is written: B_i is a function of the reference summary, so decay needs
no update pass to be correct and a stored activation column cannot drift from
the history it claims to summarise.  The episodic log is never a retirement
candidate, because it is the substrate every derived row is rebuilt from."
  (let* ((form (parameter :base-form parameters))
         (base (base-level activation now
                                     :d (parameter :decay parameters)
                                     :beta (parameter :base-offset parameters)
                                     :lambda-e (parameter :encoding-weight parameters)
                                     :form form
                                     :time-constant (parameter :time-constant
                                                               parameters)))
         (retained (parameter :retained-kinds parameters)))
    (values base
            (and (not (member (activation-kind activation) retained :test #'string=))
                 (< base (parameter :prune-below parameters))))))

(defun decay-sweep (store now &key (parameters *memory-parameters*))
  "Recompute every activation summary in STORE and return a report plist.

The report holds :SCANNED, :LIVE, :EXEMPT -- the records the retained kinds
protected -- and :DORMANT, a list of (KIND ID BASE) for derived records below
the floor.

The floor is meaningful only for the derived layer.  With the default d of 0.5,
a single-reference derived row reaches -4.0 at about 3.3 hours of age and a
three-reference row at about 30 hours; the log is exempt because deleting the
substrate is not forgetting, it is data loss.  Retiring a record is a separate
call, because a sweep that writes while it reads is what makes a rebuild
unsafe."
  (let ((rows (enchiridion.memory.store:query-rows
               store
               "SELECT kind, id, n_enc, last_enc, n_ret, last_ret, created_ts,
                       supp, supp_ts, imp, distinctness
                  FROM activation"))
        (dormant '()) (live 0) (exempt 0))
    (dolist (row rows)
      (let* ((record (activation-from-row row))
             (base (decay-update record now :parameters parameters))
             (candidate (nth-value 1 (decay-update record now
                                                  :parameters parameters))))
        (cond ((member (activation-kind record)
                       (parameter :retained-kinds parameters) :test #'string=)
               (incf exempt))
              (candidate
               (push (list (activation-kind record) (activation-id record) base)
                     dormant))
              (t (incf live)))))
    (list :scanned (length rows) :live live :exempt exempt
          :dormant (nreverse dormant))))

(defun activation-from-row (row)
  "Return ROW, one activation row as a plist, as an ACTIVATION."
  (make-activation :kind (enchiridion.memory.store:field row "kind")
                   :id (enchiridion.memory.store:field row "id")
                   :n-enc (enchiridion.memory.store:field row "n_enc")
                   :last-enc (enchiridion.memory.store:field row "last_enc")
                   :n-ret (enchiridion.memory.store:field row "n_ret")
                   :last-ret (enchiridion.memory.store:field row "last_ret")
                   :created-ts (enchiridion.memory.store:field row "created_ts")
                   :supp (enchiridion.memory.store:field row "supp")
                   :supp-ts (enchiridion.memory.store:field row "supp_ts")
                   :imp (enchiridion.memory.store:field row "imp")
                   :distinctness (enchiridion.memory.store:field row
                                                                 "distinctness")))

;;;; ---------------------------------------------------------------------
;;;; 6. Inhibition: a bounded, decaying accessibility penalty.

(defun inhibition-after-loss (activation now &key (parameters *memory-parameters*))
  "Raise ACTIVATION's suppression by one increment and return the new value.

The increment is bounded at 1.0 and is raised only when the record competed
with a retrieved record and lost.  Suppression is never a deletion and it
always decays, which is the design's answer to the contested mechanism behind
retrieval-induced forgetting: the phenomenon is implemented as a change in
accessibility, never as loss of content."
  (let* ((previous (if (and (activation-supp-ts activation)
                            (plusp (activation-supp activation)))
                       (decay-inhibition activation now :parameters parameters)
                       (activation-supp activation)))
         (raised (min 1.0 (+ previous (parameter :supp-increment parameters)))))
    (setf (activation-supp activation) raised
          (activation-supp-ts activation) now)
    raised))

(defun decay-inhibition (activation now &key (parameters *memory-parameters*))
  "Return ACTIVATION's suppression decayed to NOW, with a one-day half-life.

The decay is applied on read rather than written on a timer, for the same
reason the base level is: a stored value that decays only when a job runs is
wrong between jobs."
  (let ((supp (activation-supp activation))
        (stamp (activation-supp-ts activation)))
    (if (or (null stamp) (zerop supp))
        (float supp)
        (let ((age (max 0 (- now stamp)))
              (half (float (parameter :supp-half-life parameters))))
          (* supp (expt 2.0 (- (/ age half))))))))

;;;; ---------------------------------------------------------------------
;;;; 7. The association graph and spreading activation.
;;;;
;;;; The graph is a hash table keyed by (KIND . ID) whose value is the list of
;;;; LINK records leaving that node.  Building it from SQL is one query; the
;;;; search below is pure and testable without a database.

(defun node (kind id)
  "Return the graph key for the record KIND with row id ID."
  (cons kind id))

(defun fan (graph kind id)
  "Return fan(src): the number of distinct neighbours of (KIND . ID), plus one.

ACT-R defines fan_ji as (slots_j + 1) / slots_ji, the number of chunks in
which j is the value of a slot.  The operational analogue is out-degree plus
one: a cue that links to many records contributes less to each of them.  The
design states that this is an analogue and not a derivation; the property it
preserves -- self-limiting cue specificity -- is the one that matters."
  (1+ (length (gethash (node kind id) graph))))

(defun associative-strength (graph src-kind src &key (max-associative 2.0))
  "Return S_ji = max(0, S - ln fan_ji).

The manual records that \"The S_ji value can become negative as the fan_ji
value grows, but that is generally an undesirable situation\", and that the
implementation prints a warning and uses 0.0 instead.  This clamps, which is
what the manual says the implementation does."
  (max 0.0 (- (float max-associative) (log (float (fan graph src-kind src))))))

(defun edge-weight (obs fan-count &key (alpha 0.5) (beta 0.5))
  "Return w(e) = (1 + obs)^alpha / (1 + fan)^beta.

Repeated co-occurrence strengthens a link and a hub node's links are
discounted, which is the same self-limiting property the fan term has."
  (/ (expt (float (1+ obs)) alpha)
     (expt (float (1+ fan-count)) beta)))

(defun decayed-edge-weight (weight updated-ts now &key (half-life 2592000))
  "Return w(t + dt) = w * 2^( -dt / h ), the 30-day half-life edge decay."
  (if (or (zerop updated-ts) (<= now updated-ts))
      (float weight)
      (* weight (expt 2.0 (- (/ (float (- now updated-ts))
                                (float (max 1 half-life))))))))

(defun spread-activation (graph sources &key (max-hops 2) (decay 0.5)
                                          (max-associative 2.0) (now 0)
                                          (half-life 2592000))
  "Return a hash table of (KIND . ID) to S_i, the spreading activation value.

SOURCES is a list of plists with :KIND, :ID and an optional :WEIGHT.  The
proposal weights each cue term by W_kj = 1/|sources|, which the caller applies
before the call; this function treats the weights as given.  Activation
spreads at most MAX-HOPS hops, each hop multiplying by DECAY, by the link
weight (decayed by the edge half-life), and by the associative strength of the
source node.  A node's value is the sum over every path that reached it, which
is S_i = sum_k sum_j W_kj * S_ji with W_kj folded into the per-hop weight.

A CONTRADICTS edge does not propagate activation: it sets the conflict flag on
both of its endpoints instead.  Propagating along it would make a record easier
to retrieve *because* something contradicts it, which is the opposite of what
the conflict ledger is for."
  ;; The frontier is a table from node to the amount that reached it this
  ;; hop. Every gain is linear in the amount, so expanding a node once with
  ;; the summed amount gives the same totals as expanding each path to it
  ;; separately, and the cost is one expansion per node per hop rather than
  ;; one per path, which grows as fan^hops.
  (let ((total (make-hash-table :test #'equal))
        (flagged (make-hash-table :test #'equal))
        (frontier (make-hash-table :test #'equal)))
    (dolist (source sources)
      (let ((key (node (getf source :kind) (getf source :id)))
            (weight (float (or (getf source :weight) 1.0))))
        (incf (gethash key total 0.0) weight)
        (incf (gethash key frontier 0.0) weight)))
    (loop for hop from 1 to max-hops
          for next = (make-hash-table :test #'equal)
          for damping = (expt (float decay) hop)
          do (maphash
              (lambda (key amount)
                (let ((edges (gethash key graph)))
                  (when edges
                    ;; Every edge leaving KEY shares its source, so the
                    ;; associative strength is computed once per node.
                    (let ((strength (associative-strength
                                     graph (car key) (cdr key)
                                     :max-associative max-associative)))
                      (dolist (edge edges)
                        (let ((target (node (link-dst-kind edge) (link-dst edge))))
                          (if (string-equal (link-type edge) "contradicts")
                              (progn (setf (gethash key flagged) t)
                                     (setf (gethash target flagged) t))
                              (let ((gain (* amount
                                             (decayed-edge-weight
                                              (link-weight edge)
                                              (link-updated-ts edge)
                                              now :half-life half-life)
                                             strength damping)))
                                (when (plusp gain)
                                  (incf (gethash target total 0.0) gain)
                                  (incf (gethash target next 0.0) gain))))))))))
              frontier)
             (setf frontier next))
    (setf (gethash :conflict-flag total) flagged)
    total))

(defun conflict-flagged-p (spread key)
  "Return T when KEY was touched by a CONTRADICTS edge during the spread."
  (let ((flagged (gethash :conflict-flag spread)))
    (and (hash-table-p flagged) (not (null (gethash key flagged))))))

;;;; ---------------------------------------------------------------------
;;;; 8. The score.
;;;;
;;;; R_i = w_B*B-hat_i + w_S*S-hat_i + w_T*T-hat_i + w_I*I-hat_i
;;;;     + w_P*P-hat_i + w_C*C-hat_i - w_X*X-hat_i + w_D*D-hat_i
;;;;
;;;; Only the two unbounded terms are rank-normalised.  The proposal says
;;;; every term is normalised to [0, 1] by rank, which cannot be right for the
;;;; signed temporal term: a rank normalisation would map the worst candidate
;;;; onto 0 and the best onto 1 regardless of sign, so an assertion whose
;;;; interval the query falls outside would stop being penalised and would
;;;; stop being distinguishable from one with no temporal information at all.
;;;; The bounded terms already have a defined scale, so they are used as
;;;; defined and only B-hat and S-hat are rank-normalised.  This is a
;;;; correction to the proposal and it is recorded as a defect.

(defstruct (terms (:constructor make-terms
                                (&key (base 0.0) (spread 0.0) (temporal 0.0)
                                      (importance 0.0) (cue-type 0.0)
                                      (context 0.0) (inhibition 0.0)
                                      (distinct 0.0) (lexical 0.0))))
  (base 0.0 :type real)        ; B_i, ACT-R base level: recency and frequency
  (spread 0.0 :type real)      ; S_i, spreading activation over the link graph
  (temporal 0.0 :type real)    ; T-hat, +1 / 0 / -1, signed, not normalised
  (importance 0.0 :type real)  ; I-hat, imp / 10
  (cue-type 0.0 :type real)    ; P-hat, 1 / 0.5 / 0
  (context 0.0 :type real)     ; C-hat, 1 / 0.5 / 0
  (inhibition 0.0 :type real)  ; X-hat, supp in 0..1
  (distinct 0.0 :type real)    ; D-hat, 1 - fan_i / max(fan)
  (lexical 0.0 :type real))    ; L-hat, BM25 relevance to the cue

(defun rank-normalise (values)
  "Return VALUES mapped onto [0, 1] by rank, preserving ties.

The proposal chooses rank normalisation over min-max because min-max is
sensitive to a single outlier.  Tied values receive the mean of the ranks they
span, so two identical candidates keep identical scores and a deterministic
tie-break stays possible, which the prompt prefix cache requires."
  (let* ((n (length values))
         (indexed (sort (loop for value in values
                              for position from 0
                              collect (cons value position))
                        #'< :key #'car))
         (out (make-array n :initial-element 0.0)))
    (cond
      ((zerop n) '())
      ((= n 1) (list 0.5))
      (t
       (let ((i 0))
         (loop while (< i n)
               do (let* ((start i)
                         (value (car (nth i indexed))))
                    (loop while (and (< i n)
                                     (= (car (nth i indexed)) value))
                          do (incf i))
                    (let ((rank (/ (+ start (1- i)) 2.0)))
                      (loop for k from start below i
                            do (setf (aref out (cdr (nth k indexed)))
                                     (/ rank (float (1- n)))))))))
       (coerce out 'list)))))

(defun normalise-terms (term-list)
  "Return TERM-LIST with the three unbounded terms rank-normalised in place."
  (let ((bases (rank-normalise (mapcar #'terms-base term-list)))
        (spreads (rank-normalise (mapcar #'terms-spread term-list)))
        (lexicals (rank-normalise (mapcar #'terms-lexical term-list))))
    (loop for term in term-list
          for base in bases
          for spread in spreads
          for lexical in lexicals
          do (setf (terms-base term) base
                   (terms-spread term) spread
                   (terms-lexical term) lexical))
    term-list))

(defun retrieval-score (terms &optional (parameters *memory-parameters*))
  "Return R_i, the weighted retrieval score of TERMS.

Units are arbitrary because every term is on a comparable scale and the
weights carry the ordering.  The weights are hyperparameters and every default
is INVENTED-DESIGN; the design states the evidence order they encode and the
fitting procedure that replaces them."
  (+ (* (parameter :base-weight parameters) (terms-base terms))
     (* (parameter :spread-weight parameters) (terms-spread terms))
     (* (parameter :temporal-weight parameters) (terms-temporal terms))
     (* (parameter :importance-weight parameters) (terms-importance terms))
     (* (parameter :cue-type-weight parameters) (terms-cue-type terms))
     (* (parameter :context-weight parameters) (terms-context terms))
     (* (- (parameter :inhibition-weight parameters)) (terms-inhibition terms))
     (* (parameter :distinct-weight parameters) (terms-distinct terms))
     (* (parameter :lexical-weight parameters) (terms-lexical terms))))

(defun retrieval-probability (score &key (threshold 0.0) (noise 0.4))
  "Return 1 / (1 + exp( -( score - tau ) / s )), the ACT-R logistic.

The design does NOT use this as the Calibrator's readout: tau and s have no
verified default, and the quantity ACT-R computes is the probability that a
chunk exceeds a threshold in a model of human retrieval, not the probability
that a machine retrieval will be useful.  It is kept because the Calibrator
fits its own logistic to the same margin, and because a caller that wants a
bounded transform of the score has one."
  (/ 1.0 (+ 1.0 (exp (- (/ (- (float score) (float threshold))
                           (float (max 0.0001 noise))))))))

(defun retrieval-latency (score &key (latency-factor 1.0))
  "Return F * exp( -A ), the ACT-R latency, for reporting only.

The design drops latency as a ranking term: there is no mapping from an
activation value to a machine latency, and claiming the equation in the score
would be decorative."
  (* (float latency-factor) (exp (- (float score)))))

;;;; ---------------------------------------------------------------------
;;;; 9. Retrieval.

(defun candidate-fan (graph key candidate-keys)
  "Return fan_i for KEY: its neighbours that are themselves candidates.

The proposal defines D-hat_i = 1 - fan_i / max(fan), where fan_i counts the
neighbours sharing the query's cue terms.  The candidate set *is* the set of
records the cue reached, so its intersection with the neighbour set is the
quantity the definition asks for, and it needs no second index."
  (count-if (lambda (edge)
              (member (node (link-dst-kind edge) (link-dst edge))
                      candidate-keys :test #'equal))
            (gethash key graph)))

(defun distinctiveness (graph key candidate-keys max-fan)
  "Return D-hat_i = 1 - fan_i / max(fan), or 0.0 when no candidate has a fan.

The relative form is the only defensible one on the evidence the design
retrieved, so distinctiveness is a tie-breaker and never a driver."
  (if (or (null max-fan) (zerop max-fan))
      0.0
      (- 1.0 (/ (float (candidate-fan graph key candidate-keys)) (float max-fan)))))

(defun item-terms (item context spread graph candidate-keys max-fan
                        now parameters)
  "Return the TERMS of one candidate ITEM.

ITEM is a plist with :KIND, :ID, :BODY, :SESSION, :PROJECT, :CUE-TYPE,
:VALID-FROM, :VALID-TO, :ACTIVATION and :CONFLICT-FLAGGED.  Every term of the
score is computed here from stored fields; none is inferred."
  (let* ((key (node (getf item :kind) (getf item :id)))
         (record (getf item :activation))
         (query-time (getf item :query-time)))
    (make-terms
     :base (base-level record now
                       :d (parameter :decay parameters)
                       :beta (parameter :base-offset parameters)
                       :lambda-e (parameter :encoding-weight parameters)
                       :form (parameter :base-form parameters)
                       :time-constant (parameter :time-constant parameters))
     :spread (gethash key spread 0.0)
     :temporal (temporal-match (getf item :valid-from) (getf item :valid-to)
                               query-time)
     :importance (/ (float (or (activation-imp record) 5)) 10.0)
     ;; An implied cue type of NIL is an unclassified cue: it favours no
     ;; kind of record, so every candidate gets the same term.
     :cue-type (let ((implied (getf item :cue-type-implied)))
                 (if implied
                     (cue-type-match (or (getf item :cue-type) "episodic") implied)
                     1.0))
     :context (context-match (getf item :context) context)
     :inhibition (decay-inhibition record now :parameters parameters)
     :distinct (distinctiveness graph key candidate-keys max-fan)
     :lexical (float (or (getf item :lexical) 0.0)))))

(defun retrieve (candidates cue context &key (parameters *memory-parameters*)
                                         (graph (make-hash-table :test #'equal))
                                         (now (get-universal-time))
                                         (query-time nil)
                                         (cue-type "episodic")
                                         (top-k nil))
  "Return the TOP-K candidates ranked by R_i, best first.

CANDIDATES is a list of plists as ITEM-TERMS documents, each already carrying
its activation summary.  The cue tokens seed the spread at weight
coverage/|sources|, which is the proposal's W_kj = 1/|sources| applied to the
terms the cue actually matched.  Each result is a plist of :ITEM, :TERMS,
:SCORE, :PROBABILITY, :LATENCY and :CONFLICT.

CUE-TYPE is the kind of retrieval the cue implies.  NIL says the cue was not
classified, and the cue-type term then gives every candidate the same value
instead of ranking one kind of record over another.

This function reads nothing and writes nothing.  A candidate that participates
in an unresolved conflict is NOT penalised: the pack is required to include the
conflicting partner or to carry the conflict flag, because a system that can
silently drop the losing side of a conflict is the system the TANGLE benchmark
measures as failing."
  (let* ((cue-tokens (tokenise cue))
         (candidates (mapcar (lambda (item)
                               (list* :query-time query-time
                                      :cue-type-implied cue-type item))
                             candidates))
         (scored-keys (mapcar (lambda (item) (node (getf item :kind)
                                                   (getf item :id)))
                              candidates))
         (matched (loop for item in candidates
                        for coverage = (term-coverage cue-tokens (getf item :body))
                        when (plusp coverage) collect (cons item coverage)))
         (source-count (max 1 (length matched)))
         (seeds (loop for (item . coverage) in matched
                      collect (list :kind (getf item :kind)
                                    :id (getf item :id)
                                    :weight (/ coverage (float source-count)))))
         (spread (spread-activation
                  graph seeds
                  :max-hops (parameter :max-hops parameters)
                  :decay (parameter :spread-decay parameters)
                  :max-associative (parameter :max-associative parameters)
                  :now now
                  :half-life (parameter :edge-half-life parameters)))
         (fans (mapcar (lambda (key) (candidate-fan graph key scored-keys))
                       scored-keys))
         (max-fan (reduce #'max fans :initial-value 0))
         (term-list (mapcar (lambda (item)
                              (item-terms item context spread graph
                                          scored-keys max-fan now parameters))
                            candidates)))
    (normalise-terms term-list)
    (let ((rows (loop for item in candidates
                      for terms in term-list
                      for key in scored-keys
                      for score = (retrieval-score terms parameters)
                      collect (list :item item :terms terms :score score
                                    :probability (retrieval-probability score)
                                    :latency (retrieval-latency score)
                                    :conflict (conflict-flagged-p spread key)))))
      (setf rows (sort rows #'> :key (lambda (row) (getf row :score))))
      (if top-k (subseq rows 0 (min top-k (length rows))) rows))))

;;;; ---------------------------------------------------------------------
;;;; 10. Candidate generation.  The only part that touches SQLite.

(defun live-generation-id (store)
  "Return the live generation id, or 0 when none has been promoted."
  (when store
    (let ((row (first (enchiridion.memory.store:query-rows
                       store
                       "SELECT live_generation_id FROM memory_state WHERE id = 1"))))
      (or (and row (enchiridion.memory.store:field row "live_generation_id")) 0))))

(defun content-hash (text)
  "Return a stable 16-character hex digest of TEXT, for naming a task or a
projection by its content across processes. SXHASH is not stable across
images, so it cannot pair rows written by two runs."
  (subseq (ironclad:byte-array-to-hex-string
           (ironclad:digest-sequence
            :sha256 (sb-ext:string-to-octets (princ-to-string text)
                                             :external-format :utf-8)))
          0 16))

(defun cue-match (cue)
  "Return the FTS5 MATCH expression for CUE: any of its distinct terms.
A cue with no searchable term signals SCHEMA-ERROR, which is FTS-QUERY's
behaviour."
  (let ((terms (remove-duplicates (tokenise cue) :test #'string=)))
    (if terms
        (format nil "~{~A~^ OR ~}"
                (mapcar (function enchiridion.memory.store:fts-query) terms))
        (enchiridion.memory.store:fts-query cue))))

(defun candidates-for (store cue &key (limit 200) (now (get-universal-time)))
  "Return episode candidates for CUE from the FTS5 index.

The lexical pass is a *candidate generator*, not a ranker: its output is
re-scored by RETRIEVE.  The activation summary is joined in the same query, so
scoring a candidate costs no second round trip.  A cue with no searchable term
signals SCHEMA-ERROR, which is the existing FTS-QUERY behaviour and is not
changed."
  (let ((match (cue-match cue)))
    (loop for row in (enchiridion.memory.store:query-rows
                      store
                      "SELECT e.id, e.body, e.session, e.channel, e.cue_type,
                              e.role, e.ts,
                              bm25(episodes_fts) AS lexical,
                              e.context_key, e.horizon, e.scene_trace,
                              a.n_enc, a.last_enc, a.n_ret, a.last_ret,
                              a.created_ts, a.supp, a.supp_ts, a.imp,
                              a.distinctness
                         FROM episodes_fts
                         JOIN episodes e ON e.id = episodes_fts.rowid
                         LEFT JOIN activation a
                                ON a.kind = 'episode' AND a.id = e.id
                        WHERE episodes_fts MATCH ?
                        ORDER BY rank
                        LIMIT ?"
                      (list match limit))
          collect (episode-candidate row now))))

(defun episode-candidate (row now)
  "Return ROW as the candidate plist RETRIEVE consumes."
  (let ((created (enchiridion.memory.store:field row "created_ts"))
        (id (enchiridion.memory.store:field row "id")))
    (list :kind "episode"
          :id id
          :body (enchiridion.memory.store:field row "body")
          :session (enchiridion.memory.store:field row "session")
          :role (enchiridion.memory.store:field row "role")
          :ts (enchiridion.memory.store:field row "ts")
          :project (first (split-context-key
                           (enchiridion.memory.store:field row "context_key")))
          :context (split-context-key
                    (enchiridion.memory.store:field row "context_key"))
          :cue-type (enchiridion.memory.store:field row "cue_type")
          ;; FTS5's bm25() is smaller for a better match, so it is negated:
          ;; every other term is larger-is-better.
          :lexical (let ((bm25 (enchiridion.memory.store:field row "lexical")))
                     (if bm25 (- (float bm25)) 0.0))
          :valid-from nil
          :valid-to nil
          :activation
          (make-activation
           :kind "episode" :id id
           :n-enc (or (enchiridion.memory.store:field row "n_enc") 1)
           :last-enc (enchiridion.memory.store:field row "last_enc")
           :n-ret (or (enchiridion.memory.store:field row "n_ret") 0)
           :last-ret (enchiridion.memory.store:field row "last_ret")
           :created-ts (or created now)
           :supp (or (enchiridion.memory.store:field row "supp") 0.0)
           :supp-ts (enchiridion.memory.store:field row "supp_ts")
           :imp (or (enchiridion.memory.store:field row "imp") 5)
           :distinctness (or (enchiridion.memory.store:field row "distinctness")
                             0.0)))))

(defun assertion-text (subject relation object polarity)
  "Return one assertion as the line a pack shows: the claim, not its episode."
  (format nil "~A ~:[not ~;~]~A ~A" subject (not (eql polarity 0)) relation object))

(defparameter +assertion-candidate-columns+
  "a.id, a.subject, a.relation, a.object, a.polarity, a.valid_from, a.valid_to,
   a.cue_type, a.episode_id, a.tx_to, e.session, e.context_key, e.ts,
   act.n_enc, act.last_enc, act.n_ret, act.last_ret, act.created_ts, act.supp,
   act.supp_ts, act.imp, act.distinctness"
  "The columns both routes to an assertion select.")

(defun assertion-candidate (row now)
  "Return ROW, one assertion and its supporting episode, as a candidate plist."
  (let ((created (enchiridion.memory.store:field row "created_ts"))
        (id (enchiridion.memory.store:field row "id")))
    (list :kind "assertion"
          :id id
          :body (assertion-text
                 (enchiridion.memory.store:field row "subject")
                 (enchiridion.memory.store:field row "relation")
                 (enchiridion.memory.store:field row "object")
                 (enchiridion.memory.store:field row "polarity"))
          :episode-id (enchiridion.memory.store:field row "episode_id")
          :ts (enchiridion.memory.store:field row "ts")
          :lexical (let ((bm25 (enchiridion.memory.store:field row "lexical")))
                     (if bm25 (- (float bm25)) 0.0))
          :route-ranks '()
          :context (split-context-key
                    (enchiridion.memory.store:field row "context_key"))
          :cue-type (enchiridion.memory.store:field row "cue_type")
          :valid-from (enchiridion.memory.store:field row "valid_from")
          :valid-to (enchiridion.memory.store:field row "valid_to")
          :assertion (list :subject (enchiridion.memory.store:field row "subject")
                           :relation (enchiridion.memory.store:field row "relation")
                           :object (enchiridion.memory.store:field row "object"))
          :activation
          (make-activation
           :kind "assertion" :id id
           :n-enc (or (enchiridion.memory.store:field row "n_enc") 1)
           :last-enc (enchiridion.memory.store:field row "last_enc")
           :n-ret (or (enchiridion.memory.store:field row "n_ret") 0)
           :last-ret (enchiridion.memory.store:field row "last_ret")
           :created-ts (or created now)
           :supp (or (enchiridion.memory.store:field row "supp") 0.0)
           :supp-ts (enchiridion.memory.store:field row "supp_ts")
           :imp (or (enchiridion.memory.store:field row "imp") 5)
           :distinctness (or (enchiridion.memory.store:field row "distinctness")
                             0.0)))))

(defun assertion-candidates-for (store cue &key generation (limit 200)
                                              (now (get-universal-time)))
  "Return GENERATION's assertion candidates for CUE, or NIL when GENERATION is
NIL or 0.

Two routes reach an assertion.  The claim route matches the cue against the
assertion's own words, so a claim is found by a term its source episode never
used: that is the recall the semantic layer can add.  The support route
matches the episode the claim came from, so a claim is never harder to find
than its evidence.  A candidate found by both appears once, and :ROUTE-RANKS
holds its rank in each route, which RETRIEVE-ROWS-FOR-TURN fuses with the
episode ranking: BM25 from two indexes is not on one scale, ranks are.  Only
the named generation is read, so a candidate is invisible to the live layer."
  (when (and generation (plusp generation))
    (let ((match (cue-match cue))
          (by-id (make-hash-table))
          (order '()))
      (flet ((route (statement)
               (loop for row in (enchiridion.memory.store:query-rows
                                 store statement (list match generation limit))
                     for rank from 0
                     for id = (enchiridion.memory.store:field row "id")
                     do (unless (gethash id by-id)
                          (push id order)
                          (setf (gethash id by-id) (assertion-candidate row now)))
                        (push rank (getf (gethash id by-id) :route-ranks)))))
        (route (format nil "SELECT ~A, bm25(assertions_fts) AS lexical
                              FROM assertions_fts
                              JOIN assertions a ON a.id = assertions_fts.rowid
                              JOIN episodes e ON e.id = a.episode_id
                              LEFT JOIN activation act
                                     ON act.kind = 'assertion' AND act.id = a.id
                             WHERE assertions_fts MATCH ? AND a.tx_to IS NULL
                               AND a.generation_id = ?
                             ORDER BY rank LIMIT ?"
                       +assertion-candidate-columns+))
        (route (format nil "SELECT ~A, bm25(episodes_fts) AS lexical
                              FROM episodes_fts
                              JOIN episodes e ON e.id = episodes_fts.rowid
                              JOIN assertions a ON a.episode_id = e.id
                              LEFT JOIN activation act
                                     ON act.kind = 'assertion' AND act.id = a.id
                             WHERE episodes_fts MATCH ? AND a.tx_to IS NULL
                               AND a.generation_id = ?
                             ORDER BY rank LIMIT ?"
                       +assertion-candidate-columns+)))
      (mapcar (lambda (id) (gethash id by-id)) (nreverse order)))))

(defun graph-for (store &key (limit *memory-graph-limit*) (kinds '("episode" "assertion")))
  "Return the link graph RETRIEVE walks: a hash table of node to out-links."
  (let ((graph (make-hash-table :test #'equal)))
    (dolist (row (enchiridion.memory.store:query-rows
                  store
                  "SELECT src_kind, src, dst_kind, dst, type, weight, obs,
                          updated_ts
                     FROM links LIMIT ?"
                  (list limit)))
      (let ((edge (make-link
                   :src-kind (enchiridion.memory.store:field row "src_kind")
                   :src (enchiridion.memory.store:field row "src")
                   :dst-kind (enchiridion.memory.store:field row "dst_kind")
                   :dst (enchiridion.memory.store:field row "dst")
                   :type (enchiridion.memory.store:field row "type")
                   :weight (enchiridion.memory.store:field row "weight")
                   :obs (enchiridion.memory.store:field row "obs")
                   :updated-ts (or (enchiridion.memory.store:field row
                                                                    "updated_ts")
                                   0))))
        (when (member (link-src-kind edge) kinds :test #'string=)
          (push edge (gethash (node (link-src-kind edge) (link-src edge))
                              graph)))))
    graph))

(defun split-context-key (key)
  "Return a stored context key as a list.  The column holds a comma-joined
triple of project, session, and channel."
  (when (and (stringp key) (plusp (length key)))
    (uiop:split-string key :separator ",")))

;;;; ---------------------------------------------------------------------
;;;; 11. The encoding filter: two filters, not one.

(defun capture-p (text)
  "Return T when TEXT may be appended to the episodic log, and signal otherwise.

Capture filters almost nothing: the log is the fallback retrieval substrate, so
filtering at capture would remove the safety net.  The only rejections are the
existing block scan's -- invisible Unicode and injection phrasing -- reused
here rather than reimplemented, because a second copy of a security check is a
second copy that drifts."
  (handler-case
      (progn (enchiridion.memory:scan-block-text :episode text) t)
    (enchiridion.errors:configuration-error () nil)))

(defparameter +promotion-conditions+
  '(:novelty :conflict :self-relevance :prospective :procedural :correction)
  "The six conditions of which any one promotes a captured episode into the
derived layer.  Capture is nearly unfiltered; promotion is selective.  Every
condition is model-free and runs on the asynchronous pass.")

(defun promotion-condition (features)
  "Return the first promotion condition FEATURES satisfies, or NIL.

FEATURES is a plist of booleans the derivation pass computes.  Returning the
condition rather than a boolean is deliberate: the condition is what selects
which derivation runs, and a pass that only knows *that* an episode is
interesting does not know what to do with it."
  (find-if (lambda (key) (getf features key)) +promotion-conditions+))

(defparameter +filter-weights+
  '(:novelty 0.35 :goal 0.20 :self-reference 0.15 :arousal 0.15
    :length 0.15 :redundancy -0.40 :source-authority 0.10)
  "Weights of the depth chooser.  Novelty dominates because a duplicate costs a
row and teaches nothing; redundancy is the only negative term.")

(defun encoding-filter (features &key (weights +filter-weights+)
                                     (skip-below 0.15) (deep-above 0.45))
  "Return the encoding depth for one candidate experience: 0, 1, or 2.

Depth 0 means do not derive anything.  Depth 1 is a verbatim episode.  Depth 2
is an episode that additionally carries an agent-relative form, which is the
self-reference mechanism: the assertion is stored twice, once as a world-state
proposition and once as a proposition about the agent's own goals, capabilities
or commitments.  The design requires the retrieval cue to match the stored cue
type for the second form to help, and states that storing the form without
matching the cue is an unvalidated analogy.

The arousal input is used only to prioritise consolidation.  It is never a term
in the retrieval score, and the design states that no retrieved source licenses
a mapping from a machine signal to human arousal."
  (let ((score (+ (* (getf weights :novelty) (float (or (getf features :novelty) 1.0)))
                  (* (getf weights :goal) (float (or (getf features :goal-relevance) 0.0)))
                  (* (getf weights :self-reference)
                     (if (getf features :self-reference-p) 1.0 0.0))
                  (* (getf weights :arousal) (float (or (getf features :arousal) 0.0)))
                  (* (getf weights :length) (float (or (getf features :length-factor) 0.0)))
                  (* (getf weights :redundancy) (float (or (getf features :redundancy) 0.0)))
                  (* (getf weights :source-authority)
                     (float (or (getf features :source-authority) 0.0))))))
    (cond ((< score skip-below) 0)
          ((< score deep-above) 1)
          (t 2))))

;;;; ---------------------------------------------------------------------
;;;; 12. The write path.  Append first, tag, derive nothing.

(defparameter +authority-by-provenance+
  '(("owner" . 5) ("system" . 4) ("agent" . 3) ("untrusted" . 1))
  "The authority ordinal assigned from the provenance class.  The provenance
classes are a closed set adopted from documented prior art; the 1..5 ordinal
is INVENTED-DESIGN, because no retrieved human finding fixes a scale.")

(defun authority-for (provenance)
  "Return the authority ordinal for PROVENANCE, defaulting to the lowest.

The default is the lowest on purpose: content whose provenance cannot be
determined is never promoted to the highest authority."
  (or (cdr (assoc (string-downcase (string provenance))
                  +authority-by-provenance+ :test #'string=))
      1))

(defun rarity-of (store body)
  "Return a cheap lexical rarity hint for BODY, in 0..1, with no model call.

One minus the fraction of the body's content tokens that the episodic index
already holds.  A text made of words the agent has never used is distinctive; a
text made of words it uses constantly is not.  This is a proxy for the
distinctiveness claim and it is INVENTED-DESIGN: the original distinctiveness
studies were not retrieved, so only the relative form of the claim is used."
  (let ((tokens (remove-duplicates (tokenise body) :test #'string=)))
    (if (null tokens)
        0.0
        (let ((known 0))
          (dolist (token tokens)
            (when (plusp (or (enchiridion.memory.store:field
                              (first (enchiridion.memory.store:query-rows
                                      store
                                      "SELECT COUNT(*) AS n FROM episodes_fts
                                        WHERE episodes_fts MATCH ?"
                                      (list (enchiridion.memory.store:fts-query
                                             token))))
                              "n")
                             0))
              (incf known)))
          (- 1.0 (/ (float known) (float (length tokens))))))))

(defun arousal-proxy (body)
  "Return a bounded lexical arousal proxy for BODY, in 0..1, with no model call.

The proxy counts operator correction markers, explicit failure words, negation
of a prior assertion, and evaluative intensifiers, and saturates.  It is
INVENTED-DESIGN and it is used only to prioritise consolidation.  It is not a
retrieval term and the design forbids presenting it as an affective mechanism."
  (let ((markers 0))
    (when (stringp body)
      (incf markers (min 3 (count #\! body)))
      (incf markers (min 3 (count-if #'upper-case-p body)))
      (dolist (word '("must" "urgent" "critical" "never" "always" "failed"
                      "wrong" "incorrect" "instead" "actually" "important"))
        (when (search word (string-downcase body)) (incf markers))))
    (min 1.0 (/ (float markers) 12.0))))

(defun context-key-for (&key project session channel)
  "Return the context key the write path stores: a comma-joined triple."
  (format nil "~A,~A,~A"
          (or project "")
          (or session "")
          (string-downcase (string (or channel :cli)))))

(defun write-episode (store &key session role body (ts (get-universal-time))
                                   event-ts (channel :cli) project
                                   (provenance "untrusted") (origin "")
                                   (cue-type "episodic") (depth 0) (span "")
                                   (horizon 2592000) source-turn-id
                                   (derive-p t) (parameters *memory-parameters*))
  "Append one episode to STORE, tag it, and open its activation summary.

This is the whole interactive write path and it calls no model: a row is
inserted, an activation summary is opened, and lexical co-occurrence links are
recorded.  Assertions, schemas and procedures are NOT derived here -- that is
the consolidation pass's job, so a slow parse can never delay a turn.  That
split is the design's answer to the measured fragility of synchronous
structured generation under weaker backbones.

Every string passes through the store's own SCRUBBED before it reaches a
column, which is the invariant the existing store already enforces.  Returns
the new EPISODE, or NIL when the capture filter refused the text."
  (check-type body string)
  (unless (capture-p body)
    (return-from write-episode nil))
  (let* ((session (enchiridion.memory.store:scrubbed (or session "default")))
         (role (enchiridion.memory.store:scrubbed (string-downcase (string role))))
         (body (enchiridion.memory.store:scrubbed body))
         (origin (enchiridion.memory.store:scrubbed (or origin "")))
         (context (context-key-for :project project :session session
                                   :channel channel))
         ;; T0 is two writes: the episode and its activation summary. The
         ;; rarity scan and the co-occurrence links are T1 work; DERIVE-P NIL
         ;; is how the reply path asks for the cheap form.
         (rarity (if derive-p (rarity-of store body) 0.0))
         (arousal (arousal-proxy body))
         (authority (authority-for provenance)))
    (enchiridion.memory.store:exec
     store
     "INSERT INTO episodes
        (session, role, body, ts, event_ts, channel, provenance, origin,
         authority, cue_type, depth, span, rarity_raw, arousal_raw,
         context_key, scene_trace, horizon, source_turn_id, run_id)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, '', ?, ?, NULL)"
     (list session role body ts event-ts (string-downcase (string channel))
           provenance origin authority cue-type depth span rarity arousal
           context horizon source-turn-id))
    (let ((id (enchiridion.memory.store:last-row-id store)))
      (enchiridion.memory.store:exec
       store
       ;; The insert trigger has already written a default row; the
       ;; encoding filter's importance and rarity replace its values.
       "INSERT INTO activation
          (kind, id, n_enc, last_enc, n_ret, last_ret, created_ts,
           supp, supp_ts, imp, distinctness)
          VALUES ('episode', ?, 1, ?, 0, NULL, ?, 0.0, NULL, ?, ?)
          ON CONFLICT (kind, id) DO UPDATE
            SET imp = excluded.imp, distinctness = excluded.distinctness"
       (list id ts ts (importance-from-depth depth) rarity))
      (when derive-p
        (link-co-occurrences store id body ts parameters))
      (make-episode :id id :session session :role role :body body :ts ts
                    :event-ts event-ts
                    :channel (intern (string-upcase (string channel)) :keyword)
                    :provenance provenance :origin origin :authority authority
                    :cue-type cue-type :depth depth :span span
                    :rarity-raw rarity
                    :arousal-raw (round (* 12 arousal))
                    :context-key context :horizon horizon :run-id nil))))

(defun importance-from-depth (depth)
  "Return the write-time importance 1..10 from the encoding depth.

INVENTED-DESIGN: the filter chose the deeper form only when the features said
so, and a deeper encoding is treated as a more important one.  The evaluation
plan fits this mapping rather than assuming it."
  (case depth (0 3) (1 5) (t 7)))

(defun link-co-occurrences (store episode-id body ts parameters)
  "Record a CO_OCCURS link from EPISODE-ID to episodes sharing a token with BODY.

Returns the number of links written.  The links are lexical and cheap on
purpose: they are the seed of the association graph and they are derived, so a
later consolidation run may rebuild them, which is what makes the graph
disposable."
  (let ((written 0))
    (dolist (token (remove-duplicates (tokenise body) :test #'string=))
      (dolist (row (enchiridion.memory.store:query-rows
                    store
                    "SELECT e.id FROM episodes_fts
                       JOIN episodes e ON e.id = episodes_fts.rowid
                      WHERE episodes_fts MATCH ? AND e.id <> ?
                      ORDER BY rank LIMIT ?"
                    (list (enchiridion.memory.store:fts-query token)
                          episode-id
                          (parameter :link-fanout parameters))))
        (let ((other (enchiridion.memory.store:field row "id")))
          (enchiridion.memory.store:exec
           store
           "INSERT INTO links (src_kind, src, dst_kind, dst, type, weight, obs,
                               updated_ts, run_id, generation_id)
              VALUES ('episode', ?, 'episode', ?, 'co_occurs', 1.0, 1, ?, 0, 0)
              ON CONFLICT (src_kind, src, dst_kind, dst, type, generation_id)
              DO UPDATE SET obs = obs + 1, updated_ts = excluded.updated_ts"
           (list episode-id other ts))
          (incf written))))
    written))

;;;; ---------------------------------------------------------------------
;;;; 13. Contradiction: update distinguished from revision.

(defun conflicting-p (left right)
  "Return T when two ASSERTIONs cannot both be applied as stated.

Two assertions conflict when they share a subject and a relation and differ in
object or in polarity.  The test is deliberately narrow: a relation whose
object is a set is not handled, and the design states that limitation."
  (and (string-equal (assertion-subject left) (assertion-subject right))
       (string-equal (assertion-relation left) (assertion-relation right))
       (or (not (string-equal (assertion-object left) (assertion-object right)))
           (/= (assertion-polarity left) (assertion-polarity right)))))

(defun conflict-kind-for (left right)
  "Return the conflict kind of LEFT and RIGHT, or NIL when they do not conflict.

The three kinds are the benchmark's: Context-Partitioned, Behaviour-Oscillation
and Source-Contradiction.  The mapping from two records to a kind is this
design's own and is INVENTED-DESIGN: the benchmark defines the kinds as
categories and does not give a classifier."
  (when (conflicting-p left right)
    (cond
      ((not (string-equal (assertion-provenance left)
                          (assertion-provenance right)))
       "scc")
      ((and (string-equal (assertion-provenance left) "agent")
            (string-equal (assertion-provenance right) "agent"))
       "boc")
      (t "cpc"))))

(defun valid-intervals-overlap-p (left right)
  "Return T when the asserted validity intervals of LEFT and RIGHT overlap.

The intervals are half-open: VALID-FROM is the first instant the assertion
holds and VALID-TO the first instant it stops holding, so an assertion ending
where another begins is an update and not a revision.  With an inclusive test
every clean hand-over of a value would be classified as a conflict.  A NULL
bound is an open end, and two open assertions overlap."
  (let ((left-from (or (assertion-valid-from left) 0))
        (left-to (or (assertion-valid-to left) most-positive-fixnum))
        (right-from (or (assertion-valid-from right) 0))
        (right-to (or (assertion-valid-to right) most-positive-fixnum)))
    (and (< left-from right-to) (< right-from left-to))))

(defun update-conditions-hold-p (old new &key change-event-p continuing-evidence-p)
  "Return T when NEW supersedes OLD, and NIL when the pair is a revision.

The five conditions, all of which must hold for an update:

  (i)   the subject and the relation are identical;
  (ii)  the two validity intervals are disjoint, or the new interval starts
        after the old one's start;
  (iii) a CHANGE EVENT exists in the episodic log that explains the
        transition -- an observation that the world changed, rather than
        merely a later statement of the opposite;
  (iv)  the two share a provenance class, or the new one's authority is
        strictly higher;
  (v)   the old assertion has no evidence of continuing validity after the new
        one's VALID-FROM.

Condition (iii) is the one that makes this rule different from every documented
one.  An update is a claim about the world's history and is checkable against
the log; a revision is a claim that one source should outrank another, and the
one benchmark that measures that case reports that fixed rules are
insufficient.  So the asymmetry is the design: an update can be decided by the
system, and a revision cannot."
  (and (string-equal (assertion-subject old) (assertion-subject new))
       (string-equal (assertion-relation old) (assertion-relation new))
       (or (not (valid-intervals-overlap-p old new))
           (and (assertion-valid-from new)
                (assertion-valid-from old)
                (> (assertion-valid-from new) (assertion-valid-from old))))
       change-event-p
       (or (string-equal (assertion-provenance old)
                         (assertion-provenance new))
           (> (assertion-authority new) (assertion-authority old)))
       (not continuing-evidence-p)))

(defun conflict-basis-for (old new &key change-event-p continuing-evidence-p)
  "Return the one-line basis of the conflict between OLD and NEW.

The basis distinguishes an update from a revision, which is what makes the
ledger auditable: an operator can read why the system decided that a value
changed rather than that a source won."
  (format nil "~A ~A ~A | ~A ~A ~A | ~A~@[ | change event~]~@[ | continuing evidence~]"
          (assertion-subject old) (assertion-relation old) (assertion-object old)
          (assertion-subject new) (assertion-relation new) (assertion-object new)
          (if (update-conditions-hold-p old new
                                        :change-event-p change-event-p
                                        :continuing-evidence-p continuing-evidence-p)
              "update: the five conditions hold, the old interval is closed"
              "revision: at least one condition fails, both records stay live")
          change-event-p continuing-evidence-p))

(defun detect-conflicts (new existing &key (now (get-universal-time))
                                          change-event-p continuing-evidence-p)
  "Return the CONFLICT records NEW opens against EXISTING, and the updates.

Two values.  The first is the list of CONFLICT records to insert.  The second
is the list of OLD assertions that the update rule supersedes, which the caller
closes by setting TX-TO; a superseded row is never deleted.

Nothing is resolved here.  Detection produces records, and resolution happens
at the point of action, which is the requirement that the conflict-bearing
relation survive extraction: the relation is a row in its own table referencing
both assertions by id."
  (let ((conflicts '()) (superseded '()))
    (dolist (old existing)
      (when (conflicting-p new old)
        (if (update-conditions-hold-p old new
                                      :change-event-p change-event-p
                                      :continuing-evidence-p continuing-evidence-p)
            (push old superseded)
            (push (make-conflict :kind (conflict-kind-for new old)
                                 :left-id (assertion-id new)
                                 :right-id (assertion-id old)
                                 :detected-ts now
                                 :basis (conflict-basis-for
                                         old new
                                         :change-event-p change-event-p
                                         :continuing-evidence-p
                                         continuing-evidence-p))
                  conflicts))))
    (values (nreverse conflicts) (nreverse superseded))))

(defun resolve-conflict (conflict &key resolution (resolver "action-time")
                                        (query "") (now (get-universal-time))
                                        (at-action-p t))
  "Return CONFLICT with a resolution recorded, or unchanged when not at action.

Resolution is deferred to the point of action by construction: with
AT-ACTION-P false the conflict comes back untouched, so a consolidation pass
can call this and cannot resolve anything by accident.  Neither referenced
assertion is modified -- a resolution is a new fact about the pair, which is
what keeps the earlier assertion legible."
  (if (not at-action-p)
      conflict
      (progn
        (setf (conflict-resolution-state conflict) "resolved"
              (conflict-resolution conflict) resolution
              (conflict-resolved-ts conflict) now
              (conflict-resolver conflict) resolver
              (conflict-acting-query conflict) query)
        conflict)))

;;;; ---------------------------------------------------------------------
;;;; 14. The Calibrator: a machine judgement of learning, fitted per family.
;;;;
;;;; Human judgements of learning are cue-based inferences, not readouts of
;;;; trace strength, and foresight bias makes a write-time judgement nearly
;;;; worthless: at write time the content is present and fluent.  The design
;;;; therefore computes no confidence at write time, and the prediction below
;;;; is made before a retrieval from features available without one.

(defparameter +calibration-features+
  '(:max-score :score-gap :cue-coverage :cue-type-match :conflict-load
    :family-prior :degraded)
  "The features the Calibrator reads.  All are model-free and all are available
before the retrieval is issued.")

(defparameter *calibration-weights*
  (list :max-score 1.6 :score-gap 0.9 :cue-coverage 1.2 :cue-type-match 0.7
        :conflict-load -1.1 :family-prior 0.6 :degraded -0.8 :bias -0.4)
  "Fallback logistic weights, in log-odds units, used when a family has too
few observed outcomes to fit an isotonic curve.  Every magnitude is
INVENTED-DESIGN; the signs encode the design's expectations.")

(defun isotonic-fit (points)
  "Return a monotone step curve fitted to POINTS by pool-adjacent-violators.

POINTS is a list of (PREDICTED . OBSERVED) pairs.  The result is a list of
(THRESHOLD . VALUE) breakpoints with non-decreasing VALUE, which is what makes
the fitted calibration monotone: a higher prediction can never map to a lower
calibrated probability.  Isotonic regression is used because it makes no
distributional assumption and is cheap enough to refit on the asynchronous
path.  The design labels the choice INVENTED-DESIGN."
  (let ((sorted (sort (copy-list points) #'< :key #'car))
        (blocks '()))
    (dolist (point sorted)
      (push (list (car point) (float (cdr point)) 1) blocks)
      (loop while (and (cdr blocks)
                       (> (/ (second (first blocks)) (third (first blocks)))
                          (/ (second (second blocks)) (third (second blocks)))))
            do (let ((newer (pop blocks)) (older (pop blocks)))
                 (push (list (max (first newer) (first older))
                             (+ (second newer) (second older))
                             (+ (third newer) (third older)))
                       blocks))))
    (nreverse (mapcar (lambda (block)
                        (cons (first block) (/ (second block) (third block))))
                      blocks))))

(defun isotonic-predict (curve value)
  "Return the calibrated probability CURVE assigns to VALUE.

CURVE is the output of ISOTONIC-FIT, a step function.  Below the first
breakpoint the first value is used and above the last the last value is used,
which is the standard convention for a step calibration and avoids inventing
behaviour outside the fitted range."
  (if (null curve)
      nil
      (let ((answer (cdr (first curve))))
        (dolist (breakpoint curve answer)
          (if (<= (car breakpoint) value)
              (setf answer (cdr breakpoint))
              (return answer))))))

(defun calibration-features (scored &key (cue-coverage 0.0) (family-prior 0.5)
                                         (degraded-p nil))
  "Return the Calibrator's feature plist from a scored retrieval.

SCORED is the output of RETRIEVE, best first.  CUE-COVERAGE is the fraction of
the query's terms that occur anywhere in the index, which the caller computes
from the candidate set.  Every feature is available before the retrieval is
issued, which is the property that makes the judgement a prediction rather than
a report."
  (let* ((top (first scored))
         (second (second scored))
         (max-score (if top (getf top :score) 0.0))
         (gap (if second (- max-score (getf second :score)) 0.0))
         (conflict-load (count-if #'identity scored
                                  :key (lambda (row) (getf row :conflict)))))
    (list :max-score max-score
          :score-gap gap
          :cue-coverage cue-coverage
          :cue-type-match (if top (terms-cue-type (getf top :terms)) 0.0)
          :conflict-load conflict-load
          :family-prior family-prior
          :degraded (if degraded-p 1.0 0.0))))

(defun judgement-of-learning (features &key curve (weights *calibration-weights*))
  "Return the predicted probability that the retrieval will be useful, in 0..1.

CURVE, when supplied, is an isotonic fit for the query's family and takes
precedence.  Without one the fallback logistic is used.  The design computes
this *before* the retrieval and writes it to RETRIEVALS, so that the outcome
can be compared with the prediction; a prediction recorded after the fact is
not a prediction."
  (if curve
      (or (isotonic-predict curve (float (or (getf features :max-score) 0.0)))
          0.5)
      (let ((log-odds
              (+ (getf weights :bias)
                 (* (getf weights :max-score) (float (or (getf features :max-score) 0.0)))
                 (* (getf weights :score-gap) (float (or (getf features :score-gap) 0.0)))
                 (* (getf weights :cue-coverage)
                    (float (or (getf features :cue-coverage) 0.0)))
                 (* (getf weights :cue-type-match)
                    (float (or (getf features :cue-type-match) 0.0)))
                 (* (getf weights :conflict-load)
                    (float (or (getf features :conflict-load) 0.0)))
                 (* (getf weights :family-prior)
                    (float (or (getf features :family-prior) 0.5)))
                 (* (getf weights :degraded)
                    (float (or (getf features :degraded) 0.0))))))
        (/ 1.0 (+ 1.0 (exp (- log-odds)))))))

(defun recalibrate (observations &key (minimum 20))
  "Return an isotonic curve fitted to OBSERVATIONS, or NIL when there are too
few.

OBSERVATIONS is a list of plists with :PREDICTED and :OBSERVED.  The feedback
signal is what closes the loop, and it is sourced from the environment rather
than from the model: the operator's correction, the outcome of an action that
depended on the retrieval, or a later episode that contradicts the retrieved
assertion.  A retrieval with none of those has OBSERVED NULL and is excluded,
because a window of guesses teaches the predictor its own bias.

MINIMUM is the point below which a family falls back to the logistic: fitting a
monotone curve to a handful of points produces a step function that looks
confident and carries no information."
  (if (< (length observations) minimum)
      nil
      (isotonic-fit (mapcar (lambda (row)
                              (cons (float (getf row :predicted))
                                    (getf row :observed)))
                            observations))))

(defun gate-action (predicted conflict-load &key (parameters *memory-parameters*)
                                                   (external-available-p t))
  "Return the Calibrator's routing decision as one of four keywords.

  :RELY            P-hat at or above the rely threshold with no conflict load
  :RETRIEVE-MORE   0.50 <= P-hat < 0.80: widen k, add a hop, or promote a tier
  :SEARCH-EXTERNAL P-hat below 0.50, or any conflict load on an action query
  :ABSTAIN         P-hat below 0.50 and no external channel exists

Confidence gates action selection and never rewrites an answer in place: the
self-correction result is that models struggle to correct their own responses
without external feedback and sometimes degrade.  The thresholds are
INVENTED-DESIGN."
  (let ((rely (parameter :rely-threshold parameters))
        (search (parameter :search-threshold parameters)))
    (cond ((and (>= predicted rely) (zerop conflict-load)) :rely)
          ((plusp conflict-load) :search-external)
          ((>= predicted search) :retrieve-more)
          (external-available-p :search-external)
          (t :abstain))))

(defun search-externally-p (predicted &key (parameters *memory-parameters*)
                                          (conflict-load 0))
  "Return T when the Calibrator's gate routes away from memory."
  (not (null (member (gate-action predicted conflict-load
                                  :parameters parameters)
                     '(:search-external :abstain)))))

(defun record-outcome (store kind ref predicted observed
                       &key (query-id "") (cue-type "")
                            (ts (get-universal-time)))
  "Write one retrieval outcome and return its row id.

OBSERVED is 1 when the retrieved record was used and the action succeeded, 0
when it was used and failed, and the call refuses anything else: an outcome
that was never observed must not enter the calibration window."
  (check-type observed (integer 0 1))
  (enchiridion.memory.store:exec
   store
   "INSERT INTO retrievals (kind, ref, ts, query_id, cue_type, predicted, observed)
      VALUES (?, ?, ?, ?, ?, ?, ?)"
   (list kind ref ts query-id cue-type (float predicted) observed))
  (enchiridion.memory.store:last-row-id store))

;;;; ---------------------------------------------------------------------
;;;; 15. Procedure admission and selection.

(defun admission-rule (procedure)
  "Return T when a PROCEDURE has earned admission, and NIL otherwise.

Four conditions, each a documented negative result rather than a preference.
Granularity must be subtask, because the reported effect flips sign on that
axis alone: task-level skills mostly reduced performance below a no-memory
baseline while subtask-level skills raised it.  Reuse must be demonstrated on
distinct task classes, because model-authored procedures were reported to
deliver no gain where curated ones delivered +16.2 percentage points.
Failures must not have caught up with successes.  And the precondition
predicate must be evaluable in-process, because evaluating it with a model
would put a model call on the interactive path."
  (and (string-equal (getf procedure :granularity) "subtask")
       (>= (or (getf procedure :distinct-tasks) 0) 2)
       (>= (or (getf procedure :evidence-count) 0) 3)
       (< (or (getf procedure :failures) 0)
          (or (getf procedure :evidence-count) 0))
       (getf procedure :applicable-when)
       (getf procedure :in-process-p)))

(defun procedure-eligible-p (procedure state)
  "Return T when PROCEDURE's preconditions are satisfied in STATE.

STUB for the predicate evaluation itself: the design requires the predicate to
be an S-expression over the world block, the working directory, the tools in
the registry, the session kind and the previous step's outcome, evaluated
in-process by the reader.  The evaluation is not implemented here because it
needs a sandbox the harness does not yet expose, and inventing one in a design
sketch would misrepresent what exists.  The contract is that this function
returns T only when the predicate evaluates true and every required input is
present, and that it signals no condition a caller has to distinguish."
  (declare (ignore procedure state))
  nil)

;;;; ---------------------------------------------------------------------
;;;; 16. The consolidation entry point.
;;;;
;;;; One function, called between sessions and never inside a turn.  It is
;;;; idempotent by construction: it works from a watermark, every insert
;;;; carries the run id, and the uniqueness constraints make a second pass
;;;; over the same range a no-op.

(defun episode-from-row (row)
  "Return ROW, one episodes row as a plist, as an EPISODE."
  (make-episode :id (enchiridion.memory.store:field row "id")
                :session (enchiridion.memory.store:field row "session")
                :role (enchiridion.memory.store:field row "role")
                :body (enchiridion.memory.store:field row "body")
                :ts (enchiridion.memory.store:field row "ts")
                :event-ts (enchiridion.memory.store:field row "event_ts")
                :provenance (enchiridion.memory.store:field row "provenance")
                :origin (enchiridion.memory.store:field row "origin")
                :authority (enchiridion.memory.store:field row "authority")
                :cue-type (enchiridion.memory.store:field row "cue_type")
                :depth (enchiridion.memory.store:field row "depth")
                :context-key (enchiridion.memory.store:field row "context_key")
                :scene-trace (enchiridion.memory.store:field row "scene_trace")
                :horizon (or (enchiridion.memory.store:field row "horizon")
                             2592000)))

(defvar *derivation-tokens* nil
  "NIL, or the tokens the deriver has spent in the build batch that bound it.
BUILD-CANDIDATE binds it to 0 and adds the total to the candidate's
TOKENS_USED, which is what the cost gate reads; a deriver that makes a model
call adds what the provider billed.")

(defparameter *assertion-deriver* nil
  "A function of (STORE EPISODE) returning (values ASSERTIONS CHANGE-EVENTS).
NIL means no derivation is installed: the builder must not watermark an
episode it cannot derive. The production deriver is a model call; tests bind a
deterministic function.")

(defun assertions-for-episode (store episode)
  "Return the ASSERTIONs derived from EPISODE, and the change events.
The production deriver is installed in *ASSERTION-DERIVER*. A NIL deriver
returns no rows rather than inventing a parser. The contract the deriver must
satisfy: every assertion carries the episode's id, a character span, the
episode's provenance and authority, and the run id it was derived under; an
assertion with no span is rejected by the caller; and the composite unique key
makes a second pass over the same episode insert nothing."
  (if *assertion-deriver*
      (funcall *assertion-deriver* store episode)
      (values nil nil)))

(defun assertion-from-row (row)
  "Return ROW, one assertions row as a plist, as an ASSERTION."
  (make-assertion
   :id (enchiridion.memory.store:field row "id")
   :subject (enchiridion.memory.store:field row "subject")
   :relation (enchiridion.memory.store:field row "relation")
   :object (enchiridion.memory.store:field row "object")
   :polarity (enchiridion.memory.store:field row "polarity")
   :episode-id (enchiridion.memory.store:field row "episode_id")
   :valid-from (enchiridion.memory.store:field row "valid_from")
   :valid-to (enchiridion.memory.store:field row "valid_to")
   :tx-from (enchiridion.memory.store:field row "tx_from")
   :tx-to (enchiridion.memory.store:field row "tx_to")
   :authority (enchiridion.memory.store:field row "authority")
   :provenance (enchiridion.memory.store:field row "provenance")
   :cue-type (enchiridion.memory.store:field row "cue_type")
   :schema-id (enchiridion.memory.store:field row "schema_id")
   :run-id (enchiridion.memory.store:field row "run_id")))

;;;; ---------------------------------------------------------------------
;;;; 17. End of the sketch.
;;;;
;;;; One stub remains: PROCEDURE-ELIGIBLE-P, which needs an evaluation sandbox
;;;; this document does not specify.  The sketch's single-pass CONSOLIDATE is
;;;; gone: derivation runs through candidate generations (generations.cl), and
;;;; only the gates in cue.cl can make one live.
