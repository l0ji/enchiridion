;;;; compat-test.lsp --- The implementation extensions.
;;;;
;;;; Everything else in the tree is standard Common Lisp. These tests exist so
;;;; that the one file which is not standard is known to work, and so that a
;;;; change to its interface shows up here rather than in the broker.

(defpackage #:enchiridion-compat-test
  (:use #:cl)
  (:import-from #:rove #:deftest #:ok #:ng #:testing)
  (:export #:run))

(in-package #:enchiridion-compat-test)

(deftest a-set-environment-variable-is-readable ()
  ;; PATH is set everywhere this code runs, the nix builder included, so the
  ;; readers are checked against the environment the process really has. That
  ;; is also what the broker will do, so the test and the use agree.
  (ok (enchiridion.compat:environment-bound-p "PATH"))
  (let ((value (enchiridion.compat:environment-value "PATH")))
    (ok (stringp value))
    (ok (plusp (length value)))))

(deftest an-unset-environment-variable-is-not-readable ()
  ;; The supervisor unsets the secrets it loaded, so an absent name is the
  ;; ordinary case rather than the exceptional one, and it has to be nil.
  (let ((name "ENCHIRIDION_ABSENT_MARKER"))
    (ng (enchiridion.compat:environment-bound-p name))
    (ng (enchiridion.compat:environment-value name))))

(deftest a-variable-can-be-set-and-then-unset ()
  ;; The unset is the step that keeps a loaded secret out of a child's
  ;; environment, so it is proved on a name that was really there rather than
  ;; on one that was never set.
  (let ((name "ENCHIRIDION_COMPAT_TEST_VALUE"))
    (unwind-protect
         (progn
           (enchiridion.compat:set-environment-variable name "present")
           (testing "the setter makes the value readable"
             (ok (enchiridion.compat:environment-bound-p name))
             (ok (string= "present" (enchiridion.compat:environment-value name))))
           (testing "and the unset removes it"
             (ok (enchiridion.compat:unset-environment-variable name))
             (ng (enchiridion.compat:environment-bound-p name))
             (ng (enchiridion.compat:environment-value name))))
      (enchiridion.compat:unset-environment-variable name))))

(deftest the-environment-is-an-alist-of-strings ()
  ;; An alist, not a list of NAME=VALUE strings. The supervisor builds the
  ;; broker's whole environment from this, and SBCL has changed the shape of
  ;; posix-environ between versions, so the shape is checked here where a
  ;; change is visible instead of inside a container.
  (let ((alist (enchiridion.compat:environment)))
    (ok (consp alist))
    (dolist (entry (subseq alist 0 (min 20 (length alist))))
      (ok (consp entry))
      (ok (stringp (car entry)))
      (ok (stringp (cdr entry))))))

(deftest running-a-program-returns-its-output ()
  (multiple-value-bind (text status)
      (enchiridion.compat:run-program-blocking
       "/bin/sh" '("-c" "printf hello"))
    (ok (equal text "hello"))
    (ok (eq status 0))))

(deftest a-failing-program-reports-a-non-zero-status ()
  (multiple-value-bind (text status)
      (enchiridion.compat:run-program-blocking
       "/bin/sh" '("-c" "exit 3"))
    (ok (equal text ""))
    (ok (= 3 status))))

(deftest the-process-identity-reads-are-available ()
  ;; The supervisor starts as uid 0 and the broker drops to 1000. These are
  ;; the two reads that the isolation tests depend on, so they are checked
  ;; here rather than being discovered to be missing inside a container.
  (ok (integerp (enchiridion.compat:process-uid)))
  (ok (integerp (enchiridion.compat:process-gid)))
  (ok (stringp (enchiridion.compat:process-user))))

(deftest a-backtrace-is-a-string ()
  ;; The caller prints this and knows nothing about SB-DEBUG. A non-string
  ;; return would turn a crash report into a second crash.
  (ok (stringp (enchiridion.compat:backtrace-string 3))))

(deftest the-implementation-is-named ()
  ;; A keyword, not whatever LISP-IMPLEMENTATION-TYPE returned. It is the
  ;; string "SBCL" on this SBCL, and a test that compares the raw value passes
  ;; on an older SBCL and fails on this one for a reason that has nothing to do
  ;; with the code under test.
  (ok (member enchiridion.compat:+implementation+
              '(:sbcl :ccl :clisp :ecl :abc.lisp)
              :test #'eq))
  (ok (eql t (enchiridion.compat:implementation-dependency-p :sbcl))
      "or nil, on an implementation that is not SBCL")
  (ok (keywordp enchiridion.compat:+implementation+)))

;;;; Interrupts.

(deftest a-body-without-an-interrupt-returns-its-value ()
  ;; Every REPL iteration and every command line runs under the handler, so
  ;; the ordinary path has to come back untouched.
  (ok (eq :done
          (enchiridion.compat:with-interrupt-handler
              ((lambda (condition) (declare (ignore condition)) nil))
            :done))))

(deftest an-interactive-interrupt-reaches-the-handler ()
  ;; SIGNAL-INTERACTIVE-INTERRUPT stands in for a real Ctrl-C. The condition
  ;; is not an ERROR, so a HANDLER-CASE would not see it, and this HANDLER-BIND
  ;; is the only thing that does. The throw proves the handler can leave the
  ;; interrupted code, which is the contract the REPL and MAIN depend on.
  #+sbcl
  (let ((caught nil))
    (ok (eq :interrupted
            (catch 'interrupt-test
              (enchiridion.compat:with-interrupt-handler
                  ((lambda (condition)
                     (declare (ignore condition))
                     (setf caught t)
                     (throw 'interrupt-test :interrupted)))
                (enchiridion.compat:signal-interactive-interrupt)
                :not-reached))))
    (ok caught))
  #-sbcl
  (ok t "this implementation has no interrupt condition to signal"))

(deftest a-ctrl-c-is-not-a-shutdown-request ()
  ;; The REPL aborts the line for the first and declines the second, so the
  ;; predicate has to tell them apart.
  #+sbcl
  (let ((shutdown nil))
    (catch 'interrupt-test
      (enchiridion.compat:with-interrupt-handler
          ((lambda (condition)
             (setf shutdown (enchiridion.compat:shutdown-interrupt-p condition))
             (throw 'interrupt-test :ok)))
        (enchiridion.compat:signal-interactive-interrupt)))
    (ok (null shutdown)))
  #-sbcl
  (ok t "this implementation has no interrupt condition"))

(deftest a-sigterm-looks-like-a-shutdown-request ()
  #+sbcl
  (let ((shutdown nil))
    (catch 'interrupt-test
      (enchiridion.compat:with-interrupt-handler
          ((lambda (condition)
             (setf shutdown (enchiridion.compat:shutdown-interrupt-p condition))
             (throw 'interrupt-test :ok)))
        (enchiridion.compat:signal-shutdown-interrupt)))
    (ok shutdown))
  #-sbcl
  (ok t "this implementation has no shutdown interrupt"))

(deftest the-shutdown-signals-can-be-installed ()
  ;; A BOOLEAN return and not the old handler: the entry point ignores it, and
  ;; an implementation with no signal interface has to answer NIL rather than
  ;; signal. A real SIGTERM is sent by the integration check, not here, so the
  ;; suite does not end itself.
  (ok (member (enchiridion.compat:install-shutdown-signals) '(t nil) :test #'eq)))
(defun capture-files ()
  "Return the capture files left in the temporary directory."
  (remove-if-not (lambda (path)
                   (uiop:string-prefix-p "enchiridion-capture-"
                                         (file-namestring path)))
                 (uiop:directory-files (enchiridion.compat:temp-directory))))

(deftest a-capture-returns-output-and-status-and-leaves-no-file ()
  (let ((before (capture-files)))
    (multiple-value-bind (output status)
        (enchiridion.compat:run-program-capture
         "/bin/sh" (list "-c" "echo out; echo err 1>&2; exit 3"))
      (ok (search "out" output))
      (ok (search "err" output) "standard error is in the same text")
      (ok (eql 3 status)))
    (multiple-value-bind (output status)
        (enchiridion.compat:run-program-capture
         "/bin/sh" (list "-c" "echo early; sleep 5") :timeout 0.2)
      (ok (search "early" output) "output written before the timeout is kept")
      (ok (eq :timeout status)))
    (ok (equal before (capture-files))
        "the capture file is never left behind")))

(deftest a-timeout-ends-the-commands-children-too ()
  ;; Killing /bin/sh alone left `sleep` running past its timeout.
  (multiple-value-bind (output status)
      (enchiridion.compat:run-program-capture
       "/bin/sh" (list "-c" "sleep 30 & echo $!; wait") :timeout 0.5)
    (ok (eq :timeout status))
    (let ((pid (parse-integer output :junk-allowed t)))
      (ok pid "the background job reported its pid")
      (when pid
        (sleep 0.2)
        (multiple-value-bind (ignored alive)
            (enchiridion.compat:run-program-capture
             "/bin/sh" (list "-c" (format nil "kill -0 ~D 2>/dev/null" pid)))
          (declare (ignore ignored))
          (ok (not (eql 0 alive)) "the background job is gone"))))))

;;;; Leaving a capture early.
;;;;
;;;; A shell command starts a child, and the caller can leave through an
;;;; interrupt, a throw or an error. The child leaves with it: a command that
;;;; outlives the turn keeps writing to a stream this process is about to close.

(deftest an-interrupted-capture-stops-the-child-it-started ()
  (let* ((directory (merge-pathnames
                     (format nil "enchiridion-compat-test-~D/"
                             (random most-positive-fixnum))
                     (uiop:ensure-directory-pathname
                      (enchiridion.compat:temp-directory))))
         (marker (merge-pathnames "marker" directory))
         (thread nil))
    (unwind-protect
         (progn
           (ensure-directories-exist directory)
           (setf thread
                 (bordeaux-threads:make-thread
                  (lambda ()
                    (catch 'abandon
                      (enchiridion.compat:run-program-capture
                       "/bin/sh"
                       (list "-c" (format nil "sleep 1; touch ~A"
                                          (uiop:native-namestring marker))))))))
           (sleep 0.2)
           (bordeaux-threads:interrupt-thread thread
                                             (lambda () (throw 'abandon :abandoned)))
           (loop repeat 200
                 while (bordeaux-threads:thread-alive-p thread)
                 do (sleep 0.01))
           (sleep 2)
           (ng (probe-file marker)
               "the child was stopped with the capture that started it"))
      (when (and thread (bordeaux-threads:thread-alive-p thread))
        (ignore-errors (bordeaux-threads:destroy-thread thread)))
      (uiop:delete-directory-tree directory :validate t :if-does-not-exist :ignore))))

;;;; Process trees.
;;;;
;;;; A hung tool is stopped by signalling its tree, which is not a process
;;;; group: RUN-PROGRAM gives every child a session of its own.

(deftest the-process-table-knows-this-process ()
  (let ((table (enchiridion.compat::process-table)))
    (ok table "this system exports a process table")
    (ok (find (enchiridion.compat:process-id) table :key #'car)
        "and it holds the process reading it")
    (ok (every (lambda (entry)
                 (and (integerp (car entry)) (integerp (cdr entry))))
               table))))

(deftest a-childs-descendants-are-found-through-parent-links ()
  (let ((process (enchiridion.compat:run-program
                  "/bin/sh" (list "-c" "sleep 30 & wait")
                  :output #p"/dev/null" :if-output-exists :supersede :wait nil)))
    (unwind-protect
         (let ((found nil))
           (loop repeat 300
                 do (setf found (enchiridion.compat:process-descendants process))
                    (when found (return))
                    (sleep 0.01))
           (ok found "the background job is a descendant of the shell")
           (ok (not (member (enchiridion.compat:process-id) found))
               "and this process is not one of them"))
      (ignore-errors (enchiridion.compat:process-kill process :sigkill :process-group))
      (ignore-errors (enchiridion.compat:process-reap process)))))

(deftest a-signalled-process-stops-being-alive ()
  (let* ((process (enchiridion.compat:run-program
                   "/bin/sh" (list "-c" "sleep 30")
                   :output #p"/dev/null" :if-output-exists :supersede :wait nil))
         (pid (enchiridion.compat:process-pid process)))
    (unwind-protect
         (progn
           (ok (enchiridion.compat:process-alive-p pid))
           (ok (enchiridion.compat:signal-process pid :sigkill))
           ;; A killed child is a zombie until reaped, and a zombie still
           ;; answers a signal.
           (enchiridion.compat:process-reap process)
           (loop repeat 300 while (enchiridion.compat:process-alive-p pid)
                 do (sleep 0.01))
           (ng (enchiridion.compat:process-alive-p pid)))
      (ignore-errors (enchiridion.compat:process-kill process :sigkill :process-group))
      (ignore-errors (enchiridion.compat:process-reap process)))))
