;;;; verify.lsp --- Compile and self-test a generation before activation.
;;;;
;;;; Compiles and loads agent files at (safety 3) (debug 3), treating any
;;;; warning, error, or falsy self-test as verification failure.

(in-package #:enchiridion.plugin)

;; Bare FUNCTION declarations match loader.lsp to avoid SBCL ftype redefinition warnings.

(declaim (ftype function verify-ok-p verify-report verify-directory))

;; Result of verifying a generation directory (status, report, tests, failures, snapshot).
(defstruct (verify-result (:constructor %make-verify-result))
  (ok-p nil :type boolean)
  (report "" :type string)
  (tests '() :type list)
  (failures '() :type list)
  (reference-skills '() :type list)
  (digests nil :type t)
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
  "Load PATH at (safety 3) (debug 3) with *READ-EVAL* NIL, muffling and collecting warnings.
Returns (values clean-p warnings)."
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
  "Run each plugin's optional SELF-TEST; return (values all-passed-p failure-lines)."
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

(defun verify-directory (directory &key (generation nil) (self-tests-p t)
                                      (source-digests nil))
  "Verify agent files in DIRECTORY under GENERATION and return a VERIFY-RESULT.
Refuses without compiling if SOURCE-DIGESTS does not match the current snapshot."
  (let* ((directory (uiop:ensure-directory-pathname directory))
         (snapshot (snapshot-sources directory))
         (mismatch (source-mismatch source-digests snapshot)))
    (if mismatch
        (refused-verification mismatch directory snapshot)
        (verify-snapshot directory generation self-tests-p snapshot))))

(declaim (ftype (function (t t t) verify-result) refused-verification))

(defun refused-verification (report directory snapshot)
  "Return a failed VERIFY-RESULT for a directory that no longer matches."
  (%make-verify-result :ok-p nil
                       :report report
                       :directory directory
                       :digests snapshot
                       :reference-skills (reference-skill-files directory)))

(declaim (ftype (function (t t t t) verify-result) verify-snapshot))

(defun verify-snapshot (directory generation self-tests-p snapshot)
  "Compile and self-test the agent files of DIRECTORY, which SNAPSHOT describes."
  (let ((enchiridion.tools::*registry*
          (copy-tool-registry (enchiridion.tools:registry)))
        (*plugins* (copy-list *plugins*))
        (*generation* (or generation (1+ (current-generation)))))
    (let* ((generation *generation*)
           (sources (agent-source-files directory))
           (package (ensure-generation-package generation))
           (before (plugin-registry))
           (failures '())
           (tests '()))
      (dolist (path sources)
        (multiple-value-bind (ok-p warnings) (verify-file path :package package)
          (unless ok-p
            (push (format nil "~A: ~{~A~^; ~}" (file-namestring path) warnings)
                  failures))))
      (let ((added (remove-if (lambda (plugin) (member plugin before))
                              (plugin-registry))))
        (when self-tests-p
          (multiple-value-bind (ok-p results) (run-self-tests added)
            (unless ok-p
              (setf failures (append failures results))))
          (setf tests (mapcar #'plugin-name added))))
      ;; Discard staged tools so verification leaves no registration side effects.
      (discard-generation generation)
      (%make-verify-result
       :ok-p (null failures)
       :report (if failures
                   (format nil "~{~A~^~%~}" (reverse failures))
                   (format nil "~D file~:P compiled, ~D self-test~:P ran"
                           (length sources) (length tests)))
       :tests tests
       :failures (reverse failures)
       :digests snapshot
       :reference-skills (reference-skill-files directory)
       :directory directory))))
