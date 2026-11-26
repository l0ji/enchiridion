;;;; cue.lsp --- Cue retrieval and proactive candidates.

(in-package #:enchiridion.memory)

;; Pack and proactive retrieval limits are configured in settings.lsp

;;;; Schema.

(defun ensure-ext-schema (store)
  "Create the extension's three tables on STORE and return the count run."
  (let ((count 0))
    (dolist (statement +ext-schema+ count)
      (enchiridion.memory.store:exec store statement)
      (incf count))))

;;;; Cue index.

(defun cue-terms (terms)
  "Tokenize TERMS (string or list of strings) via TOKENISE, dropping stop words,
single-char tokens, and duplicates."
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
  "Record co-occurrence of TERMS with KIND/REF in cue_index (one row per triple),
incrementing USES when USED is true."
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
  "Return (KIND . REF) pairs indexed under TERM with at least MIN-USES,
ordered by uses descending then recency."
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
  "Return deduplicated union of CUE-INDEX-FOR across all terms in TERMS."
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
  "Delete cue_index rows unused for OLDER-THAN seconds (default 90 days) and return count."
  (enchiridion.memory.store:exec
   store "DELETE FROM cue_index WHERE last_used < ?" (list (- now older-than))))

;;;; Push channels (T1).

(defun precondition-surfacing (store state &key (limit 4))
  "Return admitted, unretired procedures whose whitespace-separated APPLICABLE_WHEN
terms all appear in STATE (case-insensitive)."
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
                                      (now (get-universal-time))
                                      (generation (live-generation-id store)))
  "Return a bulleted string of the highest-importance live assertions in GENERATION,
capped at CHAR-BUDGET. Never signals."
  (let ((rows (handler-case
                  (enchiridion.memory.store:query-rows
                   store
                   "SELECT a.subject, a.relation, a.object, a.polarity
                      FROM assertions a
                      JOIN activation v ON v.kind = 'assertion' AND v.id = a.id
                     WHERE a.generation_id = ?
                       AND (a.valid_to IS NULL OR a.valid_to > ?)
                     ORDER BY v.imp DESC, a.valid_from DESC
                     LIMIT ?"
                   (list generation now limit))
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
  "Return pending, unexpired intentions whose trigger_expr matches any keyword in STATE
(or is empty, which fires unconditionally)."
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
  "Assemble pushed context for CUE within CHAR-BUDGET in priority order:
cue index, applicable procedures, pending intentions, then learned-state block."
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

(defun assemble-pack (retrieved pushed &key (char-budget *memory-pack-chars*))
  "Concatenate RETRIEVED (never truncated) with PUSHED, capping PUSHED to
*PUSH-MAX-FRACTION* and remaining CHAR-BUDGET."
  (let* ((push-cap (floor (* char-budget *push-max-fraction*)))
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
