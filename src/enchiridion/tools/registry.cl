;;;; registry.cl --- Tool registration, schema budget, and dispatch.
;;;;
;;;; A tool is a name, a description, one schema, and one handler. The schema
;;;; does two jobs: it is sent to the model as JSON, and it validates the call
;;;; that comes back. Registration is a hash table, not a list, because a
;;;; lookup happens on every tool call and a name collision has to be visible
;;;; rather than silently shadowed.

(in-package #:enchiridion.tools)

(defstruct (tool (:constructor make-tool))
  (name "" :type string)
  (description "" :type string)
  (schema nil :type t)
  (handler nil :type t)
  (self-test nil :type t)
  (generation 0 :type (integer 0 *))
  (broker-side-p nil :type boolean))

(defparameter *registry* (make-hash-table :test #'equal)
  "Tool name to TOOL. The name is a lowercase string, so a symbol and a string
are the same lookup.")

(declaim (ftype (function () hash-table) registry))

(defun registry ()
  "Return the live tool registry."
  *registry*)

(declaim (ftype (function (t) string) normalize-tool-name))

(defun normalize-tool-name (name)
  "Return NAME as the lowercase string used by the registry."
  (string-downcase (string name)))

(declaim (ftype (function (tool) tool) register-tool))

(defun register-tool (tool)
  "Add TOOL to the registry and return it. A later definition replaces the
earlier one, which is what a reload needs."
  (check-type tool tool)
  (setf (gethash (normalize-tool-name (tool-name tool)) *registry*) tool)
  tool)

(defmacro define-tool (name &key schema description handler self-test)
  "Register a tool and keep its schema as a Lisp form.

The schema is quoted here and converted on demand. Keeping the form rather
than a prebuilt JSON string means a tool can be introspected and the budget
counted without a parse, and it means a test can inspect the declaration."
  `(register-tool
    (make-tool :name ,(normalize-tool-name name)
               :description ,description
               :schema ',schema
               :handler ,handler
               :self-test ,self-test)))

(declaim (ftype (function (t) (or null tool)) find-tool))

(defun find-tool (name)
  "Return the tool called NAME, or NIL."
  (gethash (normalize-tool-name name) *registry*))

(declaim (ftype (function () list) tool-names))

(defun tool-names ()
  "Return every registered tool name, sorted."
  (sort (loop for name being the hash-keys of *registry* collect name)
        #'string<))

(declaim (ftype (function () list) list-tools))

(defun list-tools ()
  "Return every registered tool, sorted by name."
  (mapcar #'find-tool (tool-names)))

(declaim (ftype (function (t) boolean) unregister-tool))

(defun unregister-tool (name)
  "Remove NAME from the registry. Return T when it was there."
  (not (null (remhash (normalize-tool-name name) *registry*))))

(declaim (ftype (function () null) clear-registry))

(defun clear-registry ()
  "Remove every tool. Tests use this; a running agent must not."
  (clrhash *registry*)
  nil)

(declaim (ftype (function () (integer 0 *)) registry-schema-tokens))

(defun registry-schema-tokens ()
  "Return the token estimate for every registered tool schema."
  (loop for tool in (list-tools)
        sum (schema-tokens (tool-schema tool))))

(declaim (ftype (function () list) schema-budget-report))

(defun schema-budget-report ()
  "Return the schema budget as a plist of :USED, :BUDGET, and :REMAINING."
  (let ((used (registry-schema-tokens)))
    (list :used used
          :budget *schema-budget*
          :remaining (- *schema-budget* used))))

(defun tool-definition (tool)
  "Return TOOL as the function object an OpenAI tool definition wraps."
  (let ((entry (make-hash-table :test #'equal)))
    (setf (gethash "name" entry) (tool-name tool))
    (setf (gethash "description" entry) (tool-description tool))
    (setf (gethash "parameters" entry) (schema-to-json (tool-schema tool)))
    entry))

(declaim (ftype (function () list) registry-tool-definitions))

(defun registry-tool-definitions ()
  "Return every tool as a name, description, and parameter object.

The budget is checked here because this is the object the kernel sends. A
registry that grew past the cap reports it rather than silently spending the
context on schemas."
  (let ((used (registry-schema-tokens)))
    (when (> used *schema-budget*)
      (error 'enchiridion.errors:budget-exceeded
             :spent used
             :cap *schema-budget*
             :window :schema))
    (loop for tool in (list-tools) collect (tool-definition tool))))

(declaim (ftype (function () string) registry-schema))

(defun registry-schema ()
  "Return every tool as one JSON array for the model.

The schema budget is checked here, at the moment the model-facing object is
built. A tool registry that grows past the cap reports it rather than silently
spending the context on schemas."
  (com.inuoe.jzon:stringify (registry-tool-definitions)))

(defun dispatch (name arguments &key generation)
  "Find the tool NAME, validate ARGUMENTS, and call its handler.

A missing tool is NOT-FOUND, a bad argument is SCHEMA-ERROR, and a handler
that raises becomes TOOL-ERROR with the tool's name. The caller never has to
guess which layer failed."
  (let ((tool (find-tool name)))
    (unless tool
      (error 'enchiridion.errors:not-found :kind "tool" :name name))
    (when (and generation (/= generation (tool-generation tool)))
      (error 'enchiridion.errors:configuration-error
             :key :generation
             :detail (format nil "Tool ~A is generation ~D, not ~D."
                             (tool-name tool)
                             (tool-generation tool)
                             generation)))
    (let ((normalized (arguments-to-json arguments)))
      (validate-arguments (tool-schema tool) normalized)
      (handler-case
          (funcall (tool-handler tool) normalized)
        (enchiridion.errors:enchiridion-error (condition)
          (error condition))
        (error (condition)
          (error 'enchiridion.errors:tool-error
                 :tool (tool-name tool)
                 :detail (princ-to-string condition)))))))
