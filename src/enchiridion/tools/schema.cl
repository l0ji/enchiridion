;;;; schema.cl --- One declaration, two jobs: the model schema and the check.
;;;;
;;;; A tool's schema is a small Lisp form, not a JSON string. The same form
;;;; builds the JSON Schema sent to the model and validates the arguments that
;;;; come back. One source means the two cannot drift.
;;;;
;;;; The forms are deliberately close to JSON Schema:
;;;;
;;;;   (:object :required (:path) :properties ((:path :string)
;;;;                                             (:from :integer)
;;;;                                             (:to :integer)))
;;;;
;;;; The JSON conversion is in this file; validation is delegated to
;;;; cl-jschema, which is the one JSON Schema implementation in the tree.

(in-package #:enchiridion.tools)

(defparameter *schema-budget* 2000
  "The token budget for all tool schemas sent with a prompt. It is a soft
budget: the report says what is over, and the caller decides whether to drop a
tool or raise the cap.")

(declaim (ftype (function (t) hash-table) schema-to-json))

(defun schema-to-json (schema)
  "Return SCHEMA as a hash table that JZON writes as JSON Schema.

A keyword is a type. A list is a compound form whose head names the type and
whose tail is keyword arguments. The object form adds additionalProperties
false, because a tool that ignores a misspelled argument is a tool that runs
with the wrong argument and reports success."
  (cond
    ((keywordp schema)
     (let ((table (make-hash-table :test #'equal)))
       (setf (gethash "type" table) (string-downcase (symbol-name schema)))
       table))
    ((consp schema)
     (case (first schema)
       (:object
        (let ((table (make-hash-table :test #'equal)))
          (setf (gethash "type" table) "object")
          (setf (gethash "additionalProperties" table) nil)
          (loop for (key value) on (rest schema) by #'cddr
                do (case key
                     (:required
                      (setf (gethash "required" table)
                            (mapcar (lambda (name)
                                      (string-downcase (symbol-name name)))
                                    (coerce value 'list))))
                     (:properties
                      (when value
                        (let ((properties (make-hash-table :test #'equal)))
                          (dolist (pair value)
                            (setf (gethash (string-downcase (symbol-name (first pair)))
                                           properties)
                                  (schema-to-json (second pair))))
                          (setf (gethash "properties" table) properties))))
                     (otherwise
                      (error 'enchiridion.errors:schema-error
                             :detail (format nil "Unknown object schema key ~S." key)))))
          table))
       (:array
        (let ((table (make-hash-table :test #'equal)))
          (setf (gethash "type" table) "array")
          (loop for (key value) on (rest schema) by #'cddr
                do (case key
                     (:items (setf (gethash "items" table) (schema-to-json value)))
                     (otherwise
                      (error 'enchiridion.errors:schema-error
                             :detail (format nil "Unknown array schema key ~S." key)))))
          table))
       (otherwise
        (error 'enchiridion.errors:schema-error
               :detail (format nil "Unknown schema form ~S." schema)))))
    (t
     (error 'enchiridion.errors:schema-error
            :detail (format nil "A schema is a keyword or a list, not ~S." schema)))))

(declaim (ftype (function (t) string) schema-json-string))

(defun schema-json-string (schema)
  "Return SCHEMA as the JSON text sent to the model."
  (com.inuoe.jzon:stringify (schema-to-json schema)))

(declaim (ftype (function (t) (integer 0 *)) schema-tokens))

(defun schema-tokens (schema)
  "Return a cheap token estimate for SCHEMA, one token per four JSON characters."
  (ceiling (length (schema-json-string schema)) 4))

(defun arguments-to-json (arguments)
  "Return ARGUMENTS as the hash table shape JZON and cl-jschema expect.
A property list gets string keys. A hash table is already what a parsed tool
call holds and is passed through."
  (cond
    ((null arguments) (make-hash-table :test #'equal))
    ((hash-table-p arguments) arguments)
    ((listp arguments)
     (let ((table (make-hash-table :test #'equal)))
       (loop for (key value) on arguments by #'cddr
             do (setf (gethash (string-downcase (string key)) table) value))
       table))
    (t
     (error 'enchiridion.errors:schema-error
            :detail (format nil "Tool arguments must be a plist or a hash table, not ~S."
                            arguments)))))

(declaim (ftype (function (t t) boolean) validate-arguments))

(defun validate-arguments (schema arguments)
  "Return T when ARGUMENTS matches SCHEMA. Signal SCHEMA-ERROR otherwise.

CL-JSCHEMA signals INVALID-JSON with one or more INVALID-JSON-VALUE children;
the children carry the JSON pointer and the reason, and both go into the detail
so the model can correct the call instead of guessing."
  (let ((parsed-schema (cl-jschema:parse (schema-json-string schema)))
        (value (arguments-to-json arguments)))
    (handler-case
        (progn (cl-jschema:validate parsed-schema value) t)
      (cl-jschema:invalid-json (condition)
        (error 'enchiridion.errors:schema-error
               :detail (format nil "~{~A~^; ~}"
                               (mapcar #'princ-to-string
                                       (cl-jschema:invalid-json-errors condition))))))))

(declaim (ftype (function (t) (or null string)) schema-error-message))

(defun schema-error-message (condition)
  "Return the free-form detail of a SCHEMA-ERROR, or NIL."
  (enchiridion.errors:error-detail condition))
