;;;; rove-bridge.cl --- Run the suites rove actually collected.
;;;;
;;;; rove can run a suite by system name, and that path maps source files back
;;;; to the package that defined them. It assumes the extension .lisp. This
;;;; project uses .cl, so the mapping never matches, `system-packages` returns
;;;; nothing, and the run reports success having executed zero tests. A green
;;;; suite that ran nothing is worse than a red one, because it hides the next
;;;; real failure.
;;;;
;;;; So the tests are run from what rove collected, and the count is checked.
;;;; A run that finds no tests fails the build.

(defpackage #:enchiridion-rove-bridge
  (:use #:cl)
  (:export #:run-suites #:suite-count #:test-count #:missing-bridge-symbol)
  (:documentation
   "Runs every suite rove registered, and refuses to report success unless it
ran at least one."))

(in-package #:enchiridion-rove-bridge)

(defparameter *bridge-symbols*
  '("SUITE-TESTS" "ALL-SUITES")
  "The rove symbols this file needs. Resolved by name rather than imported,
so that a rove upgrade that renames one of them produces a clear error here
instead of a reader error at load time.")

(defun missing-bridge-symbol (name)
  "Return T when rove no longer exports NAME and this bridge cannot work."
  (not (and (find-package :rove/core/suite/package)
             (find-symbol name :rove/core/suite/package))))

(defun suite-tests-accessor ()
  "Return rove's SUITE-TESTS function, or signal when it is gone. Reaching
into one library internal is cheaper than reaching into several, and it is
confined to this one function so that the breakage is in one place."
  (or (find-symbol "SUITE-TESTS" :rove/core/suite/package)
      (error "rove no longer has SUITE-TESTS; ~A needs updating."
             *bridge-symbols*)))

(defun suite-count ()
  "Return how many suites rove has registered. Anything above zero means at
least one deftest form was expanded."
  (length (rove:all-suites)))

(defun test-count ()
  "Return how many deftest forms rove has registered across every suite."
  (let ((accessor (suite-tests-accessor)))
    (loop for suite in (rove:all-suites)
          summing (length (funcall accessor suite)))))

(declaim (ftype (function () integer) run-suites))

(defun run-suites ()
  "Run every registered suite. Signal when there were none, and signal when
any of them failed. Return the number of tests that ran."
  (let ((accessor (suite-tests-accessor)))
    (let ((names (loop for suite in (rove:all-suites)
                       append (funcall accessor suite))))
      (cond
        ((null names)
         (error "rove collected no tests. Every suite file defines no deftest, ~
or the suite was never compiled."))
        (t
         (format t "~&Running ~D test~:P in ~D suite~:P.~%"
                 (length names) (suite-count))
         (finish-output)
         (multiple-value-bind (passed result)
             (rove:run-tests names)
           (declare (ignore result))
           (unless passed
             (error "Tests failed.")))
         (length names))))))