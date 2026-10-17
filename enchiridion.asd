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
  ;;
  ;; dbi and dbd-sqlite3 are the SQLite binding the memory store opens. The
  ;; driver is named rather than left to DBI's own loader, so opening a store
  ;; never depends on a system load inside a query.
  :serial t
  :depends-on ("alexandria" "cl-ppcre" "dexador" "com.inuoe.jzon"
               "cl-jschema" "usocket" "bordeaux-threads"
               "dbi" "dbd-sqlite3")
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
        ((:file "blocks")
         (:file "store")
         (:file "tiers")
         (:file "seed")))
       (:module "tools"
        :serial t
        :default-component-class "cl-source-file.cl"
        :components
        ((:file "schema")
         (:file "registry")
         (:file "pipe")
         (:file "broker")
         (:module "builtin"
          :serial t
          :default-component-class "cl-source-file.cl"
          :components
          ((:file "file")
           (:file "shell")
           (:file "search")
           (:file "blockops")
           (:file "meta")
           (:file "web")
           (:file "register")))))
       (:file "kernel"))))))

  ;; A warning is a failure. Style warnings nobody reads are warnings nobody
  ;; fixes, and #check is the gate every commit passes through, so the gate
  ;; has to actually fail. The agent runs the same code path, which is why a
  ;; problem the operator can see is a problem the agent cannot hide.
  ;; A warning is a failure. Three things have to hold for that to be true.
  ;;
  ;; The handler catches a warning raised while this file compiles. The binding
  ;; makes UIOP:COMPILE-FILE*, which decides whether a file's warnings are
  ;; fatal, treat them as fatal. :OVERRIDE catches the warning SBCL defers to
  ;; the end of the outermost compilation unit: ASDF keeps a unit open for the
  ;; whole plan, so without it an undefined function in this file is reported
  ;; after this hook returned and no handler is left to see it.
  ;;
  ;; The binding is scoped to this one file, so a dependency that compiles with
  ;; a warning of its own does not stop this system's build.
  :around-compile
  (lambda (compile-function)
    (handler-bind ((warning #'error))
      (let ((asdf:*compile-file-warnings-behaviour* :error))
        (with-compilation-unit (:override t)
          (funcall compile-function)))))

  :in-order-to ((test-op (test-op "enchiridion-tests"))))

;;;; src/main.cl is the script the wrapper runs with --script. It is not a
;;;; system component because loading a system must never start an agent, and
;;;; this file's top level form is the program. #check compiles it explicitly,
;;;; so it is still covered by the gate.