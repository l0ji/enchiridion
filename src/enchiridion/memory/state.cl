;;;; state.cl --- state.json, the generation counter, and the bootstrap record.
;;;;
;;;; The agent directory holds one small JSON file. It records the plugin
;;;; generation the loader has reached and how far the first-steps bootstrap
;;;; has got. Everything else derives from it, so it has exactly one reader and
;;;; one writer, and the reader never signals: a missing, empty, or corrupt
;;;; file is a fresh agent, not a crash.
;;;;
;;;; The in-memory shape is the shape com.inuoe.jzon produces and accepts: an
;;;; EQUAL hash table keyed by strings, arrays as vectors, and false as NIL.
;;;; Keeping the native shape means STRINGIFY can write a state directly.
;;;; Handing it a plist instead writes a JSON array of alternating elements,
;;;; and an empty list is the boolean false, not an empty array.

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

;;;; The state object.
;;;;
;;;; default-bootstrap-record comes first because default-state calls it and a
;;;; call to a function that is neither defined nor declared yet is exactly the
;;;; warning this build refuses.

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
  "Return a fresh state: schema 1, generation 0, bootstrap untouched.

The template init writes and this function must agree, because the file is
read back into this shape on the first call."
  (let ((state (make-hash-table :test #'equal)))
    (setf (gethash "schema" state) 1
          (gethash "generation" state) 0
          (gethash "bootstrap" state) (default-bootstrap-record))
    state))

(declaim (ftype (function (hash-table) hash-table) normalize-bootstrap))

(defun normalize-bootstrap (candidate)
  "Return CANDIDATE as a complete bootstrap record.

An absent field takes its default. A field of the wrong type takes its default
too: a state.json a human edited by hand should cost the agent a fresh start,
not a type error three functions later. Step numbers are kept as a sorted,
duplicate-free vector because that is what STRINGIFY writes as a JSON array."
  (let ((record (default-bootstrap-record)))
    (let ((step (gethash "step" candidate)))
      (when (and (integerp step) (not (minusp step)))
        (setf (gethash "step" record) step)))
    (let ((done (gethash "done" candidate)))
      (when (vectorp done)
        (setf (gethash "done" record)
              (coerce (sort (remove-duplicates (remove-if-not #'integerp (coerce done 'list)))
                            #'<)
                      'vector))))
    (when (gethash "complete" candidate)
      (setf (gethash "complete" record) t))
    record))

(declaim (ftype (function (t) hash-table) normalize-state))

(defun normalize-state (candidate)
  "Return CANDIDATE as a complete state, filling anything absent or malformed
from DEFAULT-STATE. A JSON document that is not an object is not a state."
  (if (not (hash-table-p candidate))
      (default-state)
      (let ((state (default-state)))
        (let ((schema (gethash "schema" candidate)))
          (when (integerp schema)
            (setf (gethash "schema" state) schema)))
        (let ((generation (gethash "generation" candidate)))
          (when (integerp generation)
            (setf (gethash "generation" state) generation)))
        (let ((bootstrap (gethash "bootstrap" candidate)))
          (when (hash-table-p bootstrap)
            (setf (gethash "bootstrap" state) (normalize-bootstrap bootstrap))))
        state)))

(declaim (ftype (function (hash-table) hash-table) bootstrap-record))

(defun bootstrap-record (state)
  "Return the bootstrap sub-object of STATE, adding a fresh one when the key is
absent or does not hold an object."
  (let ((record (gethash "bootstrap" state)))
    (if (hash-table-p record)
        record
        (let ((fresh (default-bootstrap-record)))
          (setf (gethash "bootstrap" state) fresh)
          fresh))))

;;;; Reading and writing.
;;;;
;;;; The reader is the tolerant one and the writer is the atomic one. Both
;;;; matter at the same moment: a supervisor killed mid-write must not leave a
;;;; half file that the next start cannot read.

(declaim (ftype (function (t) hash-table) read-state))

(defun read-state (directory)
  "Return the state stored in DIRECTORY, or DEFAULT-STATE.

Never signals. A missing file, an empty file, and a file that is not the state
JSON all mean the same thing to every caller: a fresh agent. The handler is
around the whole body, because PROBE-FILE and the read can fail too, not only
the parse."
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

(declaim (ftype (function (t hash-table) hash-table) write-state))

(defun write-state (directory state)
  "Write STATE to DIRECTORY/state.json and return STATE.

The bytes go to state.json.new first and the rename happens last, so a crash
can leave the old state or the new one, never half of either. The overwriting
rename is UIOP's: it is atomic where the implementation allows it, and this
runs on a five second status timer."
  (let* ((path (state-file directory))
         (temporary (merge-pathnames "state.json.new"
                                     (uiop:ensure-directory-pathname directory))))
    (ensure-directories-exist temporary)
    (with-open-file (stream temporary
                            :direction :output
                            :if-exists :supersede
                            :if-does-not-exist :create
                            :external-format :utf-8)
      (write-string (com.inuoe.jzon:stringify state) stream)
      (terpri stream))
    (uiop:rename-file-overwriting-target temporary path)
    state))

(declaim (ftype (function (t) hash-table) ensure-state))

(defun ensure-state (state-or-directory)
  "Return STATE-OR-DIRECTORY as a state hash table. A state comes back
unchanged, and a directory is read from its state.json."
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

Given a state hash table the change is made in memory and the caller writes it
with WRITE-STATE. Given a directory the state is read, changed, and written
back, which is what a loader that only knows the agent directory wants."
  (if (hash-table-p state-or-directory)
      (setf (gethash "generation" state-or-directory) generation)
      (let ((state (read-state state-or-directory)))
        (setf (gethash "generation" state) generation)
        (write-state state-or-directory state)
        generation)))

;;;; The bootstrap steps.
;;;;
;;;; BOOTSTRAP.md is an ordered list in Markdown. The parser is deliberately
;;;; the plainest thing that matches the template: optional indent, digits, a
;;;; dot, then the text of the line. Continuation lines that wrap a step are
;;;; part of the file's prose, not of the step's name.

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
  "Return the first steps in DIRECTORY/BOOTSTRAP.md as a list of (NUMBER . TEXT),
in the order the file gives them. The list is empty when the file is absent,
which is what makes an absent file mean a finished bootstrap."
  (let ((path (bootstrap-file directory)))
    (when (probe-file path)
      (loop for line in (uiop:read-file-lines path :external-format :utf-8)
            for step = (bootstrap-step-from-line line)
            when step
              collect step))))

(declaim (ftype (function (hash-table) list) bootstrap-done-list))

(defun bootstrap-done-list (record)
  "Return the step numbers in RECORD as a sorted list.

STATE writes a sorted, duplicate-free vector. The sort and the duplicate
removal are repeated here so that a hand-edited file cannot make completeness
depend on the order the file happened to list."
  (let ((done (gethash "done" record)))
    (if (vectorp done)
        (the list (sort (remove-duplicates (remove-if-not #'integerp (coerce done 'list))) #'<))
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
  "Return T when every step in DIRECTORY is done.

An absent BOOTSTRAP.md has no steps, so it is complete: that is both the
handover that renamed the file and a directory that never had one."
  (null (bootstrap-remaining directory)))

(declaim (ftype (function (t) list) bootstrap-status))

(defun bootstrap-status (directory)
  "Return the bootstrap state as a plist:

  (:step N :done (N...) :total M :complete BOOL :remaining ((N . TEXT)...))

:STEP is the number of steps done, which is the count the prompt line and the
status command both want. :REMAINING holds the steps still to do, in file
order, so a caller can name the next one without parsing the file again."
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
  "Return T while the agent may not write the seed-backed blocks.

True exactly while BOOTSTRAP.md is present and its steps are not all done. The
operator's guidance cannot be edited away in the first minutes of the agent's
life; after handover the file is gone and the answer is NIL."
  (and (not (null (probe-file (bootstrap-file directory))))
       (not (bootstrap-complete-p directory))))

(declaim (ftype (function (t) string) bootstrap-commit-report))

(defun bootstrap-commit-report (directory)
  "Commit DIRECTORY through ENCHIRIDION.GIT and return one line about it.

This is the only part of the handover that can fail without losing work: the
archive has already happened, and a git that is missing, broken, or simply not
there yet must not be the reason a completed bootstrap is reported as lost."
  (handler-case
      (let ((revision (enchiridion.git:git-commit-all directory "Bootstrap handover complete.")))
        (cond
          ((null revision) "The agent repository was not committed.")
          ((eq revision :nothing) "Nothing changed, so there was nothing to commit.")
          (t (format nil "Commit ~A recorded the change." revision))))
    (error () "The agent repository was not committed.")))

(declaim (ftype (function (t) string) bootstrap-handover))

(defun bootstrap-handover (directory)
  "Archive BOOTSTRAP.md, mark the bootstrap complete, write the state, commit,
and return a report string.

A missing BOOTSTRAP.md is not a failure: it still marks the state complete, so
a handover interrupted after the rename finishes on the next call. The rename
comes first and the commit last, so no git failure can lose the archive."
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

(declaim (ftype (function (t integer) list) mark-bootstrap-step))

(defun mark-bootstrap-step (directory step)
  "Mark STEP done in DIRECTORY and return the new bootstrap status.

The list stays sorted and duplicate free, so marking the same step twice is the
same as marking it once. When the last step lands, the handover runs from here:
the agent should not have to know that a separate call finishes the job."
  (let* ((state (read-state directory))
         (record (bootstrap-record state))
         (done (sort (remove-duplicates (cons step (bootstrap-done-list record))) #'<)))
    (setf (gethash "done" record) (coerce done 'vector)
          (gethash "step" record) (length done))
    (write-state directory state)
    (when (and (probe-file (bootstrap-file directory))
               (bootstrap-complete-p directory))
      (bootstrap-handover directory))
    (bootstrap-status directory)))

(declaim (ftype (function (t) list) reset-bootstrap))

(defun reset-bootstrap (directory)
  "Undo a handover: restore BOOTSTRAP.md, clear the bootstrap record, write the
state, and return the new status.

BOOTSTRAP.done.md is renamed back only when BOOTSTRAP.md is absent. When both
exist an operator has edited the live file already, and the archive must not
overwrite that."
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
  "Return TEXT as one line of at most sixty characters.

The prompt line and the status command both print this, and a wrapped step from
the template would otherwise push the line past the column the terminal
reports."
  (let ((flat (substitute #\Space #\Newline text)))
    (if (<= (length flat) 60)
        flat
        (concatenate 'string (subseq flat 0 57) "..."))))

(declaim (ftype (function (t) string) bootstrap-status-line))

(defun bootstrap-status-line (directory)
  "Return the bootstrap state as one line, for the prompt and for
`enchiridion bootstrap status`."
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
