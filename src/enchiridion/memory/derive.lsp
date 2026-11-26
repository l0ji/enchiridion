;;;; derive.lsp --- Model-dependent assertion deriver and reranker.
;;;; Implements *ASSERTION-DERIVER* (JSON extraction with span checks) and optional reranking.

(in-package #:enchiridion.memory)

(defparameter +assertion-parser-brief+
  "You extract factual assertions from one episodic record. Answer with a JSON array only. Each element has subject, relation, object, polarity (1 or 0), span_start, span_end, valid_from and valid_to. The span is a character range in the record that contains the evidence for the assertion. Use null for an unknown valid_from or valid_to. If the record contains no factual assertion, answer []. You may also be given the turn before the record: use it only to understand what the record refers to, for example to name the subject an answer is about. Every span must point into the record, never into the earlier turn."
  "The parser's only persona. It is a data task, not a conversation.")

(defun json-object-field (object key &optional default)
  "Return KEY from a parsed JSON OBJECT, or DEFAULT.
PARSE-JSON normalises objects to plists with keyword keys; the hash-table
branch covers a caller that hands over jzon's own shape."
  (cond
    ((hash-table-p object) (gethash key object default))
    ((listp object)
     (getf object (intern (string-upcase key) :keyword) default))
    (t default)))

(defun json-array-as-list (value)
  "Return a parsed JSON array as a list, or NIL for anything else."
  (cond
    ((null value) nil)
    ((vectorp value) (coerce value 'list))
    ((listp value) value)
    (t nil)))

(defun strip-json-fence (text)
  "Return TEXT with a markdown code fence removed when one is present."
  (let* ((trimmed (string-trim '(#\Space #\Tab #\Newline #\Return) text))
         (open (search "```" trimmed)))
    (if open
        (let* ((after (subseq trimmed (+ open 3)))
               (newline (position #\Newline after))
               (body (if newline (subseq after (1+ newline)) after))
               (close (search "```" body)))
          (string-trim '(#\Space #\Tab #\Newline #\Return)
                       (if close (subseq body 0 close) body)))
        trimmed)))

(defun json-array-text-p (text)
  "Return T when TEXT looks like a JSON array after fence removal."
  (let ((trimmed (strip-json-fence text)))
    (and (plusp (length trimmed))
         (char= (char trimmed 0) #\[))))

(defun parse-assertion-json (text)
  "Parse TEXT as a JSON array of assertion objects, returning NIL on malformed
output instead of signalling."
  (handler-case
      (let ((start (position #\[ text))
            (end (position #\] text :from-end t)))
        (when (and start end (< start end))
          (json-array-as-list
           (enchiridion.llm:parse-json (subseq text start (1+ end))))))
    (error () nil)))

(defun json-integer (value)
  (cond ((integerp value) value)
        ((and (realp value) (= value (floor value))) (floor value))
        (t nil)))

(defun assertion-from-json (object episode)
  "Return one ASSERTION from OBJECT, or NIL when a required field is missing.
The span is required and is clamped only by validation later; a row with no
span is not an assertion."
  (let ((subject (json-object-field object "subject"))
        (relation (json-object-field object "relation"))
        (object-value (json-object-field object "object"))
        (polarity (json-integer (json-object-field object "polarity" 1)))
        (span-start (json-integer (json-object-field object "span_start")))
        (span-end (json-integer (json-object-field object "span_end")))
        (valid-from (json-integer (json-object-field object "valid_from")))
        (valid-to (json-integer (json-object-field object "valid_to"))))
    (when (and (stringp subject) (plusp (length subject))
               (stringp relation) (plusp (length relation))
               (stringp object-value) (plusp (length object-value))
               (integerp span-start) (integerp span-end)
               (< span-start span-end))
      (make-assertion
       :subject subject
       :relation relation
       :object object-value
       :polarity (if (member polarity '(0 1)) polarity 1)
       :episode-id (episode-id episode)
       :span-start span-start
       :span-end span-end
       :valid-from valid-from
       :valid-to valid-to
       :tx-from (get-universal-time)
       :authority (episode-authority episode)
       :authority-basis "parser"
       :provenance (episode-provenance episode)
       :cue-type "semantic"
       :run-id 0))))

(defun assertions-from-model-text (text episode)
  "Return the assertions in TEXT that describe EPISODE."
  (let ((objects (parse-assertion-json text)))
    (loop for object in objects
          for assertion = (assertion-from-json object episode)
          when assertion collect assertion)))

(defparameter +deriver-context-limit+ 600
  "How much of the turn before a record reaches the deriver's prompt.")

(defparameter +deriver-body-limit+ 20000
  "How much of the record itself reaches the deriver's prompt.
The cut is a prefix of the body, and a span is validated against the whole
record.")

(defun deriver-record-text (body)
  "Return BODY cut to the characters the deriver's prompt carries."
  (if (> (length body) +deriver-body-limit+)
      (subseq body 0 +deriver-body-limit+)
      body))

(defun previous-episode-body (store episode)
  "Return the body of the preceding non-sleep, non-memory episode in EPISODE's
session (truncated to +DERIVER-CONTEXT-LIMIT+), or NIL."
  (when store
    (let ((row (first (enchiridion.memory.store:query-rows
                       store
                       "SELECT body FROM episodes
                         WHERE session = ? AND id < ?
                           AND channel <> 'sleep' AND role <> 'memory'
                         ORDER BY id DESC LIMIT 1"
                       (list (episode-session episode) (episode-id episode))))))
      (when row
        (let ((body (enchiridion.memory.store:field row "body")))
          (if (> (length body) +deriver-context-limit+)
              (subseq body 0 +deriver-context-limit+)
              body))))))

(defun make-model-assertion-deriver (backend &key model)
  "Return an assertion deriver calling BACKEND (with optional MODEL).
Records usage to STORE on :t2 and *DERIVATION-TOKENS*; malformed model output
returns NIL rather than signalling."
  (lambda (store episode)
    (let* ((body (episode-body episode))
           (context (previous-episode-body store episode))
           (messages (list (enchiridion.llm:system-message
                            +assertion-parser-brief+)
                           (enchiridion.llm:user-message
                            (format nil "~@[Earlier turn, for context only:~%~A~%~%~]Record. Session ~A, role ~A, channel ~A.~%~A"
                                    context
                                    (episode-session episode)
                                    (episode-role episode)
                                    (episode-channel episode)
                                    (deriver-record-text body)))))
           (completion (enchiridion.llm:complete backend messages :model model)))
      (when *derivation-tokens*
        (incf *derivation-tokens*
              (enchiridion.llm:completion-total-tokens completion)))
      (when store
        (handler-case
            (enchiridion.memory.store:record-usage
             store
             :session (episode-session episode)
             :model (enchiridion.llm:completion-model completion)
             :input (enchiridion.llm:completion-input-tokens completion)
             :output (enchiridion.llm:completion-output-tokens completion)
             :cache-read (enchiridion.llm:completion-cache-read-tokens completion)
             :cache-write (enchiridion.llm:completion-cache-write-tokens completion)
             :channel :t2)
          (error (condition)
            (format *error-output* "~&enchiridion: could not write the T2 usage row: ~A~%"
                    condition))))
      (values (assertions-from-model-text
               (enchiridion.llm:completion-text completion)
               episode)
              nil))))

;;;; Optional cheap-model reranking (falls back to score order on error).

(defparameter +rerank-brief+
  "You rank retrieved records for a question. Each record is numbered. Reply
with the numbers of the records that help answer the question, most helpful
first, separated by commas. Leave out records that do not help. Reply with
numbers only, or with the word none.")

(defun parse-rerank-reply (text count)
  "Return the distinct indices 0..COUNT-1 named in TEXT, in the order given.
The model numbers records from 1."
  (let ((seen '()))
    (dolist (match (cl-ppcre:all-matches-as-strings "\\d+" (or text "")))
      (let ((index (1- (parse-integer match))))
        (when (and (< -1 index count) (not (member index seen)))
          (push index seen))))
    (nreverse seen)))

(defun make-model-reranker (backend &key model (chars 300))
  "Return a reranker calling BACKEND over CHARS-sized cue windows of each body.
Bills token usage to the active retrieval ledger on the :RERANK channel."
  (lambda (cue bodies)
    (let* ((tokens (remove-duplicates (tokenise cue) :test #'string=))
           (listing (with-output-to-string (out)
                      (loop for body in bodies
                            for n from 1
                            do (multiple-value-bind (start end)
                                   (cue-window body tokens chars)
                                 (format out "~D. ~A~%" n
                                         (substitute #\Space #\Newline
                                                     (subseq body start end)))))))
           (completion (enchiridion.llm:complete
                        backend
                        (list (enchiridion.llm:system-message +rerank-brief+)
                              (enchiridion.llm:user-message
                               (format nil "Question: ~A~%~%~A" cue listing)))
                        :model model)))
      (record-memory-usage
       :model (enchiridion.llm:completion-model completion)
       :input (enchiridion.llm:completion-input-tokens completion)
       :output (enchiridion.llm:completion-output-tokens completion)
       :cache-read (enchiridion.llm:completion-cache-read-tokens completion)
       :cache-write (enchiridion.llm:completion-cache-write-tokens completion)
       :channel :rerank)
      (parse-rerank-reply (enchiridion.llm:completion-text completion)
                          (length bodies)))))
