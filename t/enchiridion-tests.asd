;;;; enchiridion-tests.asd --- The test systems.
;;;;
;;;; Two systems, because they run at different times from different places.
;;;; enchiridion-tests is the suite every commit passes.
;;;; enchiridion-tests/property is slower and separate, so a five second check
;;;; does not turn into a five minute one.
;;;;
;;;; The system is named enchiridion-tests because that is what ASDF matches
;;;; against the file name. A secondary system defined here has to be named
;;;; enchiridion-tests/<something>; ASDF says so and means it.
;;;;
;;;; There is no outer module for t. This file already lives in t, so an outer
;;;; module named t would resolve the components to t/t and find nothing.
;;;;
;;;; :default-component-class is on every module for the reason given in
;;;; enchiridion.asd: it is how ASDF 3.3 is told the extension is .cl.

(defsystem "enchiridion-tests"
  :description "Unit tests for enchiridion"
  :depends-on ("enchiridion" "rove")
  :serial t
  :components
  ((:module "support"
    :serial t
    :default-component-class "cl-source-file.cl"
    :components
    ((:file "rove-bridge")))
   (:module "core"
    :serial t
    :default-component-class "cl-source-file.cl"
    :components
    ((:file "errors-test")
     (:file "compat-test")
     (:file "config-test")
     (:file "llm-test")
     (:file "blocks-test")
     (:file "store-test")
     (:file "tiers-test")
     (:file "kernel-test")
     (:file "schema-test")
     (:file "registry-test")
     (:file "pipe-test")
     (:file "file-test")
     (:file "broker-test")
     (:file "builtin-test")
     (:file "tool-loop-test")
     (:file "seed-test")
     (:file "secrets-test"))))

  ;; Every suite rove collected is run, and the count is checked first. The
  ;; obvious implementation, (rove:run "enchiridion-tests"), finds nothing
  ;; here, because rove maps source files to packages by .lisp extension and
  ;; this project uses .cl. It would report success having run nothing.
  :perform
  (test-op (operation component)
    (declare (ignore operation component))
    (finish-output)
    (let ((count (uiop:symbol-call :enchiridion-rove-bridge 'run-suites)))
      (format t "~&enchiridion-tests: ~D tests passed.~%" count)
      (finish-output)))

  :around-compile
  (lambda (compile-function)
    (handler-bind ((warning #'error))
      (funcall compile-function))))

(defsystem "enchiridion-tests/property"
  :description "Property tests for enchiridion"
  :depends-on ("enchiridion-tests" "cl-quickcheck")
  :serial t
  :components
  ((:module "property"
    :serial t
    :default-component-class "cl-source-file.cl"
    :components
    ((:file "seed-property")
     (:file "prompt-property"))))

  :perform
  (test-op (operation component)
    (declare (ignore operation component))
    (finish-output)
    (let ((count (uiop:symbol-call :enchiridion-rove-bridge 'run-suites)))
      (format t "~&enchiridion-tests/property: ~D tests passed.~%" count)
      (finish-output)))

  :around-compile
  (lambda (compile-function)
    (handler-bind ((warning #'error))
      (funcall compile-function))))