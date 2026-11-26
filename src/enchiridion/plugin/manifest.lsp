;;;; manifest.lsp --- Data-only plugin manifest reader.
;;;;
;;;; Reads top-level (define-plugin ...) forms with *READ-EVAL* NIL and a
;;;; restricted readtable so the supervisor extracts tool schemas without executing code.

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
  "Extract (:name :description :schema) plist from a (define-plugin ...) form."
  (multiple-value-bind (name description schema)
      (tool-form-parts (plugin-form-tool form))
    (list :name (string-downcase (string (or name (plugin-form-name form))))
          :description (if (stringp description) description "")
          :schema (or schema '(:object :properties ())))))

(defparameter +manifest-file-limit+ (* 256 1024)
  "Maximum agent file size in bytes for manifest reading.")

(defparameter +manifest-numeric-argument-limit+ 4096
  "Maximum numeric dispatch-macro argument (e.g. #4096(...)) allowed during manifest reads.")

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
  "Return a restricted readtable for untrusted agent files.
Rejects #=, ##, #S, #A, and #. (preventing circular structures, constructor calls,
and arbitrary allocations) and bounds numeric arguments on #(, #*, and #R."
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
  "Read manifests from PATH using MANIFEST-READTABLE in a temporary package.
Signals CONFIGURATION-ERROR on any SERIOUS-CONDITION (including stack overflow)."
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
  "Return all plugin manifests from PATHS (a pathname or list of pathnames) in order."
  (loop for path in (if (listp paths) paths (list paths))
        append (file-manifests path)))
