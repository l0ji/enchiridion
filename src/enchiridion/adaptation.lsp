;;;; adaptation.lsp --- The bearing that fades, and the preferences it may learn.
;;;;
;;;; A young agent borrows its operator's style and work habits. That is the
;;;; opening posture, not a permanent rule: as substantive memory and
;;;; corroborated experience accumulate, the bearing moves toward the agent's
;;;; own defaults. Elapsed time is not a term. The agent is not told that it is
;;;; being measured, and no tick announces a change.
;;;;
;;;; ADAPT.md is the visible form. It is a normal file in the agent directory,
;;;; so a diff and a revert are the ordinary Git ones. The harness owns the
;;;; bearing line; the maintenance pass may add one preference entry per pass,
;;;; and only with evidence it can name.
;;;;
;;;; This file is prompt guidance. It cannot grant a tool, lift a refusal,
;;;; change a permission, raise a budget, or finish the bootstrap. Those
;;;; bounds are enforced in code and are listed in the operator documentation.

(in-package #:enchiridion.kernel)

;;;; What a pass needs and what it may do.

(defparameter +adaptation-file-name+ "ADAPT.md"
  "The Markdown file the bearing and the learned entries live in.")

(defparameter +adaptation-proposal-name+ "tmp/adaptation.json"
  "Where a maintenance pass leaves one proposal. The directory is ignored by
the agent repository, so a proposal is never a commit.")

(defparameter +adaptation-entry-limit+ 240
  "The most characters one learned entry may hold. A pass that wants to write
an essay is a pass that is rewriting the identity files instead.")

(defparameter +adaptation-min-inferred-evidence+ 3
  "How many separate operator turns an inferred preference needs.
One turn is an incident; several turns are a pattern.")

(defparameter *adaptation-operator-channels* '("cli")
  "Channels whose user turns can be cited as operator evidence. The CLI is the
operator's direct surface. HTTP and Fluxer messages arrive with role user but
are not operator identity by themselves, so they do not authorize a preference
unless an embedding binds their channel here.")

(defparameter +adaptation-memory-full+ 120
  "Substantive turns that count as a full memory for the bearing. Sleep output
and tool rows are excluded, so a chatty harness cannot mature an agent by
talking to itself. Saved memories are excluded too: every saved memory carries
the same owner provenance regardless of who saved it.")

(defparameter +adaptation-experience-full+ 6
  "Corroborated sessions that count as full experience for the bearing.
A session is corroborated when it holds at least two tool results and an
assistant reply, which is the smallest shape of acting and then answering.")

(defparameter +adaptation-evidence-window+ 24
  "How many recent turns the maintenance prompt shows as possible evidence.")

(defparameter +adaptation-evidence-chars+ 240
  "How much of one evidence turn the maintenance prompt shows.")

(defparameter +adaptation-evidence-budget+ 5000
  "The total characters of evidence turns one maintenance prompt may carry.")

(defparameter +adaptation-categories+
  '("style" "workflow" "format" "communication" "priority")
  "The kinds of preference an adaptation may record. A category outside this
list is refused, so a proposal cannot rename itself a permission or a tool
policy and still apply.")

(defparameter +adaptation-forbidden-terms+
  '("permission" "refusal" "refuse" "tool access" "bootstrap" "sandbox"
    "authority" "token budget")
  "Words that name an enforced bound. The list is a guard, not a proof: the
operator still reads the diff, and the code that enforces the bound never reads
ADAPT.md.")

(defparameter +adaptation-bearings+
  '((4/5 . "Use your own defaults. Your memory and corroborated experience are broad enough that the operator's style is context, not a model. Explicit operator instructions still override this line.")
    (3/5 . "Prefer your own judgment where your own experience has confirmed it; borrow the operator's demonstrated style where it has not.")
    (2/5 . "Blend the operator's demonstrated style and work habits with what your own experience has confirmed.")
    (1/5 . "Lean on the operator's demonstrated style and work habits; your own experience is still thin.")
    (0 . "Emulate the operator's demonstrated style and work habits closely. They are the default while your memory and experience are thin."))
  "The bearing line at each maturity band, strongest emulation first in the
list because the loop returns the first threshold the score reaches. The text
is deliberately about behavior and never about the measurement.")

(defparameter +adaptation-note+
  "Guidance only. Tool access, permissions, refusals, budgets, and the bootstrap are enforced in code and do not change here. Explicit operator instructions and OPERATOR.md override this section."
  "The sentence that keeps the block honest. It is part of the prompt and of
ADAPT.md, so neither the model nor the operator has to infer the distinction.")

;;;; Paths and the file view.

(declaim (ftype (function (t) pathname) adaptation-path))
(defun adaptation-path (directory)
  "Return the ADAPT.md path for DIRECTORY."
  (merge-pathnames +adaptation-file-name+ (uiop:ensure-directory-pathname directory)))

(declaim (ftype (function (t) pathname) adaptation-proposal-path))
(defun adaptation-proposal-path (directory)
  "Return the proposal path for DIRECTORY."
  (merge-pathnames +adaptation-proposal-name+
                   (uiop:ensure-directory-pathname directory)))

(defun adaptation-read-file (directory)
  "Return ADAPT.md as text, or NIL when the file is absent."
  (let ((path (adaptation-path directory)))
    (when (probe-file path)
      (uiop:read-file-string path :external-format :utf-8))))

(defun adaptation-write-file (directory text)
  "Write TEXT as ADAPT.md after the block scan and the block limit."
  (enchiridion.memory:scan-block-text :adapt text)
  (let ((limit (enchiridion.memory:default-block-limit :adapt)))
    (when (> (length text) limit)
      (error 'enchiridion.errors:block-overflow
             :label :adapt :current limit :wanted (length text))))
  (enchiridion.memory:write-block-file (adaptation-path directory) text)
  text)

;;;; Maturity. The two terms are deliberately different: memory is what the
;;;; agent has kept, experience is what it has done and had answered.

(defun adaptation-memory-count (store)
  "Return the substantive user and assistant turns in STORE, capped at the full
mark. Sleep output and tool rows do not count, so consolidation cannot age an
agent. Saved memories do not count either: their owner provenance is written by
SAVE-MEMORY for every caller, so it says nothing about the source."
  (if store
      (handler-case
          (let ((row (first (enchiridion.memory.store:query-rows
                             store
                             "SELECT COUNT(*) AS n FROM
                                (SELECT 1 FROM episodes
                                  WHERE channel <> 'sleep'
                                    AND role IN ('user', 'assistant')
                                    AND length(trim(body)) > 0
                                  LIMIT ?)"
                             (list (max 1 +adaptation-memory-full+))))))
            (or (and row (enchiridion.memory.store:field row "n")) 0))
        (error () 0))
    0))

(defun adaptation-experience-count (store)
  "Return corroborated sessions in STORE, capped at the full mark.
A session is corroborated when it holds at least two tool results and an
assistant reply. One tool call is a try; a second in the same conversation is
the experience the answer was formed against."
  (if store
      (handler-case
          (let ((row (first (enchiridion.memory.store:query-rows
                             store
                             "SELECT COUNT(*) AS n FROM
                                (SELECT session FROM episodes
                                  WHERE channel <> 'sleep'
                                    AND role = 'tool'
                                    AND session IN
                                        (SELECT session FROM episodes
                                          WHERE channel <> 'sleep'
                                            AND role = 'assistant')
                                  GROUP BY session
                                  HAVING COUNT(*) >= 2
                                  LIMIT ?)"
                             (list (max 1 +adaptation-experience-full+))))))
            (or (and row (enchiridion.memory.store:field row "n")) 0))
        (error () 0))
    0))

(declaim (ftype (function (t) rational) adaptation-maturity))
(defun adaptation-maturity (store)
  "Return 0 to 1, the smaller of the memory and experience terms.
The smaller term means neither a large transcript nor a busy tool history is
enough on its own. A store with no rows is 0, which is the early bearing."
  (let ((memory (/ (adaptation-memory-count store)
                   (max 1 +adaptation-memory-full+)))
        (experience (/ (adaptation-experience-count store)
                       (max 1 +adaptation-experience-full+))))
    (min 1 memory experience)))

(declaim (ftype (function (rational) string) adaptation-bearing))
(defun adaptation-bearing (maturity)
  "Return the bearing text for MATURITY."
  (or (loop for (threshold . text) in +adaptation-bearings+
            when (>= maturity threshold)
              return text)
      (cdar (last +adaptation-bearings+))))

;;;; The file's small grammar: one header, one bearing line, and one bullet
;;;; per learned entry. That is enough for a diff and too little for a policy
;;;; language.

(defun adaptation-bearing-marker (text)
  "Return the start of a Bearing: line in TEXT, or NIL.
Only a marker at the beginning of a line counts, so a sentence that mentions
the word does not become the bearing."
  (let ((marker (search "Bearing: " text)))
    (when marker
      (when (or (zerop marker)
                (char= (char text (1- marker)) #\Newline))
        marker))))

(defun adaptation-replace-bearing (text bearing)
  "Return TEXT with its Bearing: line replaced by BEARING.
A file without the marker gets one appended, so a hand-edited file keeps
everything else."
  (let* ((line (format nil "Bearing: ~A" bearing))
         (start (adaptation-bearing-marker text)))
    (cond
      (start
       (let ((end (or (position #\Newline text :start start) (length text))))
         (concatenate 'string (subseq text 0 start) line (subseq text end))))
      ((plusp (length text))
       (concatenate 'string text
                    (unless (char= (char text (1- (length text))) #\Newline)
                      (string #\Newline))
                    line
                    (string #\Newline)))
      (t (format nil "# Adaptation~%~%~A~%~%Bearing: ~A~%"
                 +adaptation-note+ bearing)))))

(defun adaptation-template (bearing)
  "Return a fresh ADAPT.md with BEARING."
  (let ((base (or (enchiridion.memory:seed-template "ADAPT.md") "")))
    (if (plusp (length base))
        (adaptation-replace-bearing base bearing)
        (format nil "# Adaptation~%~%~A~%~%Bearing: ~A~%"
                +adaptation-note+ bearing))))

(defun adaptation-entry-line (entry)
  "Return ENTRY, a plist, as one Markdown bullet."
  (let ((evidence (getf entry :evidence)))
    (format nil "- [~A, ~A, ~A] ~A"
            (getf entry :kind)
            (getf entry :category)
            (if (= 1 (length evidence))
                (format nil "turn ~D" (first evidence))
                (format nil "turns ~{~D~^, ~}" evidence))
            (getf entry :text))))

;;;; Evidence and the one proposal.

(defun adaptation-evidence-row (store id)
  "Return the row for turn ID, or NIL.
The query names the columns rather than using RECENT-TURNS, because evidence
may be older than the recent window and is looked up by exact id."
  (when store
    (handler-case
        (first (enchiridion.memory.store:query-rows
                store
                "SELECT id, session, role, body, channel FROM turns WHERE id = ?"
                (list id)))
      (error () nil))))

(defun adaptation-operator-channel-p (channel)
  "Return T when CHANNEL is one this build accepts as operator evidence."
  (and (stringp channel)
       (member (string-downcase channel) *adaptation-operator-channels*
               :test #'string=)))

(defun adaptation-valid-evidence-p (store id)
  "Return T when ID is a user turn from an operator channel.
The role alone is not identity: an HTTP or Fluxer message also arrives as user."
  (let ((row (adaptation-evidence-row store id)))
    (and row
         (string= "user" (enchiridion.memory.store:field row "role"))
         (adaptation-operator-channel-p
          (enchiridion.memory.store:field row "channel")))))

(defun adaptation-evidence-body (store id)
  "Return the body of turn ID, or NIL."
  (let ((row (adaptation-evidence-row store id)))
    (and row (enchiridion.memory.store:field row "body"))))

(defun adaptation-quote-p (store quote evidence)
  "Return T when QUOTE appears in one of EVIDENCE, ignoring case."
  (and (stringp quote)
       (>= (length quote) 8)
       (<= (length quote) 200)
       (not (find #\Newline quote))
       (loop for id in evidence
             for body = (adaptation-evidence-body store id)
             thereis (and body
                          (search (string-downcase quote)
                                  (string-downcase body))))))

(defun adaptation-validate-text (text)
  "Return why TEXT is not a usable entry, or NIL."
  (cond
    ((not (stringp text)) "the text is not a string")
    ((zerop (length (string-trim '(#\Space #\Tab) text))) "the text is empty")
    ((find #\Newline text) "the text must be one line")
    ((> (length text) +adaptation-entry-limit+)
     (format nil "the text is longer than ~D characters" +adaptation-entry-limit+))
    (t
     (let ((lower (string-downcase text)))
       (loop for term in +adaptation-forbidden-terms+
             when (search term lower)
               return (format nil "the text names an enforced bound (~A)" term))))))

(defun adaptation-validate-proposal (store proposal)
  "Return two values: the normalized entry, or NIL and the reason.
The checks are structural. They can prove that a named turn says the quoted
words and that an inferred preference has three separate operator turns. They
cannot prove that the model inferred the right preference, which is why the
operator gets a diff and a revert."
  (let* ((kind (string-downcase (string (getf proposal :kind))))
         (category (string-downcase (string (getf proposal :category))))
         (text (and (stringp (getf proposal :text))
                    (string-trim '(#\Space #\Tab) (getf proposal :text))))
         (evidence (getf proposal :evidence))
         (quote (getf proposal :quote)))
    (cond
      ((not (member kind '("explicit" "inferred") :test #'string=))
       (values nil "the kind is neither explicit nor inferred"))
      ((not (member category +adaptation-categories+ :test #'string=))
       (values nil (format nil "the category ~A is outside the allowed list" category)))
      ((adaptation-validate-text text))
      ((not (and (listp evidence) (every #'integerp evidence)))
       (values nil "the evidence is not a list of turn ids"))
      ((not (= (length evidence) (length (remove-duplicates evidence))))
       (values nil "the evidence repeats a turn id"))
      ((not (every (lambda (id) (adaptation-valid-evidence-p store id)) evidence))
       (values nil "the evidence names a turn that is not an operator turn"))
      ((and (string= kind "explicit")
            (< (length evidence) 1))
       (values nil "an explicit correction needs the operator turn"))
      ((and (string= kind "inferred")
            (< (length evidence) +adaptation-min-inferred-evidence+))
       (values nil (format nil "an inferred preference needs ~D separate operator turns"
                           +adaptation-min-inferred-evidence+)))
      ((and (string= kind "explicit")
            (not (adaptation-quote-p store quote evidence)))
       (values nil "an explicit correction needs a quote found in the cited turn"))
      ((and quote (not (adaptation-quote-p store quote evidence)))
       (values nil "the quote does not occur in the cited evidence"))
      (t
       (values (list :kind kind
                     :category category
                     :text text
                     :evidence (sort (copy-list evidence) #'<)
                     :quote quote)
               nil)))))

(defun adaptation-json-field (object key)
  "Return KEY from OBJECT, a jzon hash table, or NIL."
  (and (hash-table-p object) (gethash key object)))

(defun adaptation-json-evidence (value)
  "Return VALUE, a JSON array, as a list of integers, or NIL."
  (when (vectorp value)
    (let ((items (coerce value 'list)))
      (when (every #'integerp items) items))))

(defun adaptation-proposal-from-text (text)
  "Return a proposal plist from JSON TEXT, or NIL and the reason."
  (handler-case
      (let ((object (com.inuoe.jzon:parse text)))
        (unless (hash-table-p object)
          (return-from adaptation-proposal-from-text
            (values nil "the proposal is not a JSON object")))
        (let ((entries (adaptation-json-field object "entries")))
          (when (and entries (vectorp entries) (> (length entries) 1))
            (return-from adaptation-proposal-from-text
              (values nil "one pass may change one thing"))))
        (values (list :kind (adaptation-json-field object "kind")
                      :category (adaptation-json-field object "category")
                      :text (adaptation-json-field object "text")
                      :evidence (adaptation-json-evidence
                                 (adaptation-json-field object "evidence"))
                      :quote (adaptation-json-field object "quote"))
                nil))
    (error (condition)
      (values nil (enchiridion.errors:condition-report-line condition)))))

(defun adaptation-read-proposal (directory)
  "Return the proposal in DIRECTORY, or two values NIL and the reason.
A missing file is a no-op, not an error."
  (let ((path (adaptation-proposal-path directory)))
    (if (probe-file path)
        (handler-case
            (let ((text (uiop:read-file-string path :external-format :utf-8)))
              (if (> (length text) 8192)
                  (values nil "the proposal is larger than 8192 characters")
                  (adaptation-proposal-from-text text)))
          (error (condition)
            (values nil (enchiridion.errors:condition-report-line condition))))
        (values nil nil))))

;;;; Recording and applying.

(defun adaptation-record (store entry before after)
  "Record ENTRY and its file BEFORE and AFTER, and return the row id."
  (enchiridion.memory.store:exec
   store
   "INSERT INTO adaptations
      (kind, category, text, evidence, before_text, after_text, ts)
      VALUES (?, ?, ?, ?, ?, ?, ?)"
   (list (getf entry :kind)
         (getf entry :category)
         (getf entry :text)
         (format nil "~{~D~^, ~}" (getf entry :evidence))
         before
         after
         (get-universal-time)))
  (enchiridion.memory.store:last-row-id store))

(defun adaptation-record-bearing (store bearing evidence before after)
  "Record one bearing change and the counts that caused it, and return its id."
  (enchiridion.memory.store:exec
   store
   "INSERT INTO adaptations
      (kind, category, text, evidence, before_text, after_text, ts)
      VALUES ('bearing', '', ?, ?, ?, ?, ?)"
   (list bearing evidence (or before "") (or after "") (get-universal-time)))
  (enchiridion.memory.store:last-row-id store))

(defun adaptation-commit (directory message)
  "Commit DIRECTORY when it is a repository, and never signal."
  (when directory
    (handler-case
        (when (enchiridion.git:repository-p directory)
          (enchiridion.git:git-commit-all directory message))
      (error () nil))))

(defun adaptation-rows (store &key (limit 20))
  "Return the newest adaptation rows, or NIL when no store is open."
  (when store
    (handler-case
        (enchiridion.memory.store:query-rows
         store
         "SELECT id, kind, category, text, evidence, before_text, after_text,
                 ts, reverted_p
            FROM adaptations ORDER BY id DESC LIMIT ?"
         (list limit))
      (error () nil))))

(defun adaptation-row (store id)
  "Return the adaptation row ID, or NIL."
  (when store
    (handler-case
        (first (enchiridion.memory.store:query-rows
                store
                "SELECT id, kind, category, text, evidence, before_text, after_text,
                        ts, reverted_p
                   FROM adaptations WHERE id = ?"
                (list id)))
      (error () nil))))

(defun adaptation-append (directory entry)
  "Append ENTRY to ADAPT.md and return two values, the old and the new text."
  (let* ((before (or (adaptation-read-file directory) ""))
         (base (if (plusp (length before))
                   before
                   (adaptation-template (adaptation-bearing 0))))
         (separator (if (and (plusp (length base))
                             (char= (char base (1- (length base))) #\Newline))
                        ""
                        (string #\Newline)))
         (after (concatenate 'string base separator
                             (adaptation-entry-line entry) (string #\Newline))))
    (adaptation-write-file directory after)
    (values before after)))

(declaim (ftype (function (t t list) list) adaptation-apply-proposal))
(defun adaptation-apply-proposal (store directory proposal)
  "Validate and apply one proposal, and return a plist describing the result.
The file is written before the row, so a database failure can put the old text
back. A commit failure is silent, because a host without a Git identity must
not lose the change."
  (multiple-value-bind (entry reason) (adaptation-validate-proposal store proposal)
    (if (null entry)
        (list :status :refused :reason reason)
        (handler-case
            (multiple-value-bind (before after)
                (adaptation-append directory entry)
              (handler-case
                  (let ((id (adaptation-record store entry before after)))
                    (adaptation-commit
                     directory
                     (format nil "Adaptation from turn~P ~{~D~^, ~}"
                             (length (getf entry :evidence))
                             (getf entry :evidence)))
                    (list :status :applied
                          :id id
                          :kind (getf entry :kind)
                          :category (getf entry :category)
                          :text (getf entry :text)
                          :evidence (getf entry :evidence)))
                (error (condition)
                  ;; The file moved and the row did not. Put the file back:
                  ;; a change no row can explain is worse than no change.
                  (ignore-errors (adaptation-write-file directory before))
                  (list :status :refused
                        :reason (enchiridion.errors:condition-report-line condition)))))
          (error (condition)
            (list :status :refused
                  :reason (enchiridion.errors:condition-report-line condition)))))))

;;;; One pass.

(defstruct (adaptation-pass (:constructor %make-adaptation-pass))
  (directory nil)
  (before nil)
  (expected nil)
  (bearing "")
  (evidence "")
  (changed-p nil)
  (problem nil))

(defun adaptation-begin (agent store)
  "Prepare ADAPT.md for one maintenance pass and return an ADAPTATION-PASS.
The bearing is updated before the turn, so the pass reads the posture it is
about to act under, and the ordinary turn commit records the change."
  (let* ((directory (and agent (agent-directory agent)))
         (before (and directory (adaptation-read-file directory)))
         (memory (adaptation-memory-count store))
         (experience (adaptation-experience-count store))
         (maturity (min 1
                        (/ memory (max 1 +adaptation-memory-full+))
                        (/ experience (max 1 +adaptation-experience-full+))))
         (bearing (adaptation-bearing maturity))
         (evidence (format nil "memory ~D of ~D, experience ~D of ~D"
                           memory (max 1 +adaptation-memory-full+)
                           experience (max 1 +adaptation-experience-full+)))
         (state (%make-adaptation-pass :directory directory
                                       :before before
                                       :expected before
                                       :bearing bearing
                                       :evidence evidence)))
    (when directory
      (ignore-errors (delete-file (adaptation-proposal-path directory)))
      (handler-case
          (let* ((current (or before (adaptation-template bearing)))
                 (updated (adaptation-replace-bearing current bearing)))
            (when (or (null before) (not (string= updated current)))
              (adaptation-write-file directory updated)
              (setf (adaptation-pass-changed-p state) t
                    (adaptation-pass-expected state) updated)))
        (error (condition)
          (setf (adaptation-pass-problem state)
                (enchiridion.errors:condition-report-line condition)
                (adaptation-pass-changed-p state) nil
                (adaptation-pass-expected state) before))))
    state))

(defun adaptation-restore (state)
  "Put ADAPT.md back as it was before STATE's pass."
  (let ((directory (adaptation-pass-directory state)))
    (when directory
      (handler-case
          (if (adaptation-pass-before state)
              (adaptation-write-file directory (adaptation-pass-before state))
              (ignore-errors (delete-file (adaptation-path directory))))
        (error () nil)))))

(defun adaptation-direct-change-p (state)
  "Return T when ADAPT.md changed without the harness. The model writing the
file directly is reverted, because the evidence checks live on the proposal
path and a direct write has not passed them."
  (let ((directory (adaptation-pass-directory state)))
    (and directory
         (not (string= (or (adaptation-read-file directory) "")
                       (or (adaptation-pass-expected state) ""))))))

(declaim (ftype (function (t t &key (:success-p t)) list) adaptation-finish))
(defun adaptation-finish (state store &key (success-p t))
  "Close one maintenance pass and return a plist for the internal report.
The status is never printed. It exists for tests and for an operator who asks
the code directly; a heartbeat says only that a maintenance pass ran."
  (let ((directory (and state (adaptation-pass-directory state))))
    (cond
      ((null directory)
       (list :status :disabled))
      ((not success-p)
       (adaptation-restore state)
       (ignore-errors (delete-file (adaptation-proposal-path directory)))
       (list :status :failed
             :problem (adaptation-pass-problem state)))
      ((adaptation-direct-change-p state)
       ;; A direct write skipped the evidence checks, so it is put back even
       ;; when the bearing moved in the same pass. The turn may already have
       ;; committed it, so the restore is committed too.
       (adaptation-restore state)
       (adaptation-commit directory "Revert a direct adaptation write")
       (ignore-errors (delete-file (adaptation-proposal-path directory)))
       (list :status :direct-reverted))
      ((adaptation-pass-changed-p state)
       ;; The bearing moved, so it is the one change this pass gets. A
       ;; proposal waits for a pass that did not already change the file.
       (ignore-errors
         (adaptation-record-bearing store
                                    (adaptation-pass-bearing state)
                                    (adaptation-pass-evidence state)
                                    (adaptation-pass-before state)
                                    (adaptation-pass-expected state)))
       (ignore-errors (delete-file (adaptation-proposal-path directory)))
       (list :status :bearing
             :bearing (adaptation-pass-bearing state)))
      (t
       (multiple-value-bind (proposal reason)
           (adaptation-read-proposal directory)
         (cond
           ((null proposal)
            (if reason
                (list :status :refused :reason reason)
                (list :status :none)))
           (t
            (let ((result (adaptation-apply-proposal store directory proposal)))
              (ignore-errors (delete-file (adaptation-proposal-path directory)))
              result))))))))

;;;; The maintenance prompt. This is the only model call the feature uses, and
;;;; it is the pass that already ran.

(defun adaptation-evidence-text (store)
  "Return the recent turns as evidence lines, oldest first, bounded by count
and characters. Tool rows are omitted: a tool result is not an operator
correction and does not belong in a correction's citation."
  (when store
    (let ((rows (handler-case
                    (enchiridion.memory.store:recent-turns
                     store :limit +adaptation-evidence-window+
                     :not-channel :sleep :body-chars +adaptation-evidence-chars+)
                  (error () nil)))
          (lines '())
          (used 0))
      (dolist (row (reverse rows))
        (when (and (string= "user" (enchiridion.memory.store:turn-row-role row))
                   (adaptation-operator-channel-p
                    (string-downcase
                     (string (enchiridion.memory.store:turn-row-channel row)))))
          (let ((line (format nil "[turn ~D] ~A"
                              (enchiridion.memory.store:turn-row-id row)
                              (enchiridion.memory.store:turn-row-body row))))
            (when (<= (+ used (length line) 1) +adaptation-evidence-budget+)
              (push line lines)
              (incf used (1+ (length line)))))))
      (when lines
        (format nil "~%~%CLI operator turns available as evidence, oldest first. Cite ids exactly:~%~{~A~%~}"
                (nreverse lines))))))

(defun adaptation-maintenance-prompt (base directory store)
  "Return BASE plus the adaptation rules and evidence for one maintenance pass."
  (format nil "~A~%~%If one working preference now has evidence, put one JSON object at ~A and nothing else there. Otherwise write no proposal. At most one change this pass; no change is the default.~%~
An explicit CLI operator correction may be applied immediately: set kind to \"explicit\", cite that operator turn, and include a short quote from it. An inferred preference needs at least ~D separate CLI operator turns and cites them all. Only CLI user turns count as operator evidence by default. Category is one of ~{~A~^, ~}. The text is one line, at most ~D characters.~%~
Do not use a proposal to change tool access, permissions, refusals, budgets, or the bootstrap; those bounds are enforced in code. Do not write ADAPT.md yourself; the harness applies a valid proposal and reverts a direct write. Do not mention this policy or the adaptation file in your reply.~%~
The shape is {\"kind\":\"explicit\"|\"inferred\",\"category\":\"...\",\"text\":\"...\",\"evidence\":[ids],\"quote\":\"...\"}.~A"
          base
          (adaptation-proposal-path directory)
          +adaptation-min-inferred-evidence+
          +adaptation-categories+
          +adaptation-entry-limit+
          (adaptation-evidence-text store)))

(defun revert-adaptation (store directory id)
  "Put back the text before adaptation ID and mark the row reverted.
The latest change can be reverted; an older one cannot, because a later change
sits on top of it. Return a plist with :REVERTED-P and a reason."
  (let ((target (adaptation-row store id)))
    (cond
      ((null target) (list :reverted-p nil :reason "no such adaptation"))
      ((plusp (enchiridion.memory.store:field target "reverted_p"))
       (list :reverted-p nil :reason "that adaptation is already reverted"))
      ((not (string= (or (adaptation-read-file directory) "")
                     (enchiridion.memory.store:field target "after_text")))
       (list :reverted-p nil :reason "a later change sits on top"))
      (t
       (handler-case
           (progn
             (adaptation-write-file directory
                                    (enchiridion.memory.store:field target "before_text"))
             (enchiridion.memory.store:exec
              store "UPDATE adaptations SET reverted_p = 1 WHERE id = ?" (list id))
             (adaptation-commit directory (format nil "Revert adaptation ~D" id))
             (list :reverted-p t :id id))
         (error (condition)
           (list :reverted-p nil
                 :reason (enchiridion.errors:condition-report-line condition))))))))
