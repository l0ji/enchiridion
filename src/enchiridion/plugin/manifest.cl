;;;; manifest.cl --- Read a plugin manifest without loading the file.
;;;;
;;;; The supervisor has to know the name, the description and the schema of
;;;; every agent tool, because those are what the model sees. It must never
;;;; execute the file to find out. This reader walks the top-level forms with
;;;; *READ-EVAL* NIL and takes each (define-plugin ...) form as data: no
;;;; evaluation, no compilation, and no way for a file to run by being read.

(in-package #:enchiridion.plugin)

(declaim (ftype function plugin-manifests))

(declaim (ftype (function (t) t) manifest-name))

(defun manifest-name (manifest)
  "Return the tool name MANIFEST declares."
  (getf manifest :name))

(declaim (ftype (function (t) t) manifest-description))

(defun manifest-description (manifest)
  "Return the one line description MANIFEST declares."
  (getf manifest :description))

(declaim (ftype (function (t) t) manifest-schema))

(defun manifest-schema (manifest)
  "Return the schema form MANIFEST declares, exactly as the file wrote it."
  (getf manifest :schema))

(declaim (ftype (function (t) boolean) plugin-form-p))

(defun plugin-form-p (form)
  "Return T when FORM is a (define-plugin ...) top-level form."
  (and (consp form)
       (symbolp (first form))
       (string-equal "DEFINE-PLUGIN" (symbol-name (first form)))))

(declaim (ftype (function (t) string) plugin-form-name))

(defun plugin-form-name (form)
  "Return the plugin name FORM declares, as the registry spells it."
  (string-downcase (string (second form))))

(declaim (ftype (function (t) t) plugin-form-tool))

(defun plugin-form-tool (form)
  "Return the (tool ...) form inside FORM, or NIL."
  (getf (cddr form) :tool))

(declaim (ftype (function (t) list) plugin-form-manifest))

(defun plugin-form-manifest (form)
  "Return the manifest FORM declares.

The tool form carries the name, the description and the schema, in either of
the two spellings TOOL-FORM-PARTS understands. A plugin with no tool form
still has a name and an empty schema, so the caller never has to guess whether
a manifest exists."
  (multiple-value-bind (name description schema)
      (tool-form-parts (plugin-form-tool form))
    (list :name (string-downcase (string (or name (plugin-form-name form))))
          :description (if (stringp description) description "")
          :schema (or schema '(:object :properties ())))))

(defparameter +manifest-file-limit+ (* 256 1024)
  "The largest agent file the supervisor will read for manifests, in bytes.
A plugin is a page of Lisp; a file far larger than that is not one.")

(defparameter +manifest-numeric-argument-limit+ 4096
  "The largest numeric argument a reader macro may carry, as in #4096(...).
The reader allocates what the argument says before it reads a byte more.")

(defun refuse-reader-macro (stream subchar argument)
  "Refuse a reader macro the supervisor never needs to read a manifest."
  (declare (ignore stream argument))
  (error "The #~C reader macro is not allowed in an agent file." subchar))

(defun bounded-reader-macro (original)
  "Return ORIGINAL, a dispatch macro function, refusing a numeric argument
above the limit."
  (lambda (stream subchar argument)
    (when (and argument (> argument +manifest-numeric-argument-limit+))
      (error "The #~D~C reader macro asks for more than ~D elements."
             argument subchar +manifest-numeric-argument-limit+))
    (funcall original stream subchar argument)))

(defun manifest-readtable ()
  "Return the readtable the supervisor reads agent files with.

The supervisor runs as root and holds the secrets, and the file it reads was
written by the agent. *READ-EVAL* NIL stops #., but the standard reader still
builds whatever the text describes. #= and ## build circular structure, and a
circular plist hangs GETF for good; #S calls a structure constructor; #A and
a large #n( or #n* allocate what the text asks for. A manifest needs none of
them, so they are refused, and the numeric argument of the rest is bounded."
  (let ((table (copy-readtable nil)))
    (dolist (character '(#\= #\# #\S #\s #\A #\a #\.))
      (set-dispatch-macro-character #\# character #'refuse-reader-macro table))
    (dolist (character '(#\( #\* #\R #\r))
      (let ((original (get-dispatch-macro-character #\# character table)))
        (when original
          (set-dispatch-macro-character #\# character
                                        (bounded-reader-macro original) table))))
    table))

(declaim (ftype (function (t) list) file-manifests))

(defun file-manifests (path)
  "Return the manifests PATH holds, in the order they appear.

A file that will not read signals a configuration error naming the file: the
caller is a verification path, and a silent empty list would report a broken
plugin as an absent one.

The file is read with MANIFEST-READTABLE into a package made for this read and
deleted after it, so an agent file cannot add a symbol to a package the
supervisor runs. A form nested deep enough to exhaust the stack is a
STORAGE-CONDITION and not an ERROR, so the handler names SERIOUS-CONDITION: an
uncaught one would end the supervisor."
  (let ((package (make-package (format nil "ENCHIRIDION-MANIFEST-~D"
                                       (random most-positive-fixnum))
                               :use '(:cl))))
    (unwind-protect
         (handler-case
             (with-open-file (stream path :direction :input :external-format :utf-8)
               (when (> (file-length stream) +manifest-file-limit+)
                 (error "the file is larger than ~D bytes" +manifest-file-limit+))
               (let ((*read-eval* nil)
                     (*readtable* (manifest-readtable))
                     (*package* package)
                     (manifests '()))
                 (loop for form = (read stream nil :eof)
                       until (eq form :eof)
                       when (plugin-form-p form)
                         do (push (plugin-form-manifest form) manifests))
                 (nreverse manifests)))
           (serious-condition (condition)
             (error 'enchiridion.errors:configuration-error
                    :key :plugin
                    :detail (format nil "~A will not read: ~A"
                                    (file-namestring path) condition))))
      (delete-package package))))

(defun plugin-manifests (paths)
  "Return the manifest of every plugin in PATHS, in file order.

PATHS is a list of pathnames or one pathname. This is the only thing the
supervisor reads of an agent file."
  (loop for path in (if (listp paths) paths (list paths))
        append (file-manifests path)))
