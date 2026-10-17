;;;; registry-test.cl --- Registration, schema budget, and dispatch.
;;;;
;;;; A tool call has three failure points: the name is missing, the arguments
;;;; do not match the schema, or the handler raises. Each has its own condition,
;;;; so the model gets a correction rather than a generic crash.

(defpackage #:enchiridion-registry-test
  (:use #:cl)
  (:import-from #:rove #:deftest #:ok #:ng #:testing #:signals)
  (:import-from #:enchiridion.tools #:define-tool)
  (:export #:run))

(in-package #:enchiridion-registry-test)

(defun echo-tool ()
  (enchiridion.tools:make-tool
   :name "echo"
   :description "Echo one string."
   :schema '(:object :required (:text) :properties ((:text :string)))
   :handler (lambda (arguments)
              (gethash "text" arguments))))

(deftest a-tool-can-be-registered-and-found ()
  (enchiridion.tools:clear-registry)
  (enchiridion.tools:register-tool (echo-tool))
  (ok (enchiridion.tools:find-tool "echo"))
  (ok (member "echo" (enchiridion.tools:tool-names) :test #'string=)))

(deftest define-tool-registers-at-run-time ()
  (enchiridion.tools:clear-registry)
  (define-tool temporary
    :schema (:object :required (:value) :properties ((:value :integer)))
    :description "A temporary tool."
    :handler (lambda (arguments) (gethash "value" arguments)))
  (ok (enchiridion.tools:find-tool "temporary")))

(deftest dispatch-checks-the-name-and-the-schema ()
  (enchiridion.tools:clear-registry)
  (enchiridion.tools:register-tool (echo-tool))
  (ok (string= "hello" (enchiridion.tools:dispatch "echo" (list :text "hello"))))
  (testing "a missing name is not-found"
    (ok (signals (enchiridion.tools:dispatch "missing" nil)
                 'enchiridion.errors:not-found)))
  (testing "a missing argument is a schema error"
    (ok (signals (enchiridion.tools:dispatch "echo" nil)
                 'enchiridion.errors:schema-error)))
  (testing "a handler error becomes a tool error"
    (enchiridion.tools:register-tool
     (enchiridion.tools:make-tool
      :name "broken"
      :description "Always fails."
      :schema '(:object :properties ((:unused :string)))
      :handler (lambda (arguments)
                 (declare (ignore arguments))
                 (error "the tool fell over"))))
    (ok (signals (enchiridion.tools:dispatch "broken" nil)
                 'enchiridion.errors:tool-error))))

(deftest the-schema-budget-is-visible-and-enforced ()
  (enchiridion.tools:clear-registry)
  (enchiridion.tools:register-tool (echo-tool))
  (let ((report (enchiridion.tools:schema-budget-report)))
    (ok (plusp (getf report :used)))
    (ok (= (getf report :budget) enchiridion.tools:*schema-budget*)))
  (let ((enchiridion.tools:*schema-budget* 0))
    (ok (signals (enchiridion.tools:registry-schema)
                 'enchiridion.errors:budget-exceeded))))

(deftest the-model-facing-registry-is-json ()
  (enchiridion.tools:clear-registry)
  (enchiridion.tools:register-tool (echo-tool))
  (let ((json (enchiridion.tools:registry-schema)))
    (ok (search "\"name\":\"echo\"" json))
    (ok (search "\"parameters\"" json))))
