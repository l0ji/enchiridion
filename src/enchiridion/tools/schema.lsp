;;;; schema.lsp --- Lisp tool schema DSL, JSON Schema conversion, and cl-jschema validation.
;;;;
;;;; Example: (:object :required (:path) :properties ((:path :string) (:from :integer)))

(in-package #:enchiridion.tools)

(defparameter *schema-budget* 2000
  "Maximum total estimated tokens allowed across all registered tool schemas.")

(declaim (ftype (function (t) hash-table) schema-to-json))

(defun schema-to-json (schema)
  "Convert Lisp SCHEMA (keyword type or (:object ...) / (:array ...) form) to a JZON hash table.
Object schemas always set additionalProperties to false and include a properties table."
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
          ;; Always emit an empty properties table; cl-jschema expects a hash table when additionalProperties is false.
          (setf (gethash "properties" table) (make-hash-table :test #'equal))
          (loop for (key value) on (rest schema) by #'cddr
                do (case key
                     (:required
                      (setf (gethash "required" table)
                            (mapcar (lambda (name)
                                      (string-downcase (symbol-name name)))
                                    (coerce value 'list))))
                     (:properties
                      (let ((properties (make-hash-table :test #'equal)))
                        (dolist (pair value)
                          (setf (gethash (string-downcase (symbol-name (first pair)))
                                         properties)
                                (schema-to-json (second pair))))
                        (setf (gethash "properties" table) properties)))
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
  "Normalize ARGUMENTS (NIL, hash table, or plist) to a string-keyed hash table for JZON/cl-jschema."
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
  "Validate ARGUMENTS against SCHEMA via cl-jschema, returning T or signaling SCHEMA-ERROR
with joined cl-jschema error messages."
  ;; cl-jschema signals a type error on object schemas with no properties;
  ;; handle zero-argument objects directly since additionalProperties is false.
  (when (and (consp schema)
             (eq (first schema) :object)
             (null (getf (rest schema) :properties))
             (null (getf (rest schema) :required)))
    (let ((value (arguments-to-json arguments)))
      (unless (zerop (hash-table-count value))
        (error 'enchiridion.errors:schema-error
               :detail (format nil "This tool takes no arguments, but it was given ~{~A~^, ~}."
                               (loop for key being the hash-keys of value collect key))))
      (return-from validate-arguments t)))
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
