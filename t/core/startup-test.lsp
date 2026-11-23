;;;; startup-test.lsp --- Privilege boundaries before dependency loading.

(defpackage #:enchiridion-startup-test
  (:use #:cl)
  (:import-from #:rove #:deftest #:ok #:signals))

(in-package #:enchiridion-startup-test)

(declaim (ftype (function (list) t) cl-user::broker-exec-drop-privileges)
         (ftype (function (t t) t) cl-user::broker-exec-setgroups)
         (ftype (function () t) cl-user::initialize-supervisor-asdf)
         (ftype (function (t) t) cl-user::check-sandbox-directory))

(defun startup-definition (file name)
  "Read NAME's definition before the script starts the application."
  (let ((*package* (find-package :cl-user)))
    (with-open-file (stream (asdf:system-relative-pathname "enchiridion" file))
      (loop for form = (read stream nil nil)
            while form
            when (and (consp form) (eq (first form) 'defun)
                      (string= (symbol-name (second form)) name))
              return form))))

(eval-when (:load-toplevel :execute)
  (dolist (definition '(("src/broker-exec.lsp" "BROKER-EXEC-ARGUMENT")
                        ("src/broker-exec.lsp" "BROKER-EXEC-DROP-PRIVILEGES")
                        ("src/main.lsp" "INITIALIZE-SUPERVISOR-ASDF")
                        ("src/main.lsp" "CHECK-SANDBOX-DIRECTORY")))
    (eval `(locally
             (declare (notinline sb-posix:geteuid sb-posix:getuid
                                 sb-posix:getegid sb-posix:getgid
                                 sb-posix:setgid sb-posix:setuid))
             ,(apply #'startup-definition definition)))))

(defmacro with-startup-functions (bindings &body body)
  (let ((saved (gensym "SAVED")))
    `(let ((,saved (mapcar (lambda (name)
                            (cons name (and (fboundp name) (symbol-function name))))
                          ',(mapcar #'first bindings))))
       (unwind-protect
            (progn
              ,@(loop for (name function) in bindings
                      collect `(setf (symbol-function ',name) ,function))
              ,@body)
         (dolist (entry ,saved)
           (if (cdr entry)
               (setf (symbol-function (car entry)) (cdr entry))
               (fmakunbound (car entry))))))))

(deftest bootstrap-drops-groups-gid-and-uid-in-order ()
  (dolist (failure '(nil :groups :groups-result :gid :uid :gid-noop :uid-noop))
    (let ((uid 0) (gid 0) (events nil))
      (flet ((record (operation)
               (push operation events)
               (when (eq operation failure) (error "Injected drop failure."))))
        (with-startup-functions
            ((sb-posix:geteuid (lambda () uid))
             (sb-posix:getuid (lambda () uid))
             (sb-posix:getegid (lambda () gid))
             (sb-posix:getgid (lambda () gid))
             (cl-user::broker-exec-setgroups
              (lambda (size pointer)
                (declare (ignore size pointer))
                (record :groups)
                (if (eq failure :groups-result) -1 0)))
             (sb-posix:setgid
              (lambda (value)
                (record :gid)
                (unless (eq failure :gid-noop) (setf gid value))))
             (sb-posix:setuid
              (lambda (value)
                (record :uid)
                (unless (eq failure :uid-noop) (setf uid value)))))
          (if failure
              (ok (signals (cl-user::broker-exec-drop-privileges
                            '("--uid" "1000" "--gid" "1000"))
                           'error))
              (progn
                (cl-user::broker-exec-drop-privileges
                 '("--uid" "1000" "--gid" "1000"))
                (ok (= uid gid 1000))))
          (ok (equal (reverse events)
                     (case failure
                       ((:groups :groups-result) '(:groups))
                       (:gid '(:groups :gid))
                       (otherwise '(:groups :gid :uid))))))))))

(deftest root-broker-invalid-identities-stop-before-system-loading ()
  (dolist (arguments '(("--uid" "0" "--gid" "1000")
                       ("--uid" "1000" "--gid" "0")
                       ("--uid" "1000bad" "--gid" "1000")
                       ("--uid" "1000")
                       ()))
    (multiple-value-bind (output status)
        (enchiridion.compat:run-program-capture
         (enchiridion.compat:lisp-runtime-path)
         (append
          (list "--noinform" "--disable-debugger"
                "--no-userinit" "--no-sysinit"
                "--eval" "(require :sb-posix)"
                "--eval" "(require :asdf)"
                "--eval" "(declaim (notinline sb-posix:geteuid))"
                "--eval" (prin1-to-string
                          '(setf (symbol-function 'sb-posix:geteuid)
                                 (lambda () 0)))
                "--eval" (prin1-to-string
                          '(setf (symbol-function 'asdf:load-system)
                                 (lambda (&rest cl-user::args)
                                   (declare (ignore cl-user::args))
                                   (write-line "UNSAFE-LOAD")
                                   (sb-ext:exit :code 99))))
                "--script" (namestring (asdf:system-relative-pathname
                                        "enchiridion" "src/broker-exec.lsp")))
          arguments)
         :timeout 10)
      (ok (= status 1))
      (ok (search "privilege drop failed" output))
      (ok (not (search "UNSAFE-LOAD" output))))))

(deftest supervisor-initializes-explicit-registries-without-user-files ()
  (let* ((scratch (merge-pathnames
                   (format nil "enchiridion-startup-~D/" (random most-positive-fixnum))
                   (uiop:temporary-directory)))
         (config (merge-pathnames ".config/" scratch))
         (old-home (uiop:getenv "HOME"))
         (old-config (uiop:getenv "XDG_CONFIG_HOME"))
         (old-source (uiop:getenv "CL_SOURCE_REGISTRY"))
         (old-output (uiop:getenv "ASDF_OUTPUT_TRANSLATIONS")))
    (unwind-protect
         (progn
           (dolist (name '("common-lisp/source-registry.conf"
                           "common-lisp/asdf-output-translations.conf"))
             (let ((path (merge-pathnames name config)))
               (ensure-directories-exist path)
               (with-open-file (stream path :direction :output)
                 (write-string "THIS IS NOT ASDF CONFIGURATION" stream))))
           (enchiridion.compat:set-environment-variable "HOME" (namestring scratch))
           (enchiridion.compat:set-environment-variable "XDG_CONFIG_HOME" (namestring config))
           (enchiridion.compat:set-environment-variable
            "CL_SOURCE_REGISTRY" "(:source-registry :inherit-configuration)")
           (enchiridion.compat:set-environment-variable
            "ASDF_OUTPUT_TRANSLATIONS" "(:output-translations (t nil) :inherit-configuration)")
           (ok (signals (asdf:initialize-source-registry) 'error))
           (with-startup-functions ((sb-posix:geteuid (lambda () 0)))
             (ok (not (signals (cl-user::initialize-supervisor-asdf) 'error)))
             (enchiridion.compat:unset-environment-variable "CL_SOURCE_REGISTRY")
             (enchiridion.compat:unset-environment-variable
              "ASDF_OUTPUT_TRANSLATIONS")
             (let ((*load-pathname*
                     (asdf:system-relative-pathname "enchiridion" "src/main.lsp")))
               (ok (not (signals (cl-user::initialize-supervisor-asdf) 'error))))))
      (loop for name in '("HOME" "XDG_CONFIG_HOME" "CL_SOURCE_REGISTRY"
                         "ASDF_OUTPUT_TRANSLATIONS")
            for value in (list old-home old-config old-source old-output)
            do (if value
                   (enchiridion.compat:set-environment-variable name value)
                   (enchiridion.compat:unset-environment-variable name)))
      (asdf:initialize-source-registry)
      (asdf:initialize-output-translations)
      (uiop:delete-directory-tree scratch :validate t :if-does-not-exist :ignore))))

(deftest writable-state-directories-must-not-be-symbolic-links ()
  (let* ((scratch (merge-pathnames (format nil "sandbox-link-~D/" (random most-positive-fixnum))
                                   *default-pathname-defaults*))
         (target (merge-pathnames "canary-approvals/" scratch))
         (link (merge-pathnames "default" scratch)))
    (unwind-protect
         (progn
           (ensure-directories-exist (merge-pathnames "placeholder" target))
           (sb-posix:symlink (namestring target) (namestring link))
           (ok (null (cl-user::check-sandbox-directory target)))
           (ok (signals (cl-user::check-sandbox-directory (uiop:ensure-directory-pathname link))
                        'enchiridion.errors:configuration-error)))
      (uiop:delete-directory-tree scratch :validate t :if-does-not-exist :ignore))))

(deftest an-unprivileged-broker-does-not-attempt-an-identity-change ()
  (with-startup-functions
      ((sb-posix:geteuid (lambda () 1000))
       (cl-user::broker-exec-setgroups
        (lambda (&rest arguments)
          (declare (ignore arguments)) (error "Unexpected group change.")))
       (sb-posix:setgid (lambda (gid) (declare (ignore gid)) (error "Unexpected gid change.")))
       (sb-posix:setuid (lambda (uid) (declare (ignore uid)) (error "Unexpected uid change."))))
    (ok (not (signals (cl-user::broker-exec-drop-privileges nil) 'error)))))
