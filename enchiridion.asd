;;;; enchiridion.asd --- The core system.
;;;;
;;;; The core is frozen at run time. It holds the loop, the LLM clients, the
;;;; plugin loader, the memory engine, and the supervisor, and it never
;;;; changes shape. The agent rewrites what lives under agents/, never this.
;;;;
;;;; Every module carries :default-component-class "cl-source-file.cl". That
;;;; component class is the one ASDF 3.3 provides for the .cl extension, and
;;;; the plan fixes the extension. Without it ASDF resolves (:file "packages")
;;;; to packages.lisp and fails on a missing TRUENAME. It has to be on the
;;;; module: there is no per-file spelling that works, and
;;;; asdf::*default-component-class* is not in ASDF/INTERFACE in this version.

(defsystem "enchiridion"
  :description "An autonomous agent harness written in Common Lisp"
  :author "penny <penny@hexmani.ac>"
  :license "0BSD"
  :version "0.1.0"
  :homepage "https://github.com/penny/enchiridion"

  ;; Deterministic load order. Packages before the files that use them,
  ;; conditions before the code that signals them.
  :serial t
  :depends-on ("alexandria" "cl-ppcre" "dexador" "com.inuoe.jzon")
  :components
  ((:module "src"
    :serial t
    :default-component-class "cl-source-file.cl"
    :components
    ((:module "enchiridion"
      :serial t
      :default-component-class "cl-source-file.cl"
      :components
      ((:file "packages")
       (:file "compat")
       (:file "config")
       (:file "errors")
       (:module "llm"
        :serial t
        :default-component-class "cl-source-file.cl"
        :components
        ((:file "secrets")
         (:file "protocol")
         (:file "openai")))
       (:module "memory"
        :serial t
        :default-component-class "cl-source-file.cl"
        :components
        ((:file "seed"))))))))

  ;; A warning is a failure. Style warnings nobody reads are warnings nobody
  ;; fixes, and #check is the gate every commit passes through, so the gate
  ;; has to actually fail. The agent runs the same code path, which is why a
  ;; problem the operator can see is a problem the agent cannot hide.
  :around-compile
  (lambda (compile-function)
    (handler-bind ((warning #'error))
      (funcall compile-function)))

  :in-order-to ((test-op (test-op "enchiridion-tests"))))

;;;; src/main.cl is the script the wrapper runs with --script. It is not a
;;;; system component because loading a system must never start an agent, and
;;;; this file's top level form is the program. #check compiles it explicitly,
;;;; so it is still covered by the gate.