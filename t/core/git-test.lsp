;;;; git-test.lsp --- The nested agent repository.
;;;;
;;;; The agent directory is its own repository, nested inside the checkout.
;;;; The properties that matter are the ones `journey` and `undo` stand on: a
;;;; commit is visible under the hash it returned, a clean tree is not an
;;;; error, a revert restores the text, and a plain directory inside a
;;;; repository is still not a repository of its own.
;;;;
;;;; Every call passes GIT-TEST-ENVIRONMENT, because the build sandbox has no
;;;; global git config: no identity, and no signing key to try.

(defpackage #:enchiridion-git-test
  (:use #:cl)
  (:import-from #:rove #:deftest #:ok #:ng #:testing #:signals)
  (:export #:run))

(in-package #:enchiridion-git-test)

(defun scratch-directory ()
  "Return a fresh directory under the directory this build may write."
  (uiop:ensure-directory-pathname
   (merge-pathnames
    (format nil "enchiridion-git-test-~D/" (random most-positive-fixnum))
    (uiop:ensure-directory-pathname *default-pathname-defaults*))))

(defmacro with-scratch-directory ((directory) &body body)
  "Bind DIRECTORY to a fresh scratch directory, then remove it."
  `(let ((,directory (scratch-directory)))
     (unwind-protect
          (progn ,@body)
       (uiop:delete-directory-tree ,directory
                                   :validate t
                                   :if-does-not-exist :ignore))))

(defun write-text (path text)
  "Write TEXT to PATH, making its directory first."
  (ensure-directories-exist path)
  (with-open-file (stream path :direction :output
                               :if-exists :supersede
                               :if-does-not-exist :create
                               :external-format :utf-8)
    (write-string text stream)))

(defun read-text (path)
  "Return PATH as text."
  (uiop:read-file-string path :external-format :utf-8))

(defmacro with-environment ((name value) &body body)
  "Run BODY with environment variable NAME set to VALUE, then restore it."
  (let ((previous (gensym "PREVIOUS")))
    `(let ((,previous (uiop:getenv ,name)))
       (unwind-protect
            (progn
              (if ,value
                  (enchiridion.compat:set-environment-variable ,name ,value)
                  (enchiridion.compat:unset-environment-variable ,name))
              ,@body)
         (if ,previous
             (enchiridion.compat:set-environment-variable ,name ,previous)
             (enchiridion.compat:unset-environment-variable ,name))))))

(defmacro with-environments (bindings &body body)
  "Run BODY with every (NAME VALUE) in BINDINGS set, then restore them."
  (if (null bindings)
      `(progn ,@body)
      `(with-environment ,(first bindings)
         (with-environments ,(rest bindings) ,@body))))

(defmacro with-process-uid ((uid) &body body)
  "Run BODY with PROCESS-UID returning UID, then restore the real function."
  (let ((original (gensym "ORIGINAL")))
    `(let ((,original (symbol-function 'enchiridion.compat:process-uid)))
       (unwind-protect
            (progn
              (setf (symbol-function 'enchiridion.compat:process-uid)
                    (lambda () ,uid))
              ,@body)
         (setf (symbol-function 'enchiridion.compat:process-uid) ,original)))))

(defmacro with-functions (bindings &body body)
  "Run BODY with each NAME bound to FUNCTION, then restore it."
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

(defun startup-definition (file name)
  "Read NAME's definition before the script starts the application."
  (let ((*package* (find-package :cl-user)))
    (with-open-file (stream (asdf:system-relative-pathname "enchiridion" file))
      (loop for form = (read stream nil nil)
            while form
            when (and (consp form) (eq (first form) 'defun)
                      (string= (symbol-name (second form)) name))
              return form))))

(declaim (ftype (function (list t) t) cl-user::git-exec-argument)
         (ftype (function (list t) t) cl-user::git-exec-positive-integer)
         (ftype (function (list) t) cl-user::git-exec-drop-privileges)
         (ftype (function () t) cl-user::git-exec-clear-supplementary-groups))

(eval-when (:load-toplevel :execute)
  (dolist (definition '(("src/git-exec.lsp" "GIT-EXEC-ARGUMENT")
                        ("src/git-exec.lsp" "GIT-EXEC-POSITIVE-INTEGER")
                        ("src/git-exec.lsp" "GIT-EXEC-DROP-PRIVILEGES")))
    (eval `(locally
             (declare (notinline sb-posix:geteuid sb-posix:getuid
                                 sb-posix:getegid sb-posix:getgid
                                 sb-posix:setgid sb-posix:setuid))
             ,(apply #'startup-definition definition)))))

(defun environment ()
  "Return the child environment every commit here uses."
  (enchiridion.git:git-test-environment))

(deftest git-answers ()
  (ok (enchiridion.git:git-available-p)))

(deftest init-creates-a-repository-with-an-ignore-file ()
  (with-scratch-directory (directory)
    (testing "a plain directory is not a repository"
      (ng (enchiridion.git:repository-p directory)))
    (enchiridion.git:git-init directory)
    (testing "and after init it is one, on main"
      (ok (enchiridion.git:repository-p directory))
      (ok (string= "main" (enchiridion.git:git-current-branch directory))))
    (testing "the ignore file holds the runtime names and not the seed files"
      (let ((text (read-text (merge-pathnames ".gitignore" directory))))
        (ok (search "state.json" text))
        (ok (search "memory.db" text))
        (ng (search "SOUL.md" text))))
    (testing "an operator edit to the ignore file survives a second init"
      (let ((path (merge-pathnames ".gitignore" directory)))
        (write-text path "my own rules\n")
        (enchiridion.git:git-init directory)
        (ok (string= "my own rules\n" (read-text path)))))))

(deftest a-commit-is-visible-under-the-hash-it-returned ()
  (with-scratch-directory (directory)
    (enchiridion.git:git-init directory)
    (write-text (merge-pathnames "SOUL.md" directory) "identity\n")
    (let ((hash (enchiridion.git:git-commit-all directory "Add the identity"
                                                :environment (environment))))
      (testing "the hash is a commit and it is HEAD"
        (ok (stringp hash))
        (ok (= 40 (length hash)))
        (ok (string= hash (enchiridion.git:git-head directory
                                                  :environment (environment)))))
      (testing "the log names it newest first"
        (let ((entry (first (enchiridion.git:git-log directory :limit 5))))
          (ok (string= hash (car entry)))
          (ok (string= "Add the identity" (cdr entry)))))
      (testing "nothing to commit is :none and not an error"
        (ok (eq :none (enchiridion.git:git-commit-all directory "again"
                                                      :environment (environment))))))))

(deftest a-plain-directory-inside-a-repository-is-not-one ()
  (with-scratch-directory (directory)
    (enchiridion.git:git-init directory)
    (let ((child (merge-pathnames "children/one/" directory)))
      (ensure-directories-exist child)
      (testing "the nesting rule is what keeps undo out of the harness history"
        (ok (enchiridion.git:repository-p directory))
        (ng (enchiridion.git:repository-p child))
        (ok (null (enchiridion.git:git-commit-all child "no"
                                                  :environment (environment))))))))

(deftest revert-restores-the-text ()
  (with-scratch-directory (directory)
    (enchiridion.git:git-init directory)
    (let ((path (merge-pathnames "WORLD.md" directory)))
      (write-text path "one\n")
      (enchiridion.git:git-commit-all directory "Record one"
                                      :environment (environment))
      (write-text path "two\n")
      (enchiridion.git:git-commit-all directory "Record two"
                                      :environment (environment))
      (enchiridion.git:git-revert directory "HEAD" :environment (environment))
      (ok (string= "one\n" (read-text path))))))

(deftest show-and-diff-answer-without-signalling ()
  (with-scratch-directory (directory)
    (enchiridion.git:git-init directory)
    (write-text (merge-pathnames "a.md" directory) "a\n")
    (enchiridion.git:git-commit-all directory "Add a" :environment (environment))
    (ok (search "Add a" (enchiridion.git:git-show directory "HEAD")))
    (write-text (merge-pathnames "a.md" directory) "changed\n")
    (ok (search "changed" (enchiridion.git:git-diff directory)))
    (testing "a revision that does not exist is an empty answer, not a crash"
      (ok (string= "" (enchiridion.git:git-show directory "no-such-revision"))))))

(deftest a-repository-with-no-commits-has-an-empty-log ()
  (with-scratch-directory (directory)
    (enchiridion.git:git-init directory)
    (ok (null (enchiridion.git:git-log directory :limit 5)))
    (ok (null (enchiridion.git:git-head directory :environment (environment))))))

;;;; The identity boundary.
;;;;
;;;; A root supervisor cannot run Git in the agent's repository: the ownership
;;;; check refuses and agent hooks would run as root. These tests prove the
;;;; bootstrap drops groups, gid, and uid in that order before it starts Git,
;;;; that an unprivileged host keeps the old plain Git path, that the dropped
;;;; child gets a minimal environment, and that a refused commit is reported
;;;; without replacing the turn's reply. The actual root container is not
;;;; available here, so the drop itself is exercised with stubbed sb-posix
;;;; calls and a simulated euid; the host-side hook test uses the real Git.

(deftest git-bootstrap-drops-groups-gid-and-uid-in-order ()
  (dolist (failure '(nil :groups :gid :uid :gid-noop :uid-noop))
    (let ((uid 0) (gid 0) (events nil))
      (flet ((record (operation)
               (push operation events)
               (when (eq operation failure) (error "Injected drop failure."))))
        (with-functions
            ((sb-posix:geteuid (lambda () uid))
             (sb-posix:getuid (lambda () uid))
             (sb-posix:getegid (lambda () gid))
             (sb-posix:getgid (lambda () gid))
             (cl-user::git-exec-clear-supplementary-groups
              (lambda () (record :groups)))
             (sb-posix:setgid
              (lambda (value)
                (record :gid)
                (unless (eq failure :gid-noop) (setf gid value))))
             (sb-posix:setuid
              (lambda (value)
                (record :uid)
                (unless (eq failure :uid-noop) (setf uid value)))))
          (if failure
              (ok (signals (cl-user::git-exec-drop-privileges
                            '("--uid" "1000" "--gid" "1000"))
                           'error))
              (progn
                (cl-user::git-exec-drop-privileges
                 '("--uid" "1000" "--gid" "1000"))
                (ok (= uid gid 1000))))
          (ok (equal (reverse events)
                     (case failure
                       (:groups '(:groups))
                       (:gid '(:groups :gid))
                       (otherwise '(:groups :gid :uid))))))))))

(deftest an-unprivileged-git-bootstrap-does-not-change-identity ()
  (with-functions
      ((sb-posix:geteuid (lambda () 1000))
       (cl-user::git-exec-clear-supplementary-groups
        (lambda () (error "Unexpected group change.")))
       (sb-posix:setgid
        (lambda (gid) (declare (ignore gid)) (error "Unexpected gid change.")))
       (sb-posix:setuid
        (lambda (uid) (declare (ignore uid)) (error "Unexpected uid change."))))
    (ok (not (signals (cl-user::git-exec-drop-privileges nil) 'error)))))

(deftest a-root-git-bootstrap-rejects-invalid-identities-before-the-drop ()
  (dolist (arguments '(("--uid" "0" "--gid" "1000")
                       ("--uid" "1000" "--gid" "0")
                       ("--uid" "1000bad" "--gid" "1000")
                       ("--uid" "1000")
                       ("--gid" "1000")
                       ()))
    (let ((events nil))
      (with-functions
          ((sb-posix:geteuid (lambda () 0))
           (cl-user::git-exec-clear-supplementary-groups
            (lambda () (push :groups events) (error "Unexpected group change.")))
           (sb-posix:setgid
            (lambda (gid)
              (declare (ignore gid))
              (push :gid events)
              (error "Unexpected gid change.")))
           (sb-posix:setuid
            (lambda (uid)
              (declare (ignore uid))
              (push :uid events)
              (error "Unexpected uid change."))))
        (ok (signals (cl-user::git-exec-drop-privileges arguments) 'error))
        (ok (null events))))))

(defun git-exec-script ()
  "Return the bootstrap path the installed source carries."
  (namestring (asdf:system-relative-pathname "enchiridion" "src/git-exec.lsp")))

(defun run-git-exec (arguments)
  "Run the bootstrap as a simulated root process and return output and status."
  (enchiridion.compat:run-program-capture
   (enchiridion.compat:lisp-runtime-path)
   (append
    (list "--noinform" "--disable-debugger" "--no-userinit" "--no-sysinit"
          "--eval" "(require :sb-posix)"
          "--eval" "(declaim (notinline sb-posix:geteuid))"
          "--eval" (prin1-to-string
                    '(setf (symbol-function 'sb-posix:geteuid)
                           (lambda () 0)))
          "--script" (git-exec-script))
    arguments)
   :timeout 20
   :environment (environment)))

(deftest a-root-git-bootstrap-stops-before-git-when-the-identity-is-invalid ()
  (dolist (arguments '(("--uid" "0" "--gid" "1000")
                       ("--uid" "1000" "--gid" "0")
                       ("--uid" "1000")))
    (multiple-value-bind (output status)
        (run-git-exec (append arguments
                              (list "--program" "/bin/sh" "--"
                                    "-c" "echo UNSAFE-RUN")))
      (ok (= status 1))
      (ok (search "git-exec:" output))
      (ok (not (search "UNSAFE-RUN" output))))))

(deftest a-root-git-bootstrap-stops-before-git-when-the-drop-fails ()
  (if (zerop (enchiridion.compat:process-uid))
      ;; A real root process would complete the drop and run the marker. The
      ;; stubbed ordering test above covers that case without needing a
      ;; container, and this host test is only meaningful as a non-root user.
      (ok t)
      (multiple-value-bind (output status)
          (run-git-exec (list "--uid" "1000" "--gid" "1000"
                              "--program" "/bin/sh" "--"
                              "-c" "echo UNSAFE-RUN"))
        (ok (= status 1))
        (ok (search "git-exec:" output))
        (ok (not (search "UNSAFE-RUN" output))))))

(deftest the-git-bootstrap-runs-git-when-it-is-not-root ()
  (multiple-value-bind (output status)
      (enchiridion.compat:run-program-capture
       (enchiridion.compat:lisp-runtime-path)
       (list "--noinform" "--no-userinit" "--no-sysinit"
             "--script" (git-exec-script)
             "--uid" "1000" "--gid" "1000"
             "--program" (enchiridion.git:git-program) "--" "--version")
       :timeout 20
       :environment (environment))
    (ok (eql 0 status))
    (ok (search "git version" output))))

(deftest the-git-bootstrap-loads-nothing-beside-sb-posix ()
  (let ((text (read-text (git-exec-script))))
    (ng (search "(require :asdf)" text))
    (ng (search "(asdf:" text))
    (ng (search "(uiop:" text))))

(deftest the-git-version-check-does-not-need-an-identity ()
  (with-process-uid (0)
    (let ((enchiridion.git:*git-identity* nil))
      (ok (enchiridion.git:git-available-p)))))

(deftest a-root-git-invocation-uses-the-bootstrap-and-a-minimal-environment ()
  (with-scratch-directory (directory)
    (let* ((state (merge-pathnames "state/" directory))
           (source (namestring (asdf:system-source-directory "enchiridion"))))
      (ensure-directories-exist (merge-pathnames "tmp/x" state))
      (with-environments (("ENCHIRIDION_SOURCE" source)
                          ("ENCHIRIDION_HOME" (namestring state))
                          ("OPENAI_API_KEY" "sk-not-a-real-key")
                          ("GIT_CONFIG_COUNT" "1")
                          ("GIT_ASKPASS" "/tmp/askpass")
                          ("GIT_AUTHOR_NAME" "Root")
                          ("SSH_AUTH_SOCK" "/tmp/agent.sock")
                          ("GPG_AGENT_INFO" "/tmp/gpg"))
        (with-process-uid (0)
          (let ((enchiridion.git:*git-identity* (cons 1234 2345)))
            (multiple-value-bind (program arguments environment)
                (enchiridion.git::git-invocation directory '("status"))
              (testing "the bootstrap, not Git, is the program"
                (ok (string= program (enchiridion.git::git-exec-program)))
                (ok (string= (nth 4 arguments)
                             (namestring (enchiridion.git::git-exec-path))))
                (ok (equal (subseq arguments 5 9)
                           '("--uid" "1234" "--gid" "2345")))
                (ok (string= (nth 10 arguments)
                             (enchiridion.git:git-program))))
              (testing "the Git command follows the separator"
                (let ((tail (member "--" arguments :test #'string=)))
                  (ok tail)
                  (ok (equal (rest tail)
                             (list "-C"
                                   (namestring
                                    (uiop:ensure-directory-pathname directory))
                                   "status")))))
              (testing "HOME and TMPDIR belong to the agent, not root"
                (ok (member (format nil "HOME=~A" (namestring state))
                            environment :test #'string=))
                (ok (member (format nil "TMPDIR=~A"
                                    (namestring (merge-pathnames "tmp/" state)))
                            environment :test #'string=)))
              (testing "no secret, signing socket, or GIT_ name crosses"
                (let ((names (mapcar (lambda (entry)
                                       (subseq entry 0 (position #\= entry)))
                                     environment)))
                  (ok (notany (lambda (name)
                                (or (eql 0 (search "GIT_" name))
                                    (eql 0 (search "SSH_" name))
                                    (eql 0 (search "GPG_" name))
                                    (string= name "OPENAI_API_KEY")))
                              names)))))))))))

(deftest a-nonroot-git-invocation-keeps-the-operator-environment ()
  (with-scratch-directory (directory)
    (with-process-uid (4242)
      (let ((enchiridion.git:*git-identity* (cons 1234 2345))
            (environment '("GIT_AUTHOR_NAME=Operator" "HOME=/home/operator")))
        (multiple-value-bind (program arguments child-environment)
            (enchiridion.git::git-invocation directory '("status")
                                             :environment environment)
          (ok (string= program (enchiridion.git:git-program)))
          (ok (equal arguments
                     (list "-C"
                           (namestring
                            (uiop:ensure-directory-pathname directory))
                           "status")))
          (ok (equal child-environment environment)))))))

(deftest a-root-git-invocation-without-an-identity-refuses ()
  (with-scratch-directory (directory)
    (with-process-uid (0)
      (dolist (identity '(nil (0 . 1000) (1000 . 0) (1000) "1000:1000"))
        (let ((enchiridion.git:*git-identity* identity))
          (ok (signals (enchiridion.git::git-invocation directory '("status"))
                       'enchiridion.errors:configuration-error)))))))

(deftest a-root-git-run-refuses-before-it-launches-git ()
  (with-scratch-directory (directory)
    (with-process-uid (0)
      (let ((enchiridion.git:*git-identity* nil)
            (launched nil))
        (with-functions
            ((enchiridion.compat:run-program-capture
              (lambda (&rest arguments)
                (declare (ignore arguments))
                (setf launched t)
                (values "" 0))))
          (ok (signals (enchiridion.git:git-run directory '("status"))
                       'enchiridion.errors:configuration-error))
          (ok (null launched)))))))

(deftest a-root-commit-without-an-identity-is-reported-and-does-not-launch-git ()
  (with-scratch-directory (directory)
    (ensure-directories-exist (merge-pathnames ".git/" directory))
    (with-process-uid (0)
      (let ((enchiridion.git:*git-identity* nil)
            (launched nil)
            (reported '()))
        (with-functions
            ((enchiridion.compat:run-program-capture
              (lambda (&rest arguments)
                (declare (ignore arguments))
                (setf launched t)
                (values "" 0))))
          (let ((enchiridion.git:*history-failure-reporter*
                  (lambda (detail) (push detail reported))))
            (multiple-value-bind (result detail)
                (enchiridion.git:git-commit-all directory "message")
              (ok (null result))
              (ok (search "agent-uid" detail))
              (ok (equal reported (list detail)))
              (ok (null launched)))))))))

(deftest a-root-git-invocation-requires-an-absolute-trusted-source ()
  (with-scratch-directory (directory)
    (with-process-uid (0)
      (let ((enchiridion.git:*git-identity* (cons 1000 1000)))
        (with-environment ("ENCHIRIDION_SOURCE" nil)
          (ok (signals (enchiridion.git::git-invocation directory '("status"))
                       'enchiridion.errors:configuration-error)))
        (with-environment ("ENCHIRIDION_SOURCE" "relative/source")
          (ok (signals (enchiridion.git::git-invocation directory '("status"))
                       'enchiridion.errors:configuration-error)))
        (with-environment ("ENCHIRIDION_SOURCE"
                           (namestring (asdf:system-source-directory "enchiridion")))
          (with-environment ("ENCHIRIDION_SBCL" "sbcl")
            (ok (signals (enchiridion.git::git-invocation directory '("status"))
                         'enchiridion.errors:configuration-error))))))))

(deftest a-nonroot-commit-runs-the-repository-hook ()
  (with-scratch-directory (directory)
    (enchiridion.git:git-init directory)
    (write-text (merge-pathnames "SOUL.md" directory) "identity\n")
    (let ((marker (merge-pathnames ".git/hook-uid.txt" directory))
          (hook (merge-pathnames ".git/hooks/pre-commit" directory)))
      (write-text hook
                  (format nil "#!/bin/sh~%id -u > ~A~%exit 0~%"
                          (namestring marker)))
      (enchiridion.compat:set-file-mode hook #o755)
      (let ((hash (enchiridion.git:git-commit-all directory "Add identity"
                                                  :environment (environment))))
        (ok (stringp hash))
        (ok (= 40 (length hash)))
        (ok (= (parse-integer
                (string-trim '(#\Space #\Newline) (read-text marker)))
               (enchiridion.compat:process-uid)))))))

(deftest a-refused-commit-is-reported-without-signalling ()
  (with-scratch-directory (directory)
    (enchiridion.git:git-init directory)
    (write-text (merge-pathnames "SOUL.md" directory) "identity\n")
    (let ((marker (merge-pathnames ".git/hook-uid.txt" directory))
          (hook (merge-pathnames ".git/hooks/pre-commit" directory))
          (reported '()))
      (write-text hook
                  (format nil "#!/bin/sh~%id -u > ~A~%echo hook refused >&2~%exit 1~%"
                          (namestring marker)))
      (enchiridion.compat:set-file-mode hook #o755)
      (let ((enchiridion.git:*history-failure-reporter*
              (lambda (detail) (push detail reported))))
        (multiple-value-bind (result detail)
            (enchiridion.git:git-commit-all directory "Add identity"
                                            :environment (environment))
          (testing "the refusal is a value, not a signal"
            (ok (null result))
            (ok (stringp detail))
            (ok (search "hook refused" detail)))
          (testing "the reporter saw it"
            (ok (equal reported (list detail))))
          (testing "the real hook ran as this nonroot user"
            (ok (= (parse-integer
                    (string-trim '(#\Space #\Newline) (read-text marker)))
                   (enchiridion.compat:process-uid)))))))))

(deftest a-commit-without-an-identity-is-reported ()
  (with-scratch-directory (directory)
    (enchiridion.git:git-init directory)
    (write-text (merge-pathnames "SOUL.md" directory) "identity\n")
    (let* ((home (merge-pathnames "home/" directory))
           (base (environment))
           (clean (remove-if (lambda (entry)
                               (let ((name (subseq entry 0 (position #\= entry))))
                                 (or (eql 0 (search "GIT_" name))
                                     (string= name "HOME")
                                     (string= name "EMAIL"))))
                             base))
           (child (append clean
                          (list (format nil "HOME=~A" (namestring home))
                                "GIT_CONFIG_GLOBAL=/dev/null"
                                "GIT_CONFIG_NOSYSTEM=1"
                                "GIT_CONFIG_COUNT=1"
                                "GIT_CONFIG_KEY_0=user.useConfigOnly"
                                "GIT_CONFIG_VALUE_0=true")))
           (reported '()))
      (ensure-directories-exist home)
      (let ((enchiridion.git:*history-failure-reporter*
              (lambda (detail) (push detail reported))))
        (multiple-value-bind (result detail)
            (enchiridion.git:git-commit-all directory "Add identity"
                                            :environment child)
          (ok (null result))
          (ok (stringp detail))
          (ok (search "fatal:" detail))
          (ok (equal reported (list detail))))))))

(deftest nothing-to-commit-is-not-a-history-failure ()
  (with-scratch-directory (directory)
    (enchiridion.git:git-init directory)
    (write-text (merge-pathnames "SOUL.md" directory) "identity\n")
    (enchiridion.git:git-commit-all directory "Add identity"
                                    :environment (environment))
    (let ((reported '()))
      (let ((enchiridion.git:*history-failure-reporter*
              (lambda (detail) (push detail reported))))
        (multiple-value-bind (result detail)
            (enchiridion.git:git-commit-all directory "again"
                                            :environment (environment))
          (ok (eq :none result))
          (ok (null detail))
          (ok (null reported)))))))

(deftest an-add-refusal-is-reported-and-skips-the-commit ()
  (with-scratch-directory (directory)
    (ensure-directories-exist (merge-pathnames ".git/" directory))
    (let ((calls '()) (reported '()))
      (with-functions
          ((enchiridion.compat:run-program-capture
            (lambda (program arguments &key timeout environment)
              (declare (ignore program timeout environment))
              (push arguments calls)
              (values "fatal: add refused" 128))))
        (let ((enchiridion.git:*history-failure-reporter*
                (lambda (detail) (push detail reported))))
          (multiple-value-bind (result detail)
              (enchiridion.git:git-commit-all directory "message")
            (ok (null result))
            (ok (search "add refused" detail))
            (ok (equal reported (list detail)))
            (ok (= 1 (length calls)))))))))

(deftest a-commit-whose-hash-cannot-be-read-is-reported ()
  (with-scratch-directory (directory)
    (ensure-directories-exist (merge-pathnames ".git/" directory))
    (let ((reported '()))
      (with-functions
          ((enchiridion.compat:run-program-capture
            (lambda (program arguments &key timeout environment)
              (declare (ignore program timeout environment))
              (cond
                ((member "add" arguments :test #'string=) (values "" 0))
                ((member "commit" arguments :test #'string=) (values "" 0))
                (t (values "fatal: no head" 1))))))
        (let ((enchiridion.git:*history-failure-reporter*
                (lambda (detail) (push detail reported))))
          (multiple-value-bind (result detail)
              (enchiridion.git:git-commit-all directory "message")
            (ok (null result))
            (ok (search "hash could not be read" detail))
            (ok (equal reported (list detail)))))))))
