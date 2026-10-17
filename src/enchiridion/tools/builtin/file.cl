;;;; file.cl --- File tools: index, read, write, edit, glob.
;;;;
;;;; The index is first because it is the token win. A model that sees a
;;;; skeleton and line ranges can ask for the twenty lines it needs instead of
;;;; paying for a file it has not read. The reader gives the line positions, so
;;;; there is no parser dependency and no second grammar to keep in sync.

(in-package #:enchiridion.tools.builtin)

(defparameter +result-cap+ 8000
  "The character cap for one tool result. Anything larger spills to a file and
the model gets the head plus the path, which is cheaper than the whole result
and still recoverable.")

(defun spill-path (text &key (directory (enchiridion.compat:temp-directory)))
  "Write TEXT to a fresh file under DIRECTORY and return the namestring."
  (let* ((directory (uiop:ensure-directory-pathname directory))
         (path (merge-pathnames
                (format nil "spill-~D.txt" (random most-positive-fixnum))
                directory)))
    (ensure-directories-exist path)
    (with-open-file (stream path :direction :output
                                 :if-exists :supersede
                                 :if-does-not-exist :create
                                 :external-format :utf-8)
      (write-string text stream))
    (namestring path)))

(defun cap-result (text &key (cap +result-cap+) (spill-directory (enchiridion.compat:temp-directory)))
  "Return TEXT when it fits, or its head and a spill path when it does not."
  (if (<= (length text) cap)
      text
      (format nil "~A~%[truncated ~D characters; full result at ~A]"
              (subseq text 0 cap)
              (- (length text) cap)
              (spill-path text :directory spill-directory))))

(defun line-number (text position)
  "Return the 1-based line that contains POSITION in TEXT."
  (1+ (loop for index from 0 below position
            count (char= (char text index) #\Newline))))

(defun skeleton-name (object)
  "Return a readable name for a form's second element."
  (typecase object
    (symbol (string-downcase (symbol-name object)))
    (string object)
    (t (prin1-to-string object))))

(defun form-skeleton (form)
  "Return a one line skeleton for FORM, or its printed value."
  (if (and (consp form) (symbolp (first form)))
      (let ((head (string-upcase (symbol-name (first form))))
            (name (second form)))
        (cond
          ((member head '("DEFUN" "DEFMACRO" "DEFMETHOD" "DEFGENERIC"
                          "DEFVAR" "DEFPARAMETER" "DEFCONSTANT" "DEFCLASS"
                          "DEFSTRUCT" "DEFPACKAGE" "DEFSYSTEM" "DEFMETHOD")
                   :test #'string=)
           (format nil "(~A ~A ...)" (string-downcase head) (skeleton-name name)))
          (t
           (format nil "(~A ...)" (string-downcase head)))))
      (prin1-to-string form)))

(declaim (ftype (function (pathname) list) file-index-forms))

(defun file-index-forms (path)
  "Return a plist per top level form in PATH: :START, :END, and :FORM.

Reading is done with *READ-EVAL* NIL and a throwaway package. The file is
agent-authored, so an evaluated reader macro in the index would be a remote
code execution with the index's permissions. The package keeps symbols from
polluting the running image and keeps an IN-PACKAGE form from changing the
reader's package for the next form."
  (let ((text (uiop:read-file-string path :external-format :utf-8))
        (forms '())
        (position 0)
        (package (make-package (format nil "ENCHIRIDION-INDEX-~D"
                                       (random most-positive-fixnum))
                               :use '(:cl))))
    (unwind-protect
         (let ((*package* package)
               (*read-eval* nil))
           (loop
             (multiple-value-bind (form next)
                 (read-from-string text nil :eof :start position)
               (when (eq form :eof)
                 (return))
               (push (list :start (line-number text position)
                           :end (line-number text next)
                           :form (form-skeleton form))
                     forms)
               (setf position next))))
      (delete-package package))
    (nreverse forms)))

(declaim (ftype (function (t) string) file-index))

(defun file-index (path)
  "Return the skeleton of PATH with the line range of each top level form."
  (let* ((path (pathname path))
         (forms (file-index-forms path)))
    (with-output-to-string (stream)
      (format stream "~A: ~D top level form~:P~%" (namestring path) (length forms))
      (dolist (form forms)
        (format stream "~D-~D ~A~%"
                (getf form :start)
                (getf form :end)
                (getf form :form))))))

(defun argument (args key &optional default)
  "Return KEY from the tool arguments, or DEFAULT.

DISPATCH normalises arguments to a hash table, but a Lisp caller and a unit
test often hold the plist directly. Both shapes answer here, so a handler does
not fail on the shape of the thing it was called with."
  (etypecase args
    (hash-table
     (multiple-value-bind (value present) (gethash key args)
       (if present value default)))
    (list
     (getf args (if (keywordp key) key (intern (string-upcase key) :keyword))
           default))))

(defun tool-index (args)
  (cap-result (file-index (argument args "path"))))

(defun split-lines (text)
  "Return TEXT as lines without their newline characters."
  (when (zerop (length text))
    (return-from split-lines '()))
  (uiop:split-string text :separator (list #\Newline)))

(defun tool-read (args)
  "Read a 1-based inclusive line range from PATH."
  (let* ((path (pathname (argument args "path")))
         (lines (split-lines (uiop:read-file-string path :external-format :utf-8)))
         (from (or (argument args "from") 1))
         (to (or (argument args "to") (length lines))))
    (when (or (< from 1) (> from to) (> to (length lines)))
      (error 'enchiridion.errors:schema-error
             :detail (format nil "Line range ~D..~D is outside ~D lines."
                             from to (length lines))))
    (cap-result (format nil "~{~A~^~%~}"
                        (subseq lines (1- from) to)))))

(defun tool-write (args)
  "Write TEXT to PATH, creating parent directories."
  (let ((path (pathname (argument args "path")))
        (text (argument args "text")))
    (unless (stringp text)
      (error 'enchiridion.errors:schema-error :detail "text must be a string."))
    (ensure-directories-exist path)
    (with-open-file (stream path :direction :output
                                 :if-exists :supersede
                                 :if-does-not-exist :create
                                 :external-format :utf-8)
      (write-string text stream))
    (format nil "wrote ~D characters to ~A" (length text) (namestring path))))

(defun tool-edit (args)
  "Replace one unique occurrence of OLD with NEW in PATH."
  (let* ((path (pathname (argument args "path")))
         (old (argument args "old"))
         (new (argument args "new"))
         (text (uiop:read-file-string path :external-format :utf-8))
         (position (and (stringp old)
                        (plusp (length old))
                        (search old text))))
    (unless (and (stringp old) (plusp (length old)))
      (error 'enchiridion.errors:schema-error :detail "old must be a non-empty string."))
    (unless position
      (error 'enchiridion.errors:tool-error
             :tool "edit-file"
             :detail "The old text does not occur in the file."))
    (when (search old text :start2 (1+ position))
      (error 'enchiridion.errors:tool-error
             :tool "edit-file"
             :detail "The old text occurs more than once; make it unique."))
    (let ((updated (concatenate 'string
                                (subseq text 0 position)
                                new
                                (subseq text (+ position (length old))))))
      (with-open-file (stream path :direction :output
                                   :if-exists :supersede
                                   :external-format :utf-8)
        (write-string updated stream))
      (format nil "edited ~A" (namestring path)))))

(defun tool-glob (args)
  "Return the paths matching PATTERN."
  (let ((pattern (argument args "pattern")))
    (unless (stringp pattern)
      (error 'enchiridion.errors:schema-error :detail "pattern must be a string."))
    (cap-result
     (format nil "~{~A~^~%~}"
             (mapcar #'namestring (directory (pathname pattern)))))))

(defparameter +file-tools+
  (list
   (enchiridion.tools:make-tool
    :name "index"
    :description "List the top level forms of a Lisp file with line ranges."
    :schema '(:object :required (:path) :properties ((:path :string)))
    :handler #'tool-index)
   (enchiridion.tools:make-tool
    :name "read-file"
    :description "Read a line range from a file."
    :schema '(:object :required (:path)
              :properties ((:path :string) (:from :integer) (:to :integer)))
    :handler #'tool-read)
   (enchiridion.tools:make-tool
    :name "write-file"
    :description "Write text to a file, creating parent directories."
    :schema '(:object :required (:path :text)
              :properties ((:path :string) (:text :string)))
    :handler #'tool-write)
   (enchiridion.tools:make-tool
    :name "edit-file"
    :description "Replace one unique occurrence of old with new in a file."
    :schema '(:object :required (:path :old :new)
              :properties ((:path :string) (:old :string) (:new :string)))
    :handler #'tool-edit)
   (enchiridion.tools:make-tool
    :name "glob"
    :description "List the paths that match a wildcard pattern."
    :schema '(:object :required (:pattern)
              :properties ((:pattern :string)))
    :handler #'tool-glob)))

(defun register-file-tools ()
  "Register the file tools. Idempotent, so a reload can call it again."
  (dolist (tool +file-tools+)
    (enchiridion.tools:register-tool tool))
  (length +file-tools+))
