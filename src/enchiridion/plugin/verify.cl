;;;; verify.cl --- Prove a generation before it loads.
;;;;
;;;; The broker compiles and loads every agent file at (safety 3), then runs
;;;; each plugin self-test. Exit zero means the generation is good. A file that
;;;; does not compile, a file that warns, and a self-test that returns NIL all
;;;; fail the same way, because the only safe answer to "is this generation
;;;; good" is a strict one.
;;;;
;;;; This file loads before the loader, so the few functions it needs from
;;;; there are declared forward. The declarations are bare FUNCTION, and they
;;;; are the only proclamations for those names anywhere: a bare declaration
;;;; and a specific one for the same name are two proclamations that disagree,
;;;; and SBCL turns that disagreement into a warning the gate treats as fatal.

(in-package #:enchiridion.plugin)

;; LOADER.CL loads before this file, so the generation special and the loader
;; helpers this file calls are already defined. The three names declared here
;; are the ones LOADER.CL calls back into, and every proclamation for them is
;; bare FUNCTION: a bare one and a specific one for the same name disagree, and
;; SBCL turns that disagreement into a warning the gate treats as fatal.

(declaim (ftype function verify-ok-p verify-report verify-directory))

(defstruct (verify-result (:constructor %make-verify-result))
  (ok-p nil :type boolean)
  (report "" :type string)
  (tests '() :type list)
  (failures '() :type list)
  (directory nil :type t))

(declaim (ftype function verify-ok-p))

(defun verify-ok-p (result)
  "Return T when RESULT says the generation loaded and passed its self-tests."
  (verify-result-ok-p result))

(declaim (ftype function verify-report))

(defun verify-report (result)
  "Return RESULT's report, the text a failing generation is refused with."
  (verify-result-report result))

(declaim (ftype (function (t &key (:package t)) t) verify-file))

(defun verify-file (path &key (package nil))
  "Compile and load PATH, and return two values: whether it was clean, and the
list of warnings it produced.

The policy is (safety 3) (debug 3), which is the profile plugin verification
and the broker share. A warning is collected and muffled, so it is reported
once by the code that owns the decision instead of printed twice."
  (let ((warnings '()))
    (handler-case
        (progn
          (proclaim '(optimize (safety 3) (debug 3)))
          (handler-bind ((warning (lambda (condition)
                                    (push (princ-to-string condition) warnings)
                                    (muffle-warning condition))))
            (let ((*package* (or package *package*))
                  (*read-eval* nil))
              (load path :verbose nil :print nil)))
          (values (null warnings) (nreverse warnings)))
      (error (condition)
        (values nil (list (princ-to-string condition)))))))

(declaim (ftype (function (list) t) run-self-tests))

(defun run-self-tests (plugins)
  "Run every plugin's self-test and return two values: whether all passed, and
the failure lines.

A plugin with no self-test passes: the extension surface makes the self-test
optional, and a generation of plain skills is a normal generation."
  (let ((failures '()))
    (dolist (plugin plugins)
      (let ((test (plugin-self-test plugin)))
        (when test
          (handler-case
              (let ((value (funcall test)))
                (unless value
                  (push (format nil "~A self-test returned ~S"
                                (plugin-name plugin) value)
                        failures)))
            (error (condition)
              (push (format nil "~A self-test signalled: ~A"
                            (plugin-name plugin) condition)
                    failures))))))
    (values (null failures) (nreverse failures))))

(declaim (ftype function verify-directory))

(defun verify-directory (directory &key (generation nil) (self-tests-p t))
  "Compile and load every agent file in DIRECTORY into a throwaway package,
run the self-tests, and return a VERIFY-RESULT.

GENERATION is the generation number the files are loaded under, and it is
bound so that the tools a verified file registers carry the number the real
load will use. SELF-TESTS-P is for a caller that only wants the compile."
  (let* ((directory (uiop:ensure-directory-pathname directory))
         (generation (or generation (1+ (current-generation))))
         (sources (agent-source-files directory))
         (package (ensure-generation-package generation))
         (before (plugin-registry))
         (failures '())
         (tests '()))
    (let ((*generation* generation))
      (dolist (path sources)
        (multiple-value-bind (ok-p warnings) (verify-file path :package package)
          (unless ok-p
            (push (format nil "~A: ~{~A~^; ~}" (file-namestring path) warnings)
                  failures)))))
    (let ((added (remove-if (lambda (plugin) (member plugin before))
                            (plugin-registry))))
      (when self-tests-p
        (multiple-value-bind (ok-p results) (run-self-tests added)
          (unless ok-p
            (setf failures (append failures results))))
        (setf tests (mapcar #'plugin-name added))))
    ;; Verification registers the tools it loads. Left alone, the real load
    ;; that follows would record every plugin a second time, and a caller that
    ;; only verifies would leave tools in the registry for a generation that
    ;; never loaded. The result already names what was tested, so the
    ;; registration can go.
    (discard-generation generation)
    (%make-verify-result
     :ok-p (null failures)
     :report (if failures
                 (format nil "~{~A~^~%~}" (reverse failures))
                 (format nil "~D file~:P compiled, ~D self-test~:P ran"
                         (length sources) (length tests)))
     :tests tests
     :failures (reverse failures)
     :directory directory)))
