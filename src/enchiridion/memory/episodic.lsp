;;;; episodic.lsp --- Episodic records, retrieval and consolidation.

(in-package #:enchiridion.memory)

;;;; ---------------------------------------------------------------------
;;;; 1. Parameters.

(defparameter *memory-parameters*
  (list
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
   :pack-claims-attached 2    ; claims shown under their own episode in the pack
   :pack-claims-alone  3      ; claims in the pack whose episode the cue missed
   :pack-claims-alone-per-episode 1 ; of those, from any one source episode
   :pack-header        t      ; prefix each record with its date and role
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
  "All memory model hyperparameters in a single plist.")

(defun parameter (key &optional (parameters *memory-parameters*))
  "Return the value of KEY in PARAMETERS, or signal when it is absent.
A key present with the value NIL returns NIL; only a missing key signals."
  (let ((value (getf parameters key '%absent)))
    (if (eq value '%absent)
        (error "The memory model has no parameter ~S." key)
        value)))

;;;; ---------------------------------------------------------------------
(defparameter *retrieval-body-chars* 4000
  "How much of an episode body a candidate query loads. Ranking a candidate needs
the body only to match the cue's terms, and the pack reads its own window.")

(defparameter *pack-body-chars* 20000
  "How much of an episode body the pack searches for its excerpt. The rest stays
in the store, where the search tool reads it.")

(defun table-names ()
  "Return the tables the memory model adds, index table first."
  *episodic-tables*)

(defun ensure-episodic-schema (store)
  "Create all episodic memory tables on STORE (idempotent via IF NOT EXISTS)
and return the number of statements executed."
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
  "Common stop words stripped by TOKENISE.")

(defun tokenise (text)
  "Return the content tokens of TEXT as a list of lowercase strings."
  (when (stringp text)
    (remove-if (lambda (token) (member token +stop-words+ :test #'string=))
               (cl-ppcre:all-matches-as-strings +token-scanner+
                                                (string-downcase text)))))

(defun term-coverage (cue-tokens text)
  "Return the fraction of unique CUE-TOKENS present in TEXT, in 0..1.
Used as the Calibrator's cue-coverage feature and spreading seed weight."
  (if (null cue-tokens)
      0.0
      (let* ((unique (remove-duplicates cue-tokens :test #'string=))
             (body (tokenise text)))
        (if (null body)
            0.0
            (/ (count-if (lambda (token) (member token body :test #'string=))
                         unique)
               (float (length unique)))))))

;;;; Model call accounting for optional retrieval-path calls (reranker, embedder).

(defvar *memory-usage-store* nil
  "The store the optional model calls inside a retrieval bill to, or NIL.")

(defvar *memory-usage-session* nil
  "The session id those calls are attributed to.")

(defvar *memory-usage-channel* :cli
  "The channel those calls are attributed to. A call site that knows better,
such as the reranker, passes its own.")

(defmacro with-memory-usage ((store &key session (channel :cli)) &body body)
  "Run BODY with STORE as the ledger its optional model calls bill to."
  `(let ((*memory-usage-store* ,store)
         (*memory-usage-session* ,session)
         (*memory-usage-channel* ,channel))
     ,@body))

(defun record-memory-usage (&key (store *memory-usage-store*)
                              (session *memory-usage-session*)
                              model input output cache-read cache-write
                              (channel *memory-usage-channel*))
  "Record one optional model call's token usage to STORE and return its row id.
No-op when STORE is NIL; logs to *ERROR-OUTPUT* and returns NIL on write error."
  (when store
    (handler-case
        (enchiridion.memory.store:record-usage
         store
         :session (or session "")
         :model (or model "")
         :input (or input 0)
         :output (or output 0)
         :cache-read (or cache-read 0)
         :cache-write (or cache-write 0)
         :channel channel)
      (error (condition)
        (format *error-output*
                "~&enchiridion: could not write a ~A usage row: ~A~%"
                channel condition)
        nil))))

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
  "Return C-hat_i between ITEM-CONTEXT and CURRENT-CONTEXT: 1.0 for same project
and session, 0.5 for same project only, else 0.0 (ignores channel)."
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
  "Alist mapping each cue type to its partially compatible cue types (score 0.5).")

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
  "Return T-hat_i: +1.0 inside [VALID-FROM, VALID-TO), 0.0 if QUERY-TIME is NIL,
else -1.0. Uses half-open intervals with NIL bounds as open ends; signed and
excluded from rank-normalisation."
  (if (null query-time)
      0.0
      (let ((from (or valid-from 0))
            (to (or valid-to most-positive-fixnum)))
        (if (and (<= from query-time) (< query-time to)) 1.0 -1.0))))

;;;; ---------------------------------------------------------------------
;;;; 5. ACT-R base level (two event populations: encoding weighted by LAMBDA-E,
;;;; retrieval by 1.0) with selectable functional form.

(defparameter +base-level-forms+ '(:power :exponential :logarithmic :exponential-power)
  "Supported functional forms for BASE-LEVEL (default :POWER).")

(defun base-level-forms ()
  "Return the functional forms BASE-LEVEL accepts."
  +base-level-forms+)

(defun base-level-exact (encoding-refs retrieval-refs now
                         &key (d 0.5) (lambda-e 0.5) (beta 0.0))
  "Return B_i = ln(lambda-E * sum_E t_j^-d + sum_R t_k^-d) + beta_i.
ENCODING-REFS and RETRIEVAL-REFS are universal-time lists; future references
clamp to age 1s."
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
  "Return B_i from summary counts N-ENC, N-RET and LIFETIME under FORM.
Effective count is n = lambda-E * n-enc + n-ret; returns BETA when n = 0.
Absolute values are not comparable across forms, so FORM must be uniform per query."
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
  "Return B_i for ACTIVATION at NOW from its stored reference summary.
Returns BETA when the record has no references."
  (let* ((n-enc (activation-n-enc activation))
         (n-ret (activation-n-ret activation))
         (created (activation-created-ts activation))
         (lifetime (max 1 (- now (if (plusp created) created now)))))
    (base-level-approx n-enc n-ret lifetime now
                       :d d :lambda-e lambda-e :beta beta
                       :form form :time-constant time-constant)))

(defun decay-update (activation now &key (parameters *memory-parameters*))
  "Recompute ACTIVATION's base level at NOW without writing to the store.
Returns (values B_i PRUNE-P), where PRUNE-P is T for non-retained kinds below
:PRUNE-BELOW."
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
  "Read-only sweep of all activation rows at NOW, returning a plist with
:SCANNED, :LIVE, :EXEMPT (retained kinds), and :DORMANT ((KIND ID BASE) below
:PRUNE-BELOW). Does not delete or retire rows."
  (let ((rows (enchiridion.memory.store:query-rows
               store
               "SELECT kind, id, n_enc, last_enc, n_ret, last_ret, created_ts,
                       supp, supp_ts, imp, distinctness
                  FROM activation"))
        (dormant '()) (live 0) (exempt 0))
    (dolist (row rows)
      (let ((record (activation-from-row row)))
        ;; One call per row: it returns the base level and the prune verdict.
        (multiple-value-bind (base candidate)
            (decay-update record now :parameters parameters)
          (cond ((member (activation-kind record)
                         (parameter :retained-kinds parameters) :test #'string=)
                 (incf exempt))
                (candidate
                 (push (list (activation-kind record) (activation-id record) base)
                       dormant))
                (t (incf live))))))
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
  "Decay ACTIVATION's suppression to NOW, add :SUPP-INCREMENT (capped at 1.0),
update ACTIVATION in place, and return the new value."
  (let* ((previous (if (and (activation-supp-ts activation)
                            (plusp (activation-supp activation)))
                       (decay-inhibition activation now :parameters parameters)
                       (activation-supp activation)))
         (raised (min 1.0 (+ previous (parameter :supp-increment parameters)))))
    (setf (activation-supp activation) raised
          (activation-supp-ts activation) now)
    raised))

(defun decay-inhibition (activation now &key (parameters *memory-parameters*))
  "Return ACTIVATION's suppression decayed on read to NOW using :SUPP-HALF-LIFE."
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
  "Return fan(src): out-degree of (KIND . ID) in GRAPH plus one."
  (1+ (length (gethash (node kind id) graph))))

(defun associative-strength (graph src-kind src &key (max-associative 2.0))
  "Return S_ji = max(0.0, S - ln(fan_ji)), clamped at 0.0."
  (max 0.0 (- (float max-associative) (log (float (fan graph src-kind src))))))

(defun edge-weight (obs fan-count &key (alpha 0.5) (beta 0.5))
  "Return w(e) = (1 + obs)^alpha / (1 + fan)^beta."
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
  "Spread activation from SOURCES (plists of :KIND :ID :WEIGHT) up to MAX-HOPS
over GRAPH, returning a hash table of (KIND . ID) -> S_i (plus :CONFLICT-FLAG).
CONTRADICTS edges do not propagate activation; they flag both endpoints."
  ;; Frontier sums gains per node per hop (linear in amount), keeping cost
  ;; proportional to active nodes rather than paths (fan^hops).
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
;;;; 8. Retrieval scoring.
;;;; Only unbounded terms (base, spread, lexical) are rank-normalised; bounded
;;;; and signed terms (notably temporal in {-1, 0, +1}) keep their raw scale.

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
  "Map VALUES onto [0, 1] by rank; tied values receive the mean of their
spanned ranks (preserving deterministic tie-breaking). Single element -> (0.5)."
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
  "Return R_i, the weighted linear combination of TERMS using PARAMETERS."
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
  "Return 1 / (1 + exp(-(score - threshold) / noise)), the ACT-R logistic
transform of SCORE."
  (/ 1.0 (+ 1.0 (exp (- (/ (- (float score) (float threshold))
                           (float (max 0.0001 noise))))))))

(defun retrieval-latency (score &key (latency-factor 1.0))
  "Return F * exp(-score), the ACT-R latency metric (reporting only)."
  (* (float latency-factor) (exp (- (float score)))))

;;;; ---------------------------------------------------------------------
;;;; 9. Retrieval.

(defun candidate-fan (graph key candidate-keys)
  "Return fan_i for KEY: count of its outgoing neighbours in CANDIDATE-KEYS."
  (count-if (lambda (edge)
              (member (node (link-dst-kind edge) (link-dst edge))
                      candidate-keys :test #'equal))
            (gethash key graph)))

(defun distinctiveness (graph key candidate-keys max-fan)
  "Return D-hat_i = 1 - fan_i / max(fan), or 0.0 when MAX-FAN is 0 or NIL."
  (if (or (null max-fan) (zerop max-fan))
      0.0
      (- 1.0 (/ (float (candidate-fan graph key candidate-keys)) (float max-fan)))))

(defun item-terms (item context spread graph candidate-keys max-fan
                        now parameters)
  "Return TERMS for candidate plist ITEM (:KIND :ID :BODY :SESSION :PROJECT
:CUE-TYPE :VALID-FROM :VALID-TO :ACTIVATION :LEXICAL :QUERY-TIME)."
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
  "Rank CANDIDATES for CUE and CONTEXT by R_i (best first), returning up to TOP-K
plists (:ITEM :TERMS :SCORE :PROBABILITY :LATENCY :CONFLICT). Pure (no I/O);
NIL CUE-TYPE gives all candidates 1.0, and conflicts are flagged without penalty."
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
  "Return up to LIMIT episode candidate plists matching CUE via FTS5, joined
with activation rows. Loads the first *RETRIEVAL-BODY-CHARS* chars of body;
signals SCHEMA-ERROR if CUE has no searchable terms."
  (let ((match (cue-match cue)))
    (loop for row in (enchiridion.memory.store:query-rows
                      store
                      "SELECT e.id, substr(e.body, 1, ?) AS body,
                              e.session, e.channel, e.cue_type,
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
                      (list *retrieval-body-chars* match limit))
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
   COALESCE(act.n_enc, eact.n_enc) AS n_enc,
   COALESCE(act.last_enc, eact.last_enc) AS last_enc,
   COALESCE(act.n_ret, eact.n_ret) AS n_ret,
   COALESCE(act.last_ret, eact.last_ret) AS last_ret,
   COALESCE(act.created_ts, eact.created_ts) AS created_ts,
   COALESCE(act.supp, eact.supp) AS supp,
   COALESCE(act.supp_ts, eact.supp_ts) AS supp_ts,
   COALESCE(act.imp, eact.imp) AS imp,
   COALESCE(act.distinctness, eact.distinctness) AS distinctness"
  "Shared SELECT column list for assertion candidates; falls back to the source
episode's activation row via COALESCE when an assertion has no row of its own.")

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
          :claim-rank nil
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
  "Return GENERATION's assertion candidates for CUE (NIL when GENERATION is NIL
or 0), deduplicated across claim-FTS (:CLAIM-RANK set) and supporting-episode
FTS routes. Restricts to live rows (tx_to IS NULL) in GENERATION."
  (when (and generation (plusp generation))
    (let ((match (cue-match cue))
          (by-id (make-hash-table))
          (order '()))
      (flet ((route (statement &key claim)
               (loop for row in (enchiridion.memory.store:query-rows
                                 store statement (list match generation limit))
                     for rank from 0
                     for id = (enchiridion.memory.store:field row "id")
                     do (unless (gethash id by-id)
                          (push id order)
                          (setf (gethash id by-id) (assertion-candidate row now)))
                        (when claim
                          (setf (getf (gethash id by-id) :claim-rank) rank)))))
        (route (format nil "SELECT ~A, bm25(assertions_fts) AS lexical
                              FROM assertions_fts
                              JOIN assertions a ON a.id = assertions_fts.rowid
                              JOIN episodes e ON e.id = a.episode_id
                              LEFT JOIN activation act
                                     ON act.kind = 'assertion' AND act.id = a.id
                              LEFT JOIN activation eact
                                     ON eact.kind = 'episode' AND eact.id = e.id
                             WHERE assertions_fts MATCH ? AND a.tx_to IS NULL
                               AND a.generation_id = ?
                             ORDER BY rank LIMIT ?"
                       +assertion-candidate-columns+)
               :claim t)
        (route (format nil "SELECT ~A, bm25(episodes_fts) AS lexical
                              FROM episodes_fts
                              JOIN episodes e ON e.id = episodes_fts.rowid
                              JOIN assertions a ON a.episode_id = e.id
                              LEFT JOIN activation act
                                     ON act.kind = 'assertion' AND act.id = a.id
                              LEFT JOIN activation eact
                                     ON eact.kind = 'episode' AND eact.id = e.id
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
  "Split a comma-joined \"project,session,channel\" context key into a list.
Legacy keys whose project duplicates session are normalised to an empty project."
  (when (and (stringp key) (plusp (length key)))
    (let ((parts (uiop:split-string key :separator ",")))
      (if (and (rest parts)
               (plusp (length (first parts)))
               (string= (first parts) (second parts)))
          (cons "" (rest parts))
          parts))))

;;;; ---------------------------------------------------------------------
;;;; 11. The encoding filter: two filters, not one.

(defun capture-p (text)
  "Return T when TEXT passes SCAN-BLOCK-TEXT (no invisible Unicode or injection
phrasing), or NIL if it signals CONFIGURATION-ERROR."
  (handler-case
      (progn (enchiridion.memory:scan-block-text :episode text) t)
    (enchiridion.errors:configuration-error () nil)))

(defparameter +promotion-conditions+
  '(:novelty :conflict :self-relevance :prospective :procedural :correction)
  "Model-free conditions any one of which promotes an episode to derivation.")

(defun promotion-condition (features)
  "Return the first condition keyword in +PROMOTION-CONDITIONS+ that is true in
FEATURES plist, or NIL."
  (find-if (lambda (key) (getf features key)) +promotion-conditions+))

(defparameter +filter-weights+
  '(:novelty 0.35 :goal 0.20 :self-reference 0.15 :arousal 0.15
    :length 0.15 :redundancy -0.40 :source-authority 0.10)
  "Feature weights for ENCODING-FILTER depth selection.")

(defun encoding-filter (features &key (weights +filter-weights+)
                                     (skip-below 0.15) (deep-above 0.45))
  "Return encoding depth (0 skip derivation, 1 verbatim, 2 with agent-relative
form) from weighted FEATURES. Arousal prioritises consolidation only and is
excluded from retrieval scoring."
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
  "Mapping from provenance class string to authority ordinal (1..5).")

(defun authority-for (provenance)
  "Return the authority ordinal (1..5) for PROVENANCE, defaulting to 1."
  (or (cdr (assoc (string-downcase (string provenance))
                  +authority-by-provenance+ :test #'string=))
      1))

(defun prior-document-frequency (store token before-id)
  "Return the count of episodes with rowid < BEFORE-ID matching TOKEN in FTS5
(or all episodes when BEFORE-ID is NIL)."
  (or (enchiridion.memory.store:field
       (first (enchiridion.memory.store:query-rows
               store
               "SELECT COUNT(*) AS n FROM episodes_fts
                 WHERE episodes_fts MATCH ? AND episodes_fts.rowid < ?"
               (list (enchiridion.memory.store:fts-query token)
                     (or before-id most-positive-fixnum))))
       "n")
      0))

(defparameter *hint-token-limit* 64
  "Maximum distinct tokens inspected per body by RARITY-OF and
LINK-CO-OCCURRENCES.")

(defun hint-tokens (body)
  "Return the distinct searchable content tokens the lexical hints read from BODY.
FTS-QUERY rejects tokens with no alphanumeric character, such as underscore runs."
  (let ((tokens (remove-if (lambda (token) (notany #'alphanumericp token))
                           (remove-duplicates (tokenise body) :test #'string=))))
    (if (> (length tokens) *hint-token-limit*)
        (subseq tokens 0 *hint-token-limit*)
        tokens)))

(defun rarity-of (store body &key before-id)
  "Return lexical rarity for BODY in 0..1 as 1 - mean(df/(df+1)) over up to
*HINT-TOKEN-LIMIT* distinct tokens, counting only episodes before BEFORE-ID so
an episode does not dilute its own rarity."
  (let ((tokens (hint-tokens body)))
    (if (null tokens)
        0.0
        (let ((commonness 0.0))
          (dolist (token tokens)
            (let ((df (prior-document-frequency store token before-id)))
              (incf commonness (/ (float df) (float (1+ df))))))
          (let ((rarity (- 1.0 (/ commonness (float (length tokens))))))
            (max 0.0 (min 1.0 rarity)))))))

(defun arousal-proxy (body)
  "Return a bounded lexical arousal proxy in 0..1 from emphasis, negation, and
correction markers. Used only for consolidation priority, never retrieval."
  (let ((markers 0))
    (when (stringp body)
      (incf markers (min 3 (count #\! body)))
      (incf markers (min 3 (count-if #'upper-case-p body)))
      (dolist (word '("must" "urgent" "critical" "never" "always" "failed"
                      "wrong" "incorrect" "instead" "actually" "important"))
        (when (search word (string-downcase body)) (incf markers))))
    (min 1.0 (/ (float markers) 12.0))))

(defun context-key-for (&key project session channel)
  "Format a comma-joined \"project,session,channel\" context key."
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
  "Append an episode to STORE, scrub text fields, upsert its activation row,
and (when DERIVE-P) compute rarity and co-occurrence links. Returns the new
EPISODE, or NIL if CAPTURE-P rejects BODY."
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
  "Map encoding depth (0, 1, 2+) to initial write-time importance (3, 5, 7)."
  (case depth (0 3) (1 5) (t 7)))

(defun link-co-occurrences (store episode-id body ts parameters)
  "Upsert CO_OCCURS links from EPISODE-ID to top :LINK-FANOUT FTS5 matches per
token in BODY, and return the number of link writes."
  (let ((written 0))
    (dolist (token (hint-tokens body))
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
  "Return T when LEFT and RIGHT share subject and relation but differ in object
or polarity."
  (and (string-equal (assertion-subject left) (assertion-subject right))
       (string-equal (assertion-relation left) (assertion-relation right))
       (or (not (string-equal (assertion-object left) (assertion-object right)))
           (/= (assertion-polarity left) (assertion-polarity right)))))

(defun conflict-kind-for (left right)
  "Return conflict kind for LEFT and RIGHT (\"scc\", \"boc\", or \"cpc\"), or
NIL if they do not conflict."
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
  "Return T when half-open validity intervals [VALID-FROM, VALID-TO) of LEFT
and RIGHT overlap (NIL bounds are open; abutting intervals do not overlap)."
  (let ((left-from (or (assertion-valid-from left) 0))
        (left-to (or (assertion-valid-to left) most-positive-fixnum))
        (right-from (or (assertion-valid-from right) 0))
        (right-to (or (assertion-valid-to right) most-positive-fixnum)))
    (and (< left-from right-to) (< right-from left-to))))

(defun update-conditions-hold-p (old new &key change-event-p continuing-evidence-p)
  "Return T when NEW supersedes OLD (update) rather than conflicting (revision).
Requires matching subject/relation, disjoint or later VALID-FROM, CHANGE-EVENT-P,
same provenance or strictly higher authority, and no CONTINUING-EVIDENCE-P."
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
  "Return a one-line audit string classifying OLD vs NEW as update or revision."
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
  "Compare NEW against EXISTING assertions without mutating either.
Returns (values CONFLICTS SUPERSEDED): new CONFLICT records to insert, and old
assertions superseded under the update rule (caller closes via tx_to)."
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
  "Record RESOLUTION on CONFLICT in place when AT-ACTION-P is true; otherwise
return CONFLICT unchanged. Does not modify the referenced assertions."
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
;;;; 14. The Calibrator: pre-retrieval probability estimation per query family.

(defparameter +calibration-features+
  '(:max-score :score-gap :cue-coverage :cue-type-match :conflict-load
    :family-prior :degraded)
  "Model-free pre-retrieval feature keys consumed by the Calibrator.")

(defparameter *calibration-weights*
  (list :max-score 1.6 :score-gap 0.9 :cue-coverage 1.2 :cue-type-match 0.7
        :conflict-load -1.1 :family-prior 0.6 :degraded -0.8 :bias -0.4)
  "Fallback log-odds weights used when a family has too few observations for an
isotonic fit.")

(defun isotonic-fit (points)
  "Fit a non-decreasing step curve of (THRESHOLD . VALUE) breakpoints to
(PREDICTED . OBSERVED) POINTS via pool-adjacent-violators."
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
  "Evaluate step curve CURVE (from ISOTONIC-FIT) at VALUE, clamping outside
the fitted breakpoint range to the endpoint values."
  (if (null curve)
      nil
      (let ((answer (cdr (first curve))))
        (dolist (breakpoint curve answer)
          (if (<= (car breakpoint) value)
              (setf answer (cdr breakpoint))
              (return answer))))))

(defun calibration-features (scored &key (cue-coverage 0.0) (family-prior 0.5)
                                         (degraded-p nil))
  "Extract the Calibrator feature plist from RETRIEVE output SCORED (best first)
along with CUE-COVERAGE, FAMILY-PRIOR, and DEGRADED-P."
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
  "Return predicted retrieval usefulness in 0..1 from FEATURES.
Uses isotonic CURVE when supplied, else the fallback logistic with WEIGHTS."
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
  "Fit an isotonic curve to OBSERVATIONS (plists of :PREDICTED and :OBSERVED),
or return NIL when fewer than MINIMUM observations are present."
  (if (< (length observations) minimum)
      nil
      (isotonic-fit (mapcar (lambda (row)
                              (cons (float (getf row :predicted))
                                    (getf row :observed)))
                            observations))))

(defun gate-action (predicted conflict-load &key (parameters *memory-parameters*)
                                                   (external-available-p t))
  "Route retrieval based on PREDICTED probability and CONFLICT-LOAD:
:RELY (>= rely, no conflicts), :RETRIEVE-MORE (>= search), :SEARCH-EXTERNAL
(any conflict or below search with external channel), or :ABSTAIN."
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
  "Insert one retrieval outcome row (OBSERVED must be 0 or 1) into RETRIEVALS
and return its row id."
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
  "Return T when PROCEDURE meets admission criteria: subtask granularity, >= 2
distinct tasks, >= 3 evidence count, failures < evidence, and in-process predicate."
  (and (string-equal (getf procedure :granularity) "subtask")
       (>= (or (getf procedure :distinct-tasks) 0) 2)
       (>= (or (getf procedure :evidence-count) 0) 3)
       (< (or (getf procedure :failures) 0)
          (or (getf procedure :evidence-count) 0))
       (getf procedure :applicable-when)
       (getf procedure :in-process-p)))

(defun procedure-eligible-p (procedure state)
  "STUB: return T when PROCEDURE's in-process precondition holds in STATE.
Always returns NIL until the precondition evaluation sandbox is implemented."
  (declare (ignore procedure state))
  nil)

;;;; ---------------------------------------------------------------------
;;;; 16. Derivation helpers.

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
  "Token counter bound to 0 by BUILD-CANDIDATE; model-backed derivers add
billed tokens here for the cost gate.")

(defparameter *assertion-deriver* nil
  "Function (STORE EPISODE) -> (values ASSERTIONS CHANGE-EVENTS), or NIL when
no deriver is installed (builder must not watermark un-derived episodes).")

(defun assertions-for-episode (store episode)
  "Derive (values ASSERTIONS CHANGE-EVENTS) from EPISODE via *ASSERTION-DERIVER*,
or (values NIL NIL) when NIL. Derivers must attach episode-id, character span,
provenance, authority, and run-id."
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
