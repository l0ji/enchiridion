;;;; reload-test.lsp --- The reload transaction main drives.
;;;;
;;;; main.lsp is a script, so the test image has none of it. These tests read the
;;;; definitions they need out of the file and evaluate them, the way the startup
;;;; tests do, and then drive the real transaction: snapshot, stage, verify,
;;;; load, publish. The broker is a real in-process broker with a child hook, so
;;;; the digest and the generation travel over the socket and through the reply
;;;; fields, and every failure path is asked whether it left the live table and
;;;; the context generation exactly where they were.

(defpackage #:enchiridion-reload-test
  (:use #:cl)
  (:import-from #:rove #:deftest #:ok #:ng #:testing #:signals)
  (:export #:run))

(in-package #:enchiridion-reload-test)

;;;; Reading main.lsp without running it.
;;;;
;;;; A compiled file is read one form at a time, so the package and the names
;;;; below have to exist before the reader reaches the tests. The package is
;;;; read out of main.lsp itself rather than restated here: a copy of it would
;;;; drift, and the point of this file is to drive the definitions in main.lsp.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package :enchiridion.main)
    (let* ((*read-eval* nil)
           (*package* (find-package :cl-user))
           (form (with-open-file
                     (stream (asdf:system-relative-pathname "enchiridion" "src/main.lsp"))
                   (loop for candidate = (read stream nil nil)
                         while candidate
                         when (and (consp candidate)
                                   (eq (first candidate) 'defpackage)
                                   (string= (string (second candidate))
                                            "ENCHIRIDION.MAIN"))
                           return candidate))))
      (unless form
        (error "src/main.lsp no longer opens with a DEFPACKAGE."))
      (eval form))))

;; The definitions are evaluated at load time, so a call to one of them from
;; this file is an undefined function while the file compiles. These bare
;; declarations are what the startup tests use for the same reason.
(declaim (ftype function
          enchiridion.main::%make-context
          enchiridion.main::context-generation
          enchiridion.main::load-agent-generation
          enchiridion.main::broker-reload))

(defun main-forms (package-name)
  "Return every top-level form of src/main.lsp, read in PACKAGE-NAME."
  (let ((*read-eval* nil)
        (*package* (find-package package-name)))
    (with-open-file (stream (asdf:system-relative-pathname "enchiridion" "src/main.lsp"))
      (loop for form = (read stream nil nil)
            while form
            collect form))))

(defun main-definition-p (form name)
  "Return T when FORM is the DEFUN that defines NAME."
  (and (consp form)
       (eq (first form) 'defun)
       (symbolp (second form))
       (string= (symbol-name (second form)) name)))

(defun main-struct-p (form name)
  "Return T when FORM is the DEFSTRUCT that defines NAME."
  (and (consp form)
       (eq (first form) 'defstruct)
       (let ((head (second form)))
         (and head
              (string= (symbol-name (if (consp head) (first head) head)) name)))))

(defparameter +main-definitions+
  '("AGENT-UID" "AGENT-GID" "CONDITION-LINE" "STAGE-AGENT-PROXIES"
    "LOAD-AGENT-GENERATION" "BROKER-RELOAD")
  "The functions of src/main.lsp the reload transaction needs.")

(defun load-main-definitions ()
  "Define the parts of src/main.lsp the reload transaction needs, and nothing else.
Every form is read and evaluated in ENCHIRIDION.MAIN, so each symbol lands where
a real load would put it: a DEFSTRUCT evaluated in another package defines its
constructor and not its accessors. The entry point is never reached, because this
reads definitions and evaluates them, which is what the startup tests do for the
same reason."
  (unless (find-package :enchiridion.main)
    (error "src/main.lsp no longer opens with a DEFPACKAGE."))
  (let ((*package* (find-package :enchiridion.main)))
    (dolist (form (main-forms :enchiridion.main))
      (when (or (main-struct-p form "CONTEXT")
                (some (lambda (name) (main-definition-p form name)) +main-definitions+))
        (eval form)))))

(eval-when (:load-toplevel :execute)
  (load-main-definitions))

;;;; Fixtures.

(defmacro with-scratch-directory ((name) &body body)
  "Bind NAME to a fresh directory under the build directory, run BODY, and
remove the directory afterwards."
  `(let ((,name (uiop:ensure-directory-pathname
                 (merge-pathnames
                  (format nil "enchiridion-reload-test-~D/" (random most-positive-fixnum))
                  (uiop:ensure-directory-pathname *default-pathname-defaults*)))))
     (unwind-protect
          (progn ,@body)
       (uiop:delete-directory-tree ,name :validate t :if-does-not-exist :ignore))))

(defun write-source (directory relative text)
  "Write TEXT to RELATIVE under DIRECTORY and return the pathname."
  (let ((path (merge-pathnames relative (uiop:ensure-directory-pathname directory))))
    (ensure-directories-exist path)
    (with-open-file (stream path :direction :output
                                 :if-exists :supersede
                                 :if-does-not-exist :create
                                 :external-format :utf-8)
      (write-string text stream))
    path))

(defun plugin-source (name)
  "Return a plugin file that declares one tool called NAME."
  (format nil "(defpackage #:reload-test-~A (:use #:cl))
(in-package #:reload-test-~A)

(enchiridion.plugin:define-plugin ~A
  :tool (enchiridion.plugin:tool
         \"~A\" \"A tool a reload test publishes.\"
         (:object :properties ()))
  :handler #'identity
  :self-test #'(lambda () t))
"
          name name name name))

(defun scratch-socket ()
  (merge-pathnames (format nil "enchiridion-reload-~D.sock" (random most-positive-fixnum))
                   #p"/tmp/"))

(defmacro with-live-registry (() &body body)
  "Run BODY and put the live tool registry, plugins, and generation back."
  (let ((tools (gensym "TOOLS"))
        (plugins (gensym "PLUGINS"))
        (generation (gensym "GENERATION")))
    `(let ((,tools (enchiridion.tools:list-tools))
           (,plugins (copy-list (enchiridion.plugin:plugin-registry)))
           (,generation (enchiridion.plugin:current-generation)))
       (unwind-protect
            (progn ,@body)
         (enchiridion.tools:clear-registry)
         (dolist (tool ,tools) (enchiridion.tools:register-tool tool))
         (setf enchiridion.plugin:*generation* ,generation
               enchiridion.plugin::*plugins* ,plugins)))))

(defmacro with-redefined ((name original function) &body body)
  "Run BODY with the global definition of NAME replaced by FUNCTION.
ORIGINAL is bound to the definition being replaced, so a replacement can still
call it."
  `(let ((,original (symbol-function ',name)))
     (unwind-protect
          (progn (setf (symbol-function ',name) ,function)
                 ,@body)
       (setf (symbol-function ',name) ,original))))

(defmacro with-test-broker ((broker hook) &body body)
  "Run BODY with an in-process BROKER whose child hook is HOOK."
  `(let ((,broker (enchiridion.tools.broker:make-broker :socket (scratch-socket)
                                                        :timeout 5)))
     (unwind-protect
          (progn
            (setf enchiridion.tools.broker:*load-generation-function* ,hook)
            (enchiridion.tools.broker:broker-start ,broker :in-process t)
            ,@body)
       (enchiridion.tools.broker:broker-stop ,broker)
       (setf enchiridion.tools.broker:*load-generation-function* nil))))

(defun child-hook (state)
  "Return a load hook that answers the way the broker child does.

It records the digest and generation the request carried, publishes the digest
it was handed, and refuses a directory that no longer matches that digest, which
is the loader's own check reached through :SOURCE-DIGESTS. STATE decides the
rest: :REFUSE-P and :REFUSE-REPORT make it refuse, and :PUBLISHED-DIGESTS makes
it answer with a digest the supervisor did not verify."
  (lambda (directory generation)
    (let* ((requested enchiridion.tools.broker::*load-source-digests*)
           (current (ignore-errors
                      (enchiridion.plugin:source-snapshot-digest
                       (enchiridion.plugin:snapshot-sources directory)))))
      (setf (gethash :digests state) requested
            (gethash :generation state) generation
            (gethash :calls state) (1+ (or (gethash :calls state) 0)))
      (cond
        ((gethash :refuse-p state)
         (values nil (or (gethash :refuse-report state) "refused")
                 requested generation))
        ((and requested current (not (string= requested current)))
         (values nil "the agent source changed since it was verified"
                 current generation))
        ((gethash :published-digests state)
         (values t (format nil "generation ~D loaded" generation)
                 (gethash :published-digests state) generation))
        ((gethash :published-generation state)
         (values t (format nil "generation ~D loaded" generation)
                 requested (gethash :published-generation state)))
        (t
         (values t (format nil "generation ~D loaded" generation)
                 requested generation))))))

(defun make-reload-context (directory broker &key (generation 0))
  "Return a main.lsp context for DIRECTORY, with BROKER and GENERATION."
  (enchiridion.main::%make-context :directory (namestring (uiop:ensure-directory-pathname directory))
                                   :config (enchiridion:default-config)
                                   :broker broker
                                   :generation generation))

(defun refusal-of (thunk)
  "Call THUNK and return the condition it signalled, or NIL."
  (handler-case (progn (funcall thunk) nil)
    (error (condition) condition)))

(defmacro with-stub-verifier ((state) &body body)
  "Run BODY with the verification child replaced by a recorder.
The stub records the digest it was handed and answers from STATE: it fails when
:VERIFY-FAILS-P is set, reports :VERIFY-REPORT, and calls :MUTATE first, which is
how a test changes the tree between the two children."
  (let ((original (gensym "ORIGINAL")))
    `(let ((,original (symbol-function 'enchiridion.tools.broker:broker-verify-plugin)))
       (unwind-protect
            (progn
              (setf (symbol-function 'enchiridion.tools.broker:broker-verify-plugin)
                    (lambda (directory &key (uid 1000) (gid 1000) (timeout 120) digests)
                      (declare (ignore directory uid gid timeout))
                      (setf (gethash :verify-digests ,state) digests)
                      (let ((mutate (gethash :mutate ,state)))
                        (when mutate (funcall mutate)))
                      (values (not (gethash :verify-fails-p ,state))
                              (or (gethash :verify-report ,state)
                                  "1 file compiled"))))
              ,@body)
         (setf (symbol-function 'enchiridion.tools.broker:broker-verify-plugin)
               ,original)))))

;;;; The tests.
;;;;
;;;; Every test but the last starts the same way: a scratch agent directory with
;;;; one plugin, an in-process broker whose child answers the protocol, a
;;;; verification child that answers rather than compiles, and generation 1
;;;; published through the real transaction. WITH-RELOAD-FIXTURE is that start,
;;;; so each test shows only what it does differently.

(defmacro with-reload-fixture ((context agent state) &body body)
  "Run BODY with generation 1 of AGENT published for CONTEXT.

STATE is the hash table both stub children answer from, and a test sets the keys
that make its own case fail."
  (let ((directory (gensym "DIRECTORY"))
        (broker (gensym "BROKER")))
    `(with-scratch-directory (,directory)
       (with-live-registry ()
         (let* ((,agent (merge-pathnames "agent/" ,directory))
                (,state (make-hash-table :test #'eq))
                (,context nil))
           (write-source ,agent "tools/alpha.lsp" (plugin-source "reload-alpha"))
           (with-test-broker (,broker (child-hook ,state))
             (setf ,context (make-reload-context ,agent ,broker))
             (with-stub-verifier (,state)
               (enchiridion.main::load-agent-generation ,context :generation 1)
               ,@body)))))))

(defun refused-reload (context)
  "Return the condition a second load of CONTEXT signals, or NIL."
  (refusal-of (lambda ()
                (enchiridion.main::load-agent-generation context :generation 2))))

(deftest a-staging-failure-stops-before-the-broker-and-keeps-the-old-tools ()
  (with-reload-fixture (context agent state)
    (let ((tool (enchiridion.tools:find-tool "reload-alpha"))
          (registry (enchiridion.tools:registry))
          (calls (gethash :calls state)))
      (ok tool)
      (write-source agent "tools/beta.lsp" (plugin-source "reload-beta"))
      (with-redefined (enchiridion.tools:register-tool original
                       (lambda (item)
                         (when (string= "reload-beta"
                                        (enchiridion.tools:tool-name item))
                           (error "the proxy constructor refused"))
                         (funcall original item)))
        (ok (signals (enchiridion.main::load-agent-generation context :generation 2)
                     'error)))
      (testing "the broker was never asked to load the half built registry"
        (ok (= calls (gethash :calls state))))
      (testing "and the live table is the one that was already published"
        (ok (eq registry (enchiridion.tools:registry)))
        (ok (eq tool (enchiridion.tools:find-tool "reload-alpha")))
        (ng (enchiridion.tools:find-tool "reload-beta"))
        (ok (= 1 (enchiridion.main::context-generation context)))))))

(deftest a-verification-refusal-keeps-the-old-proxies ()
  (with-reload-fixture (context agent state)
    (let ((tool (enchiridion.tools:find-tool "reload-alpha"))
          (registry (enchiridion.tools:registry))
          (calls (gethash :calls state)))
      (setf (gethash :verify-fails-p state) t
            (gethash :verify-report state) "alpha.lsp: a warning is fatal")
      (let ((condition (refused-reload context)))
        (ok condition)
        (ok (search "a warning is fatal"
                    (or (enchiridion.errors:error-detail condition) ""))))
      (ok (= calls (gethash :calls state)))
      (ok (eq registry (enchiridion.tools:registry)))
      (ok (eq tool (enchiridion.tools:find-tool "reload-alpha")))
      (ok (= 1 (enchiridion.main::context-generation context))))))

(deftest a-broker-refusal-keeps-the-old-proxies ()
  (with-reload-fixture (context agent state)
    (let ((tool (enchiridion.tools:find-tool "reload-alpha"))
          (registry (enchiridion.tools:registry)))
      (setf (gethash :refuse-p state) t
            (gethash :refuse-report state) "the agent source changed while it loaded")
      (let ((condition (refused-reload context)))
        (ok condition)
        (ok (search "changed while it loaded"
                    (or (enchiridion.errors:error-detail condition) ""))))
      (ok (eq registry (enchiridion.tools:registry)))
      (ok (eq tool (enchiridion.tools:find-tool "reload-alpha")))
      (ok (= 1 (enchiridion.main::context-generation context))))))

(deftest a-reply-that-published-another-digest-keeps-the-old-proxies ()
  (with-reload-fixture (context agent state)
    (let ((tool (enchiridion.tools:find-tool "reload-alpha"))
          (registry (enchiridion.tools:registry)))
      (setf (gethash :published-digests state)
            "sha256:0000000000000000000000000000000000000000000000000000000000000000")
      (ok (refused-reload context))
      (ok (eq registry (enchiridion.tools:registry)))
      (ok (eq tool (enchiridion.tools:find-tool "reload-alpha")))
      (ok (= 1 (enchiridion.main::context-generation context))))))

(deftest a-reply-that-published-another-generation-keeps-the-old-proxies ()
  (with-reload-fixture (context agent state)
    (let ((tool (enchiridion.tools:find-tool "reload-alpha"))
          (registry (enchiridion.tools:registry)))
      (setf (gethash :published-generation state) 9)
      (ok (refused-reload context))
      (ok (eq registry (enchiridion.tools:registry)))
      (ok (eq tool (enchiridion.tools:find-tool "reload-alpha")))
      (ok (= 1 (enchiridion.main::context-generation context))))))

(deftest a-matching-publication-replaces-every-proxy ()
  (with-reload-fixture (context agent state)
    ;; Generation 1 added exactly one proxy, so the count before it is one less.
    (let ((builtins (1- (hash-table-count (enchiridion.tools:registry))))
          (tool (enchiridion.tools:find-tool "reload-alpha"))
          (registry (enchiridion.tools:registry)))
      (ok tool)
      (write-source agent "tools/beta.lsp" (plugin-source "reload-beta"))
      (multiple-value-bind (generation report)
          (enchiridion.main::load-agent-generation context :generation 2)
        (ok (= 2 generation))
        (ok (search "generation 2" report)))
      (testing "the publication is a new table with the new generation"
        (ok (not (eq registry (enchiridion.tools:registry))))
        (ok (not (eq tool (enchiridion.tools:find-tool "reload-alpha"))))
        (ok (enchiridion.tools:find-tool "reload-beta"))
        (ok (= 2 (enchiridion.main::context-generation context)))
        (ok (= (+ builtins 2) (hash-table-count (enchiridion.tools:registry)))))
      (testing "every proxy is the broker side wrapper for its generation"
        (dolist (name '("reload-alpha" "reload-beta"))
          (let ((proxy (enchiridion.tools:find-tool name)))
            (ok (enchiridion.tools:tool-broker-side-p proxy))
            (ok (= 2 (enchiridion.tools:tool-generation proxy))))))
      (testing "and the old table still holds the old proxy"
        (ok (eq tool (gethash "reload-alpha" registry)))))))

(deftest one-digest-reaches-both-children-and-a-change-refuses ()
  (with-reload-fixture (context agent state)
    (let ((tool (enchiridion.tools:find-tool "reload-alpha"))
          (registry (enchiridion.tools:registry))
          (snapshot (enchiridion.plugin:snapshot-sources agent)))
      (setf (gethash :mutate state)
            (lambda ()
              (write-source agent "tools/alpha.lsp"
                            (plugin-source "reload-alpha-rewritten"))))
      (let ((condition (refused-reload context)))
        (ok condition)
        (testing "both children were handed the snapshot main read"
          (ok (string= (enchiridion.plugin:source-snapshot-digest snapshot)
                       (gethash :verify-digests state)))
          (ok (string= (gethash :verify-digests state)
                       (gethash :digests state))))
        (testing "and the child refused the tree that changed under it"
          (ok (search "changed since it was verified"
                      (or (enchiridion.errors:error-detail condition) "")))))
      (ok (eq registry (enchiridion.tools:registry)))
      (ok (eq tool (enchiridion.tools:find-tool "reload-alpha")))
      (ok (= 1 (enchiridion.main::context-generation context))))))

(deftest an-empty-directory-unloads-both-sides ()
  (with-reload-fixture (context agent state)
    ;; Generation 1 added exactly one proxy, so the count before it is one less.
    (let ((builtins (1- (hash-table-count (enchiridion.tools:registry)))))
      (ok (enchiridion.tools:find-tool "reload-alpha"))
      (delete-file (merge-pathnames "tools/alpha.lsp" agent))
      (let ((verify-digests (gethash :verify-digests state)))
        (multiple-value-bind (generation report)
            (enchiridion.main::load-agent-generation context :generation 2)
          (ok (= 2 generation))
          (ok (plusp (length report))))
        (testing "the child was asked for the empty generation"
          (ok (= 2 (gethash :generation state)))
          (ok (string= (enchiridion.plugin:source-snapshot-digest
                        (enchiridion.plugin:snapshot-sources agent))
                       (gethash :digests state))))
        (testing "and both sides dropped the authored generation"
          (ng (enchiridion.tools:find-tool "reload-alpha"))
          (ok (= builtins (hash-table-count (enchiridion.tools:registry))))
          (ok (= 2 (enchiridion.main::context-generation context))))
        (testing "an empty tree needs no verification child"
          (ok (eq verify-digests (gethash :verify-digests state))))))))

(deftest broker-reload-reports-the-generation-or-the-refusal ()
  (with-scratch-directory (directory)
    (with-live-registry ()
      (let ((agent (merge-pathnames "agent/" directory))
            (state (make-hash-table :test #'eq))
            (context nil))
        (write-source agent "tools/alpha.lsp" (plugin-source "reload-alpha"))
        (with-test-broker (broker (child-hook state))
          (setf context (make-reload-context agent broker))
          (let ((supervisor (enchiridion.supervisor:make-supervisor
                             :directory (namestring agent)
                             :run-directory (namestring (merge-pathnames "run/" directory))
                             :generation 0
                             :reload-function
                             (lambda (target)
                               (enchiridion.main::broker-reload context target)))))
            (with-stub-verifier (state)
              (let ((result (enchiridion.supervisor:supervisor-reload supervisor)))
                (ok (getf result :ok-p))
                (ok (= 1 (getf result :generation)))
                (ok (= 1 (enchiridion.supervisor:supervisor-generation supervisor))))
              (setf (gethash :verify-fails-p state) t
                    (gethash :verify-report state) "alpha.lsp: refused")
              (let ((result (enchiridion.supervisor:supervisor-reload supervisor)))
                (ng (getf result :ok-p))
                (testing "a refusal leaves the supervisor on its last good number"
                  (ok (= 1 (getf result :generation)))
                  (ok (= 1 (enchiridion.supervisor:supervisor-generation supervisor)))
                  (ok (search "refused" (getf result :report))))))))))))
