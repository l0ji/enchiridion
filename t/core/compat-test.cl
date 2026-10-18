;;;; compat-test.cl --- The implementation extensions.
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
  (ok (stringp (enchiridion.compat:process-user))))

(deftest a-backtrace-is-a-string ()
  ;; The caller prints this and knows nothing about SB-DEBUG. A non-string
  ;; return would turn a crash report into a second crash.
  (ok (stringp (enchiridion.compat:backtrace-string 3))))

(deftest the-implementation-is-named ()
  ;; A keyword, not whatever LISP-IMPLEMENTATION-TYPE returned. It is the
  ;; string "SBCL" on SBCL 2.5.4, and a test that compares the raw value passes
  ;; on an older SBCL and fails on this one for a reason that has nothing to do
  ;; with the code under test.
  (ok (member enchiridion.compat:+implementation+
              '(:sbcl :ccl :clisp :ecl :abc.lisp)
              :test #'eq))
  (ok (eql t (enchiridion.compat:implementation-dependency-p :sbcl))
      "or nil, on an implementation that is not SBCL")
  (ok (keywordp enchiridion.compat:+implementation+)))