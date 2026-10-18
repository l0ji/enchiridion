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

(declaim (ftype (function (t) list) file-manifests))

(defun file-manifests (path)
  "Return the manifests PATH holds, in the order they appear.

A file that will not read signals a configuration error naming the file: the
caller is a verification path, and a silent empty list would report a broken
plugin as an absent one."
  (handler-case
      (with-open-file (stream path :direction :input :external-format :utf-8)
        (let ((*read-eval* nil)
              (*package* (find-package :enchiridion.plugin))
              (manifests '()))
          (loop for form = (read stream nil :eof)
                until (eq form :eof)
                when (plugin-form-p form)
                  do (push (plugin-form-manifest form) manifests))
          (nreverse manifests)))
    (error (condition)
      (error 'enchiridion.errors:configuration-error
             :key :plugin
             :detail (format nil "~A will not read: ~A"
                             (file-namestring path) condition)))))

(defun plugin-manifests (paths)
  "Return the manifest of every plugin in PATHS, in file order.

PATHS is a list of pathnames or one pathname. This is the only thing the
supervisor reads of an agent file."
  (loop for path in (if (listp paths) paths (list paths))
        append (file-manifests path)))
