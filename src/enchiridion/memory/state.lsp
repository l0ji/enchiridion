;;;; state.lsp --- state.json persistence, generation counter, and bootstrap record.
;;;;
;;;; Uses jzon's native representation: EQUAL hash tables with string keys,
;;;; vectors for JSON arrays, and NIL for false.

(in-package #:enchiridion.memory)

;;;; Paths.

(declaim (ftype (function (t) pathname) state-file))

(defun state-file (directory)
  "Return the state.json path inside DIRECTORY."
  (merge-pathnames "state.json" (uiop:ensure-directory-pathname directory)))

(declaim (ftype (function (t) pathname) bootstrap-file))

(defun bootstrap-file (directory)
  "Return the BOOTSTRAP.md path inside DIRECTORY."
  (merge-pathnames "BOOTSTRAP.md" (uiop:ensure-directory-pathname directory)))

(declaim (ftype (function (t) pathname) bootstrap-done-file))

(defun bootstrap-done-file (directory)
  "Return the BOOTSTRAP.done.md path inside DIRECTORY."
  (merge-pathnames "BOOTSTRAP.done.md" (uiop:ensure-directory-pathname directory)))

;;;; State object.

(defparameter +state-schema+ 1
  "Current state.json schema version; unknown fields from newer versions are preserved.")

(declaim (ftype (function () hash-table) default-bootstrap-record))

(defun default-bootstrap-record ()
  "Return a fresh bootstrap record: step 0, no step done, not complete."
  (let ((record (make-hash-table :test #'equal)))
    (setf (gethash "step" record) 0
          (gethash "done" record) #()
          (gethash "complete" record) nil)
    record))

(declaim (ftype (function () hash-table) default-state))

(defun default-state ()
  "Return a fresh state hash table (schema 1, generation 0, empty bootstrap)."
  (let ((state (make-hash-table :test #'equal)))
    (setf (gethash "schema" state) +state-schema+
          (gethash "generation" state) 0
          (gethash "bootstrap" state) (default-bootstrap-record))
    state))

(declaim (ftype (function (hash-table) hash-table) normalize-bootstrap))

(defun normalize-bootstrap (candidate)
  "Normalize CANDIDATE into a complete bootstrap record, preserving unknown keys
and sorting/deduplicating done steps into a vector."
  (let ((record (default-bootstrap-record)))
    ;; Preserve keys written by newer versions
    (maphash (lambda (key value)
               (unless (member key '("step" "done" "complete") :test #'string=)
                 (setf (gethash key record) value)))
             candidate)
    (let ((step (gethash "step" candidate)))
      (when (and (integerp step) (not (minusp step)))
        (setf (gethash "step" record) step)))
    (let ((done (gethash "done" candidate)))
      (when (vectorp done)
        (setf (gethash "done" record)
              (coerce (sort (remove-duplicates
                             (remove-if-not (lambda (number)
                                              (and (integerp number) (plusp number)))
                                            (coerce done 'list)))
                            #'<)
                      'vector))))
    (when (gethash "complete" candidate)
      (setf (gethash "complete" record) t))
    record))

(declaim (ftype (function (t) hash-table) normalize-state))

(defun normalize-state (candidate)
  "Normalize CANDIDATE into a complete state hash table, preserving unknown keys
and newer schema numbers."
  (if (not (hash-table-p candidate))
      (default-state)
      (let ((state (default-state)))
        (maphash (lambda (key value)
                   (unless (member key '("schema" "generation" "bootstrap")
                                   :test #'string=)
                     (setf (gethash key state) value)))
                 candidate)
        (let ((schema (gethash "schema" candidate)))
          (when (and (integerp schema) (not (minusp schema)))
            (setf (gethash "schema" state) schema)))
        (let ((generation (gethash "generation" candidate)))
          (when (and (integerp generation) (not (minusp generation)))
            (setf (gethash "generation" state) generation)))
        (let ((bootstrap (gethash "bootstrap" candidate)))
          (when (hash-table-p bootstrap)
            (setf (gethash "bootstrap" state) (normalize-bootstrap bootstrap))))
        state)))

(declaim (ftype (function (hash-table) hash-table) bootstrap-record))

(defun bootstrap-record (state)
  "Return the bootstrap sub-object of STATE, initializing one if absent or invalid."
  (let ((record (gethash "bootstrap" state)))
    (if (hash-table-p record)
        record
        (let ((fresh (default-bootstrap-record)))
          (setf (gethash "bootstrap" state) fresh)
          fresh))))

;;;; Reading and writing.

(declaim (ftype (function (t) hash-table) read-state))

(defun read-state (directory)
  "Read state.json from DIRECTORY, returning DEFAULT-STATE on missing, invalid, or
unreadable files without signaling."
  (handler-case
      (let ((path (state-file directory)))
        (if (probe-file path)
            (let ((parsed (com.inuoe.jzon:parse (uiop:read-file-string path
                                                                       :external-format :utf-8))))
              (if (hash-table-p parsed)
                  (normalize-state parsed)
                  (default-state)))
            (default-state)))
    (error () (default-state))))

(defvar *state-write-lock* (bordeaux-threads:make-lock "enchiridion state writes"))

(defvar *state-write-sequence* 0
  "How many state writes this process has started, for a unique name.")

(defun state-temporary-name ()
  "Return a temporary state file name unique to this process and write."
  (bordeaux-threads:with-lock-held (*state-write-lock*)
    (format nil "state.json.new.~D.~D.~D"
            (enchiridion.compat:process-id)
            (get-internal-real-time)
            (incf *state-write-sequence*))))

(declaim (ftype (function (t hash-table) hash-table) write-state))

(defun write-state (directory state)
  "Atomically write STATE to DIRECTORY/state.json via a uniquely named temp file and rename.
Returns STATE."
  (let* ((path (state-file directory))
         (temporary (merge-pathnames
                     (state-temporary-name)
                     (uiop:ensure-directory-pathname directory)))
         (renamed-p nil))
    (ensure-directories-exist temporary)
    (unwind-protect
         (progn
           (with-open-file (stream temporary
                                   :direction :output
                                   :if-exists :error
                                   :if-does-not-exist :create
                                   :external-format :utf-8)
             (write-string (com.inuoe.jzon:stringify state) stream)
             (terpri stream))
           (uiop:rename-file-overwriting-target temporary path)
           (setf renamed-p t)
           state)
      (unless renamed-p
        (ignore-errors (delete-file temporary))))))

(declaim (ftype (function (t) hash-table) ensure-state))

(defun ensure-state (state-or-directory)
  "Return STATE-OR-DIRECTORY as a state hash table, reading state.json if given a directory."
  (if (hash-table-p state-or-directory)
      state-or-directory
      (read-state state-or-directory)))

;;;; The generation counter.

(declaim (ftype (function (t) integer) state-generation))

(defun state-generation (state-or-directory)
  "Return the generation counter. Accepts a state hash table or a directory."
  (the integer (gethash "generation" (ensure-state state-or-directory))))

(declaim (ftype (function (t integer) integer) set-state-generation))

(defun set-state-generation (state-or-directory generation)
  "Set the generation counter to GENERATION and return it.
Mutates a hash table in place; reads and writes state.json when given a directory."
  (if (hash-table-p state-or-directory)
      (setf (gethash "generation" state-or-directory) generation)
      (let ((state (read-state state-or-directory)))
        (setf (gethash "generation" state) generation)
        (write-state state-or-directory state)
        generation)))

;;;; Bootstrap steps.

(defparameter +bootstrap-step-scanner+
  (cl-ppcre:create-scanner "^[ \t]*(\\d+)\\.\\s*(.*)$")
  "A line that opens a numbered bootstrap step, and the text after the dot.")

(declaim (ftype (function (string) (or null cons)) bootstrap-step-from-line))

(defun bootstrap-step-from-line (line)
  "Return (NUMBER . TEXT) when LINE opens a numbered bootstrap step, else NIL."
  (multiple-value-bind (whole registers)
      (cl-ppcre:scan-to-strings +bootstrap-step-scanner+ line)
    (when whole
      (cons (parse-integer (aref registers 0))
            (string-trim '(#\Space #\Tab) (aref registers 1))))))

(declaim (ftype (function (t) list) bootstrap-steps))

(defun bootstrap-steps (directory)
  "Return numbered steps in DIRECTORY/BOOTSTRAP.md as (NUMBER . TEXT) pairs in file order,
or NIL if absent."
  (let ((path (bootstrap-file directory)))
    (when (probe-file path)
      (loop for line in (uiop:read-file-lines path :external-format :utf-8)
            for step = (bootstrap-step-from-line line)
            when step
              collect step))))

(declaim (ftype (function (hash-table) list) bootstrap-done-list))

(defun bootstrap-done-list (record)
  "Return completed step numbers in RECORD as a sorted, deduplicated list."
  (let ((done (gethash "done" record)))
    (if (vectorp done)
        (the list (sort (remove-duplicates
                         (remove-if-not (lambda (number)
                                          (and (integerp number) (plusp number)))
                                        (coerce done 'list)))
                        #'<))
        '())))

;;;; The bootstrap state machine.

(declaim (ftype (function (t) list) bootstrap-remaining))

(defun bootstrap-remaining (directory)
  "Return the steps in DIRECTORY that are not yet marked done, as (NUMBER . TEXT)
in file order."
  (let* ((state (read-state directory))
         (done (bootstrap-done-list (bootstrap-record state))))
    (remove-if (lambda (step) (member (car step) done :test #'=))
               (bootstrap-steps directory))))

(declaim (ftype (function (t) boolean) bootstrap-complete-p))

(defun bootstrap-complete-p (directory)
  "Return T when all steps in DIRECTORY/BOOTSTRAP.md are done (or the file is absent)."
  (null (bootstrap-remaining directory)))

(declaim (ftype (function (t) list) bootstrap-status))

(defun bootstrap-status (directory)
  "Return bootstrap state as (:step N :done (N...) :total M :complete BOOL :remaining ((N . TEXT)...))."
  (let* ((state (read-state directory))
         (record (bootstrap-record state))
         (done (bootstrap-done-list record))
         (steps (bootstrap-steps directory))
         (remaining (remove-if (lambda (step) (member (car step) done :test #'=)) steps)))
    (list :step (length done)
          :done done
          :total (length steps)
          :complete (null remaining)
          :remaining remaining)))

(declaim (ftype (function (t) boolean) bootstrap-refuse-writes-p))

(defun bootstrap-refuse-writes-p (directory)
  "Return T while BOOTSTRAP.md exists and has incomplete steps (blocks agent writes to seed-backed files)."
  (and (not (null (probe-file (bootstrap-file directory))))
       (not (bootstrap-complete-p directory))))

(declaim (ftype (function (t) string) bootstrap-commit-report))

(defun bootstrap-commit-report (directory)
  "Commit DIRECTORY after handover and return a one-line status string; never signals."
  (handler-case
      (let ((revision (enchiridion.git:git-commit-all directory "Bootstrap handover complete.")))
        (cond
          ((null revision) "The agent repository was not committed.")
          ((eq revision :nothing) "Nothing changed, so there was nothing to commit.")
          (t (format nil "Commit ~A recorded the change." revision))))
    (error () "The agent repository was not committed.")))

(declaim (ftype (function (t) string) bootstrap-handover))

(defun bootstrap-handover (directory)
  "Archive BOOTSTRAP.md to BOOTSTRAP.done.md, mark bootstrap complete in state.json,
commit, and return a report string. Archive runs before commit so git failures cannot lose it."
  (let* ((source (bootstrap-file directory))
         (target (bootstrap-done-file directory))
         (archived-p (not (null (probe-file source)))))
    (when archived-p
      (uiop:rename-file-overwriting-target source target))
    (let ((state (read-state directory)))
      (setf (gethash "complete" (bootstrap-record state)) t)
      (write-state directory state))
    (format nil "~A ~A"
            (if archived-p
                "Bootstrap complete; BOOTSTRAP.md is now BOOTSTRAP.done.md."
                "Bootstrap complete; there was no BOOTSTRAP.md to archive.")
            (bootstrap-commit-report directory))))

(declaim (ftype (function (t list) list) mark-bootstrap-steps)
         (ftype (function (t integer) list) mark-bootstrap-step))

(defun mark-bootstrap-step (directory step)
  "Mark STEP done in DIRECTORY, trigger handover if all steps are complete, and return the status."
  (mark-bootstrap-steps directory (list step)))

(defun mark-bootstrap-steps (directory steps)
  "Record STEPS in one state update and run handover if complete."
  (let* ((state (read-state directory))
         (record (bootstrap-record state))
         (done (sort (remove-duplicates (append steps (bootstrap-done-list record))) #'<)))
    (setf (gethash "done" record) (coerce done 'vector)
          (gethash "step" record) (length done))
    (write-state directory state)
    (when (and (probe-file (bootstrap-file directory))
               (bootstrap-complete-p directory))
      (bootstrap-handover directory))
    (bootstrap-status directory)))

(declaim (ftype (function (t) list) reset-bootstrap))

(defun reset-bootstrap (directory)
  "Restore BOOTSTRAP.done.md (only if BOOTSTRAP.md is absent), clear the bootstrap record,
and return the new status."
  (let ((source (bootstrap-file directory))
        (target (bootstrap-done-file directory)))
    (when (and (probe-file target) (not (probe-file source)))
      (uiop:rename-file-overwriting-target target source))
    (let ((state (read-state directory)))
      (setf (gethash "bootstrap" state) (default-bootstrap-record))
      (write-state directory state))
    (bootstrap-status directory)))

(declaim (ftype (function (string) string) bootstrap-step-summary))

(defun bootstrap-step-summary (text)
  "Flatten TEXT to a single line truncated to at most 60 characters."
  (let ((flat (substitute #\Space #\Newline text)))
    (if (<= (length flat) 60)
        flat
        (concatenate 'string (subseq flat 0 57) "..."))))

(declaim (ftype (function (t) string) bootstrap-status-line))

(defun bootstrap-status-line (directory)
  "Format the bootstrap state as a single status line."
  (let* ((status (bootstrap-status directory))
         (total (getf status :total))
         (remaining (getf status :remaining)))
    (cond
      ((getf status :complete)
       (if (zerop total)
           "Bootstrap complete."
           (format nil "Bootstrap complete: ~D of ~D steps done."
                   (getf status :step) total)))
      ((null remaining) "Bootstrap complete.")
      (t (format nil "Bootstrap step ~D of ~D: ~A"
                 (car (first remaining)) total
                 (bootstrap-step-summary (cdr (first remaining))))))))
