;;;; file.lsp --- File tools: index, read, write, edit, glob.

(in-package #:enchiridion.tools.builtin)

(defparameter +result-cap+ 8000
  "Max characters returned inline by a tool; larger results spill to a temp file.")

(defparameter *file-read-byte-limit* (* 1024 1024)
  "The largest whole file a file or search tool decodes at once, in bytes.")

(declaim (ftype (function (t) string) read-file-bounded))

(defun read-file-bounded (path)
  "Return PATH decoded as UTF-8, reading at most the configured byte limit."
  (with-open-file (stream path :direction :input
                               :element-type '(unsigned-byte 8))
    (let* ((buffer (make-array (1+ *file-read-byte-limit*)
                               :element-type '(unsigned-byte 8)))
           (end (read-sequence buffer stream)))
      (when (> end *file-read-byte-limit*)
        (error 'enchiridion.errors:tool-error
               :tool "read-file"
               :detail (format nil "~A is larger than ~D bytes."
                               (namestring (pathname path))
                               *file-read-byte-limit*)))
      (sb-ext:octets-to-string buffer :external-format :utf-8 :end end))))

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
  "Return a plist (:START :END :FORM) per top-level form in PATH.
Reads with *READ-EVAL* NIL and a throwaway package to prevent reader eval and symbol pollution."
  (let ((text (read-file-bounded path))
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
  "Return KEY from tool ARGS (hash table or keyword plist), or DEFAULT."
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
         (lines (split-lines (read-file-bounded path)))
         (from-argument (argument args "from"))
         (to-argument (argument args "to"))
         (from (or from-argument 1))
         (to (or to-argument (length lines))))
    (when (or (and (null lines) (or from-argument to-argument))
              (and lines
                   (or (< from 1) (> from to) (> to (length lines)))))
      (error 'enchiridion.errors:schema-error
             :detail (format nil "Line range ~D..~D is outside ~D lines."
                             from to (length lines))))
    (cap-result (format nil "~{~A~^~%~}"
                        (subseq lines (1- from) to)))))

(defparameter +seed-backed-identity-files+
  '(("SOUL.md" . :soul) ("OPERATOR.md" . :operator) ("WORLD.md" . :world))
  "The files the bootstrap gate protects, and the label each one reports.")

(defparameter +harness-maintained-adaptation-file+ "ADAPT.md"
  "Harness-maintained file; file tools refuse writes to it at every bootstrap state.")

(defun absolute-pathname (path)
  "Return PATH as an absolute pathname, relative to the current directory."
  (let ((path (pathname path)))
    (if (uiop:absolute-pathname-p path)
        path
        (merge-pathnames path (uiop:getcwd)))))

(defun canonical-pathname (path)
  "Return PATH with symlinks resolved when it exists, or absolute when it does not."
  (or (ignore-errors (truename path)) (absolute-pathname path)))

(defun seed-backed-identity-label (path)
  "Return the label PATH reports when it is a seed-backed identity file."
  (let ((target (canonical-pathname path))
        (agent (canonical-pathname (enchiridion:agent-directory))))
    (loop for (name . label) in +seed-backed-identity-files+
          when (uiop:pathname-equal
                target
                (canonical-pathname (merge-pathnames name agent)))
            return label)))

(defun check-seed-backed-write (path)
  "Refuse a write to an identity file while the bootstrap is pending."
  (let ((label (seed-backed-identity-label path)))
    (when (and label
               (enchiridion.memory:bootstrap-refuse-writes-p
                (enchiridion:agent-directory)))
      (error 'enchiridion.errors:bootstrap-pending :label label))))

(defun adaptation-file-p (path)
  "Return T when PATH names the agent's ADAPT.md, following a symlink."
  (let* ((agent (canonical-pathname (enchiridion:agent-directory)))
         (adaptation (canonical-pathname
                      (merge-pathnames +harness-maintained-adaptation-file+ agent))))
    (uiop:pathname-equal (canonical-pathname path) adaptation)))

(defun check-file-write (path tool)
  "Refuse writes to ADAPT.md (following symlinks) at all times, and to seed-backed files during bootstrap."
  (when (adaptation-file-p path)
    (error 'enchiridion.errors:tool-error
           :tool tool
           :detail "ADAPT.md is harness-maintained; a maintenance proposal is the only writer."))
  (check-seed-backed-write path))

(defun tool-write (args)
  "Write TEXT to PATH, creating parent directories."
  (let ((path (pathname (argument args "path")))
        (text (argument args "text")))
    (unless (stringp text)
      (error 'enchiridion.errors:schema-error :detail "text must be a string."))
    (check-file-write path "write-file")
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
         (new (argument args "new")))
    (check-file-write path "edit-file")
    (let* ((text (read-file-bounded path))
           (position (and (stringp old)
                          (plusp (length old))
                          (search old text))))
      (unless (and (stringp old) (plusp (length old)))
        (error 'enchiridion.errors:schema-error
               :detail "old must be a non-empty string."))
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
        (format nil "edited ~A" (namestring path))))))

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
