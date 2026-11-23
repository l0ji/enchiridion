;;;; canaries.lsp --- Retrieval checks and operator approvals.

(in-package #:enchiridion.memory)

;;;; ------------------------------------------------------------------
;;;; 4. The canary set (store 12)
;;;; ------------------------------------------------------------------

(defun register-canary (store name expect &key (family "") (now (get-universal-time)))
  "Add or replace a named behavioral canary."
  (enchiridion.memory.store:exec
   store
   "INSERT INTO canary (name, expect, family, ts) VALUES (?, ?, ?, ?)
    ON CONFLICT(name) DO UPDATE SET expect = ?, family = ?, ts = ?"
   (list name expect family now expect family now)))

(defparameter +canary-families+ '("retrieval" "update" "safety" "tail")
  "The canary families required for promotion.")

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
A canary removed from the configuration is removed here too."
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

(defun canary-behaviour-p (store canary generation &key require-hit-p)
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
           (and (or (not require-hit-p) rows) (null (rank expect))))
          ((string= family "update")
           (let ((new (rank expect)) (old (rank (getf canary :stale))))
             (and new (or (null old) (< new old)))))
          (t (error "~A is not a canary family." family)))))))

(defparameter +canary-fixture-bodies+
  '("The velarium map is in the copper cabinet."
    "The current torvane dispatch address is the blue annex."
    "The torvane office used to be at the red annex."
    "The cerulite inventory lists three glass jars."
    "The serradine lock uses the violet passphrase."
    "The quenvora shipment contains a paper sextant.")
  "Transient records for the shipped canaries.")

(defun built-in-canary-outcomes (store canaries generation)
  "Check the shipped cues against GENERATION without retaining fixture rows."
  (let ((checks (intersection canaries +built-in-canaries+ :test #'equal)))
    (when checks
      (let ((*memory-embedder* nil))
        (enchiridion.memory.store:with-store-transaction (store)
          (dolist (body +canary-fixture-bodies+)
            (enchiridion.memory.store:record-turn store :session "t2-canary"
                                                 :role "user" :body body))
          ;; The nonlocal return rolls the transaction back, including FTS and activation
          (return-from built-in-canary-outcomes
            (loop for canary in checks
                  collect (cons (getf canary :name)
                                (and (canary-behaviour-p store canary generation)
                                     (or (not (equal "safety" (getf canary :family)))
                                         (canary-behaviour-p
                                          store
                                          '(:family "retrieval" :cue "cerulite inventory"
                                            :expect "three glass jars")
                                          generation)))))))))))

(declaim (ftype (function (t t t) t) proposal-check-p))

(defun canary-predicate (store canaries generation)
  "Return the CANARY-CHECK predicate that checks each of CANARIES against a
retrieval reading GENERATION. A canary the table holds but CANARIES does not
name fails, because a check with nothing to run must not pass."
  (let ((built-in (built-in-canary-outcomes store canaries generation)))
    (lambda (name expect)
      (declare (ignore expect))
      (let ((result (assoc name built-in :test #'equal))
            (canary (find name canaries :key (lambda (c) (getf c :name)) :test #'equal)))
        (cond (result (cdr result))
              ((and canary (valid-canary-p canary))
               (if (getf canary :episode)
                   (proposal-check-p store canary generation)
                   (canary-behaviour-p store canary generation))))))))

(defun canary-check (store &key predicate (checks nil checks-p) (now (get-universal-time)))
  "Run PREDICATE on CHECKS, or on stored canaries when CHECKS is omitted."
  (let ((rows (if checks-p
                  (remove-if-not #'valid-canary-p checks)
                  (enchiridion.memory.store:query-rows
                   store "SELECT name, expect FROM canary ORDER BY id")))
        (passed 0) (failed 0) (unchecked 0) (failures '()))
    (dolist (row rows)
      (let* ((name (getf row :name))
             (ok (if predicate
                     (handler-case (not (null (funcall predicate name (getf row :expect))))
                       (error () nil))
                     :unchecked)))
        (cond ((eq ok :unchecked) (incf unchecked))
              (ok (incf passed)
                  (enchiridion.memory.store:exec
                   store "UPDATE canary SET last_pass = ?, last_checked = ? WHERE name = ?"
                   (list now now name)))
              (t (incf failed) (push name failures)
                 (enchiridion.memory.store:exec
                  store "UPDATE canary SET last_checked = ? WHERE name = ?"
                  (list now name))))))
    (list :ok-p (and predicate (zerop failed))
          :passed passed :failed failed :unchecked unchecked
          :failures (nreverse failures) :total (length rows))))

(defun canary-report (result)
  "Return a one-line report for RESULT, as SUPERVISOR-TICK expects."
  (format nil "canary: ~D pass, ~D fail, ~D unchecked of ~D"
          (getf result :passed) (getf result :failed)
          (getf result :unchecked) (getf result :total)))

(defconstant +canary-proposal-limit+ 32)
(defconstant +canary-field-limit+ 200)

(defun canary-input-error (detail)
  (error 'enchiridion.errors:schema-error :detail detail))

(defun proposal-field-p (value)
  (and (stringp value) (<= 1 (length value) +canary-field-limit+)
       (find-if (lambda (ch) (not (char= ch #\Space))) value)
       (every (lambda (ch) (and (graphic-char-p ch)
                                (not (member (char-code ch) '(8232 8233)))))
              value)
       (string= value (enchiridion.llm.secrets:scrub value))))

(defun canary-digest (family cue expect stale episode)
  (ironclad:byte-array-to-hex-string
   (ironclad:digest-sequence
    :sha256 (sb-ext:string-to-octets
             (with-standard-io-syntax
               (prin1-to-string (list family cue expect stale episode)))
             :external-format :utf-8))))

(defun canary-id-p (id)
  (and (stringp id) (= 64 (length id))
       (every (lambda (ch) (find ch "0123456789abcdef")) id)))

(defun proposed-canary (family cue expect stale episode)
  "Validate the fields and return the content-addressed check."
  (unless (and (member family +canary-families+ :test #'equal)
               (proposal-field-p cue) (tokenise cue) (proposal-field-p expect)
               (if (equal family "update")
                   (and (proposal-field-p stale) (not (string-equal stale expect)))
                   (null stale))
               (typep episode '(integer 1 #x7fffffffffffffff)))
    (canary-input-error "Supply a supported family, single-line cue and expect, and a positive episode ID. Only update takes a distinct stale value."))
  (list :name (canary-digest family cue expect stale episode)
        :family family :cue cue :expect expect :stale stale :episode episode))

(defun canary-evidence-p (store check)
  (not (null (enchiridion.memory.store:query-rows
              store "SELECT id FROM episodes WHERE id = ? AND instr(body, ?) > 0"
              (list (getf check :episode) (getf check :expect))))))

(defun propose-canary (store family cue expect episode &key stale)
  "Queue a shadow canary and return its fingerprint."
  (let* ((check (proposed-canary family cue expect stale episode))
         (id (getf check :name)))
    (enchiridion.memory.store:with-store-transaction (store)
      (unless (canary-evidence-p store check)
        (canary-input-error "The cited episode must contain the expected text verbatim."))
      (unless (enchiridion.memory.store:query-rows
               store "SELECT id FROM canary_proposals WHERE id = ?" (list id))
        (when (enchiridion.memory.store:query-rows
               store "SELECT 1 FROM canary_proposals LIMIT 1 OFFSET ?"
               (list (1- +canary-proposal-limit+)))
          (canary-input-error "The shadow queue is full. An operator can discard a proposal."))
        (enchiridion.memory.store:exec
         store "INSERT INTO canary_proposals (id, family, cue, expect, stale, episode)
                VALUES (?, ?, ?, ?, ?, ?)"
         (list id family cue expect stale episode))))
    id))

(defun canary-proposals (store &optional id)
  "Return validated shadow checks, optionally restricted to ID."
  (when (and id (not (canary-id-p id)))
    (canary-input-error "Use the full proposal fingerprint from memory canaries."))
  (loop for row in (enchiridion.memory.store:query-rows
                    store
                    "SELECT id, family, cue, expect, stale, episode FROM canary_proposals
                      WHERE length(id) = 64 AND length(family) <= 9 AND length(cue) <= ?
                        AND length(expect) <= ? AND COALESCE(length(stale), 0) <= ?
                        AND (? IS NULL OR id = ?) ORDER BY id LIMIT ?"
                    (list +canary-field-limit+ +canary-field-limit+ +canary-field-limit+
                          id id +canary-proposal-limit+))
        for check = (handler-case
                        (apply #'proposed-canary
                               (mapcar (lambda (key) (enchiridion.memory.store:field row key))
                                       '("family" "cue" "expect" "stale" "episode")))
                      (enchiridion.errors:schema-error () nil))
        when (and check (equal (getf check :name) (enchiridion.memory.store:field row "id")))
          collect check))

(defun discard-canary (store id)
  "Remove the shadow proposal, without changing any approved check."
  (unless (canary-id-p id)
    (canary-input-error "Use the full proposal fingerprint from memory canaries."))
  (enchiridion.memory.store:exec store "DELETE FROM canary_proposals WHERE id = ?" (list id)))

(defun proposal-check-p (store check generation)
  "Run a proposal against a generation without calling a provider."
  (let ((*memory-embedder* nil))
    (canary-behaviour-p store check generation :require-hit-p t)))

(defvar *canary-approval-directory* nil)

(defun canary-approval-directory ()
  (or *canary-approval-directory*
      (let ((config enchiridion:*config-source*))
        (when (pathnamep config)
          (merge-pathnames "canary-approvals/" (uiop:pathname-directory-pathname config))))))

(defun checked-approval-path (path)
  (if (zerop (enchiridion.compat:process-uid))
      (enchiridion::check-root-config-path path)
      path))

(defun read-approved-canary (path)
  (with-open-file (stream (checked-approval-path path) :external-format :utf-8)
    (unless (<= (file-length stream) 4096)
      (canary-input-error "A canary approval file exceeds 4096 bytes."))
    (with-standard-io-syntax
      (let* ((*read-eval* nil)
             (data (read stream nil nil))
             (check (and (alexandria:proper-list-p data) (= 5 (length data))
                         (apply #'proposed-canary data))))
        (unless (and check (equal (pathname-name path) (getf check :name))
                     (eq :eof (read stream nil :eof)))
          (canary-input-error "A canary approval does not match its fingerprint."))
        check))))

(defun approved-canaries ()
  "Return the operator's blocking snapshots, separate from the agent's store."
  (let ((directory (canary-approval-directory)))
    (when (and directory (probe-file directory))
      (let ((paths (uiop:directory-files (checked-approval-path directory) "*.lsp")))
        (when (> (length paths) +canary-proposal-limit+)
          (canary-input-error "Too many approved canaries. Revoke one before adding another."))
        (loop for path in paths collect
          (flet ((refuse (&optional detail)
                   (canary-input-error
                    (format nil "Cannot read approval ~A.~@[ ~A~] Remove or restore it before running T2."
                            path detail))))
            (handler-case (read-approved-canary path)
              (enchiridion.errors:enchiridion-error (condition)
                (refuse (enchiridion.errors:condition-report-line condition)))
              (error () (refuse)))))))))

(defun canary-approval-path (id)
  (unless (canary-id-p id)
    (canary-input-error "Use the full proposal fingerprint from memory canaries."))
  (let ((directory (or (canary-approval-directory)
                       (canary-input-error "Operator canary approval requires a config file."))))
    (merge-pathnames (make-pathname :name id :type "lsp") directory)))

(defun approve-canary (store id)
  "Snapshot the reviewed proposal as a blocking check after a live baseline pass."
  (let* ((path (canary-approval-path id))
         (check (first (canary-proposals store id))))
    (unless (and check (canary-evidence-p store check))
      (canary-input-error "No matching proposal with its supporting episode."))
    (unless (proposal-check-p store check :live)
      (canary-input-error "The proposal fails against live retrieval and remains in shadow mode."))
    (let ((approved (approved-canaries)))
      (when (find id approved :key (lambda (row) (getf row :name)) :test #'equal)
        (return-from approve-canary id))
      (when (>= (length approved) +canary-proposal-limit+)
        (canary-input-error "The approved list is full. Revoke a check first."))
      (ensure-directories-exist path)
      (checked-approval-path (uiop:pathname-directory-pathname path))
      (uiop:with-temporary-file (:stream stream :pathname temporary
                                 :directory (uiop:pathname-directory-pathname path)
                                 :type "tmp" :external-format :utf-8)
        (with-standard-io-syntax
          (write (mapcar (lambda (key) (getf check key)) '(:family :cue :expect :stale :episode))
                 :stream stream :readably t))
        (close stream)
        (enchiridion.compat:set-file-mode temporary #o600)
        (uiop:rename-file-overwriting-target temporary path)))
    id))

(defun revoke-canary (id)
  "Remove the operator snapshot, returning the proposal to shadow if it still exists."
  (let ((path (canary-approval-path id)))
    (when (probe-file path)
      (checked-approval-path path)
      (delete-file path)
      t)))
