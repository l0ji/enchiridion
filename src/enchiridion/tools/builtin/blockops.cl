;;;; blockops.cl --- Read, patch, and add to the memory blocks.
;;;;
;;;; A block is a file the agent can reason about, not a database row. The
;;;; tool patches a unique span, checks the capacity and the injection scan,
;;;; and writes the file last. A failed write leaves the old text in place.

(in-package #:enchiridion.tools.builtin)

(defparameter +block-files+
  '(("soul" . "SOUL.md")
    ("persona" . "SOUL.md")
    ("operator" . "OPERATOR.md")
    ("world" . "WORLD.md"))
  "The labels that have a Markdown file, and the file each one uses.")

(defun block-directory (args)
  "Return the agent directory BLOCKOPS reads and writes."
  (let ((path (argument args "directory")))
    (cond
      (path (uiop:ensure-directory-pathname path))
      ((uiop:getenv "ENCHIRIDION_HOME")
       (merge-pathnames "agents/default/"
                        (uiop:ensure-directory-pathname
                         (uiop:getenv "ENCHIRIDION_HOME"))))
      (t (uiop:ensure-directory-pathname *default-pathname-defaults*)))))

(defun block-file-for (label directory)
  "Return the file for LABEL under DIRECTORY, or signal a schema error."
  (let ((entry (assoc (string-downcase (string label)) +block-files+
                      :test #'string=)))
    (unless entry
      (error 'enchiridion.errors:schema-error
             :detail (format nil "Unknown block label ~A." label)))
    (merge-pathnames (cdr entry) directory)))

(defun block-limit-for (label)
  "Return the character limit for LABEL."
  (enchiridion.memory:default-block-limit
   (intern (string-upcase (string label)) :keyword)))

(defun block-read-text (path)
  "Return PATH as text, or an empty string when it does not exist."
  (if (probe-file path)
      (uiop:read-file-string path :external-format :utf-8)
      ""))

(defun block-write-text (path text label)
  "Check TEXT against LABEL's scan and limit, then write PATH."
  (let ((label (intern (string-upcase (string label)) :keyword)))
    (enchiridion.memory:scan-block-text label text)
    (when (> (length text) (block-limit-for label))
      (error 'enchiridion.errors:block-overflow
             :label label
             :current (block-limit-for label)
             :wanted (length text)))
    (ensure-directories-exist path)
    (with-open-file (stream path :direction :output
                                 :if-exists :supersede
                                 :if-does-not-exist :create
                                 :external-format :utf-8)
      (write-string text stream))
    text))

(defun block-list (directory)
  "Return a line for each known block with its size and limit."
  (with-output-to-string (stream)
    (dolist (entry +block-files+)
      (let* ((label (first entry))
             (path (merge-pathnames (cdr entry) directory))
             (text (block-read-text path)))
        (format stream "~A ~D/~D ~A~%"
                label (length text) (block-limit-for label) (namestring path))))))

(declaim (ftype (function (t) string) block-ops))

(defun block-ops (args)
  "Read, patch, or add to a memory block. ACTION defaults to list."
  (let* ((action (string-downcase (or (argument args "action") "list")))
         (directory (block-directory args))
         (label (argument args "label"))
         (path (and label (block-file-for label directory)))
         (text (if path (block-read-text path) "")))
    (cond
      ((string= action "list") (cap-result (block-list directory)))
      ((string= action "read")
       (unless path (error 'enchiridion.errors:schema-error :detail "label is required."))
       (cap-result text))
      ((string= action "patch")
       (unless path (error 'enchiridion.errors:schema-error :detail "label is required."))
       (let* ((old (argument args "old"))
              (new (argument args "new"))
              (position (and (stringp old) (plusp (length old)) (search old text))))
         (unless (and (stringp old) (plusp (length old)))
           (error 'enchiridion.errors:schema-error :detail "old must be a non-empty string."))
         (unless position
           (error 'enchiridion.errors:tool-error
                  :tool "blockops"
                  :detail "The old text does not occur in the block."))
         (when (search old text :start2 (1+ position))
           (error 'enchiridion.errors:tool-error
                  :tool "blockops"
                  :detail "The old text occurs more than once; make it unique."))
         (let ((updated (concatenate 'string
                                     (subseq text 0 position)
                                     new
                                     (subseq text (+ position (length old))))))
           (block-write-text path updated label)
           (format nil "patched ~A" (namestring path)))))
      ((string= action "add")
       (unless path (error 'enchiridion.errors:schema-error :detail "label is required."))
       (let ((addition (argument args "text")))
         (unless (stringp addition)
           (error 'enchiridion.errors:schema-error :detail "text must be a string."))
         (let ((updated (if (zerop (length text))
                            addition
                            (concatenate 'string text (string #\Newline) addition))))
           (block-write-text path updated label)
           (format nil "added to ~A" (namestring path)))))
      (t (error 'enchiridion.errors:schema-error
                :detail (format nil "Unknown block action ~A." action))))))

(defparameter +block-tools+
  (list
   (enchiridion.tools:make-tool
    :name "blockops"
    :description "List, read, patch, or add to a memory block."
    :schema '(:object :properties
              ((:action :string) (:label :string) (:old :string)
               (:new :string) (:text :string) (:directory :string)))
    :handler #'block-ops)))

(defun register-block-tools ()
  "Register the block tool. Idempotent."
  (dolist (tool +block-tools+)
    (enchiridion.tools:register-tool tool))
  (length +block-tools+))
