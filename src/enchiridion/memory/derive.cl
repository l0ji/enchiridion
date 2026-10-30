;;;; derive.cl --- The model-dependent assertion parser seam.
;;;;
;;;; The builder calls *ASSERTION-DERIVER*. This file provides one deriver:
;;;; a cheap-model call that asks for a strict JSON array of assertions and
;;;; refuses every row without a usable span. It is not wired into a turn or a
;;;; heartbeat phase; a later phase installs it on the T2 path.
;;;;
;;;; The parser is deliberately boring. The interesting properties are the
;;;; caller's: off the reply path, idempotent, every row carrying a span and the
;;;; episode's provenance, and a second pass over the same episode inserting
;;;; nothing.

(in-package #:enchiridion.memory)

(defparameter +assertion-parser-brief+
  "You extract factual assertions from one episodic record. Answer with a JSON array only. Each element has subject, relation, object, polarity (1 or 0), span_start, span_end, valid_from and valid_to. The span is a character range in the record that contains the evidence for the assertion. Use null for an unknown valid_from or valid_to. If the record contains no factual assertion, answer []."
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
  "Parse TEXT, a JSON array of assertion objects, and return a list of objects.
A malformed response returns NIL rather than signalling: one bad model answer
must not take the builder down. The caller counts the empty result as a
quarantined candidate if it needs to."
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

(defun make-model-assertion-deriver (backend &key model)
  "Return a deriver that asks BACKEND to turn one episode into assertions.
The call is off the interactive path. A malformed response yields no
assertions, not a signal, so one bad answer cannot take the builder down."
  (lambda (store episode)
    (declare (ignore store))
    (let* ((body (episode-body episode))
           (messages (list (enchiridion.llm:system-message
                            +assertion-parser-brief+)
                           (enchiridion.llm:user-message
                            (format nil "Session ~A, role ~A, channel ~A.~%~A"
                                    (episode-session episode)
                                    (episode-role episode)
                                    (episode-channel episode)
                                    body))))
           (completion (enchiridion.llm:complete backend messages :model model)))
      (values (assertions-from-model-text
               (enchiridion.llm:completion-text completion)
               episode)
              nil))))
