;;;; git.lsp --- Manage the agent directory as its own nested Git repository.
;;;;
;;;; Uses the operator's global Git config/signing key (never writes user.*).
;;;; When running as root, GIT-RUN invokes src/git-exec.lsp to drop privileges
;;;; before touching the agent-owned repository, refusing if no identity is set.

(in-package #:enchiridion.git)

(defparameter +program+ "git"
  "Git executable name (rebindable in tests).")

(defun git-program ()
  "Return the Git executable, honoring ENCHIRIDION_GIT."
  (or (uiop:getenv "ENCHIRIDION_GIT") +program+))

(defparameter +ignored+
  '("state.json" "state.json.*" "memory.db" "memory.db-*" "private/" "tmp/" "*.fasl")
  "Patterns ignored in the agent repository (runtime state, not history).")

(defparameter +commit-timeout+ 30
  "Timeout in seconds for Git commands.")

(defparameter +test-environment-keys+
  '("GIT_AUTHOR_NAME" "GIT_AUTHOR_EMAIL" "GIT_COMMITTER_NAME"
    "GIT_COMMITTER_EMAIL" "GIT_CONFIG_NOSYSTEM" "GIT_CONFIG_GLOBAL")
  "Git env vars overridden by GIT-TEST-ENVIRONMENT.")

(declaim (ftype (function (t) t) enchiridion.errors:error-detail))

(defparameter *git-identity* nil
  "Target (UID . GID) for repository Git when running as root, or NIL to refuse.")

(defparameter +root-environment-keys+
  '("PATH" "LANG" "LC_ALL" "LC_CTYPE" "TZ" "SBCL_HOME" "LD_LIBRARY_PATH"
    "ENCHIRIDION_HOME")
  "Allowlisted env vars passed across the root privilege drop (excludes GIT_*, SSH/GPG sockets).")

(defun git-exec-path ()
  "Return path to src/git-exec.lsp.
Root requires an absolute ENCHIRIDION_SOURCE so nothing is loaded from an agent-writable cwd."
  (let ((source (uiop:getenv "ENCHIRIDION_SOURCE")))
    (cond
      ((and source (plusp (length source)))
       (let ((directory (uiop:ensure-directory-pathname source)))
         (unless (uiop:absolute-pathname-p directory)
           (error 'enchiridion.errors:configuration-error
                  :key :sandbox
                  :detail "ENCHIRIDION_SOURCE must be an absolute path."))
         (merge-pathnames "src/git-exec.lsp" directory)))
      ((zerop (enchiridion.compat:process-uid))
       (error 'enchiridion.errors:configuration-error
              :key :sandbox
              :detail "A root process needs ENCHIRIDION_SOURCE."))
      (t
       (asdf:system-relative-pathname "enchiridion" "src/git-exec.lsp")))))

(defun git-exec-program ()
  "Return SBCL executable for the bootstrap; root requires an absolute path."
  (let ((program (or (uiop:getenv "ENCHIRIDION_SBCL")
                     (enchiridion.compat:lisp-runtime-path))))
    (when (zerop (enchiridion.compat:process-uid))
      (unless (uiop:absolute-pathname-p (pathname program))
        (error 'enchiridion.errors:configuration-error
               :key :sandbox
               :detail "A root process needs an absolute SBCL path.")))
    program))

(defun checked-git-identity ()
  "Return *GIT-IDENTITY* as a (UID . GID) of positive integers, or signal CONFIGURATION-ERROR."
  (let ((identity *git-identity*))
    (unless (and (consp identity)
                 (integerp (car identity))
                 (integerp (cdr identity))
                 (plusp (car identity))
                 (plusp (cdr identity)))
      (error 'enchiridion.errors:configuration-error
             :key :sandbox
             :detail "Git needs positive :sandbox :agent-uid and :agent-gid."))
    identity))

(defun git-root-environment ()
  "Return allowlisted env for dropped Git children, setting HOME and TMPDIR under ENCHIRIDION_HOME."
  (let* ((state (uiop:getenv "ENCHIRIDION_HOME"))
         (usable (and state (plusp (length state))))
         (home (if usable state "/nonexistent"))
         (tmp (if usable
                  (namestring (merge-pathnames
                               "tmp/"
                               (uiop:ensure-directory-pathname state)))
                  "/tmp"))
         (entries '()))
    (dolist (name +root-environment-keys+)
      (let ((value (uiop:getenv name)))
        (when value
          (push (cons name value) entries))))
    (unless (assoc "PATH" entries :test #'string=)
      (push (cons "PATH" "/usr/local/bin:/usr/bin:/bin") entries))
    (push (cons "HOME" home) entries)
    (push (cons "TMPDIR" tmp) entries)
    (mapcar (lambda (entry)
              (format nil "~A=~A" (car entry) (cdr entry)))
            (nreverse entries))))

(defun git-command (directory arguments)
  "Return the -C form of ARGUMENTS for DIRECTORY."
  (cons "-C"
        (cons (namestring (uiop:ensure-directory-pathname directory))
              (mapcar #'princ-to-string arguments))))

(defun git-invocation (directory arguments &key environment)
  "Return (values program arguments environment) for GIT-RUN.
Root uses the privilege-drop bootstrap and allowlisted env, ignoring caller ENVIRONMENT."
  (let ((command (git-command directory arguments)))
    (if (zerop (enchiridion.compat:process-uid))
        (let ((identity (checked-git-identity)))
          (values (git-exec-program)
                  (append (list "--noinform" "--no-userinit" "--no-sysinit"
                                "--script" (namestring (git-exec-path))
                                "--uid" (princ-to-string (car identity))
                                "--gid" (princ-to-string (cdr identity))
                                "--program" (git-program)
                                "--")
                          command)
                  (git-root-environment)))
        (values (git-program) command environment))))

(declaim (ftype (function (t list &key (:environment t) (:timeout t)) t) git-run))

(defun git-run (directory arguments &key environment (timeout +commit-timeout+))
  "Run git -C DIRECTORY with ARGUMENTS and return combined output and exit status.
Root ignores ENVIRONMENT and uses GIT-ROOT-ENVIRONMENT."
  (multiple-value-bind (program command child-environment)
      (git-invocation directory arguments :environment environment)
    (enchiridion.compat:run-program-capture program command
                                            :timeout timeout
                                            :environment child-environment)))

(declaim (ftype (function () list) git-test-environment))

(defun git-test-environment ()
  "Return current env with a test author and global/system Git config disabled (preserves PATH)."
  (let ((entries '()))
    (loop for (name . value) in (enchiridion.compat:environment)
          unless (member name +test-environment-keys+ :test #'string=)
            do (push (format nil "~A=~A" name value) entries))
    (append (nreverse entries)
            (list "GIT_AUTHOR_NAME=Test"
                  "GIT_AUTHOR_EMAIL=test@example.invalid"
                  "GIT_COMMITTER_NAME=Test"
                  "GIT_COMMITTER_EMAIL=test@example.invalid"
                  "GIT_CONFIG_NOSYSTEM=1"
                  "GIT_CONFIG_GLOBAL=/dev/null"))))

(declaim (ftype (function () boolean) git-available-p))

(defun git-available-p ()
  "Return T when `git --version` succeeds (runs directly without repo bootstrap)."
  (handler-case
      (multiple-value-bind (output status)
          (enchiridion.compat:run-program-capture
           (git-program) (list "--version") :timeout +commit-timeout+)
        (declare (ignore output))
        (eql 0 status))
    (error () nil)))

(declaim (ftype (function (t) boolean) repository-p))

(defun repository-p (directory)
  "Return T when DIRECTORY has its own .git entry (avoids rev-parse matching a parent repo)."
  (let ((path (uiop:ensure-directory-pathname directory)))
    (not (null (or (probe-file (merge-pathnames ".git/" path))
                   (probe-file (merge-pathnames ".git" path)))))))

(declaim (ftype (function () string) ignore-file-text))

(defun ignore-file-text ()
  "Return the text of the agent repository's .gitignore."
  (with-output-to-string (stream)
    (format stream "# Written by enchiridion. Runtime state is not history:~%")
    (format stream "# the seed files, the skills, and the tools are.~%")
    (dolist (pattern +ignored+)
      (format stream "~A~%" pattern))))

(declaim (ftype (function (t) t) write-ignore-file))

(defun write-ignore-file (directory)
  "Write .gitignore into DIRECTORY if absent, without overwriting existing edits."
  (let ((path (merge-pathnames ".gitignore"
                               (uiop:ensure-directory-pathname directory))))
    (unless (probe-file path)
      (with-open-file (stream path
                              :direction :output
                              :if-exists :error
                              :if-does-not-exist :create
                              :external-format :utf-8)
        (write-string (ignore-file-text) stream)))
    path))

(declaim (ftype (function (t) string) git-init))

(defun git-init (directory)
  "Initialize a Git repo at DIRECTORY, write .gitignore if missing, and return git's output."
  (let ((path (uiop:ensure-directory-pathname directory)))
    (ensure-directories-exist (merge-pathnames "x" path))
    (multiple-value-bind (output status)
        (git-run path (list "init" "--initial-branch=main"))
      (unless (eql 0 status)
        (error 'enchiridion.errors:tool-error :tool "git" :detail output))
      (write-ignore-file path)
      output)))

(declaim (ftype (function (t &key (:environment t)) t) git-head))

(defun git-head (directory &key environment)
  "Return DIRECTORY's current commit hash, or NIL when there is none."
  (multiple-value-bind (output status)
      (git-run directory (list "rev-parse" "HEAD") :environment environment)
    (when (eql 0 status)
      (string-trim '(#\Space #\Newline #\Return #\Tab) output))))

(defparameter *commit-environment* nil
  "Child env for GIT-COMMIT-ALL (NIL inherits; tests bind to GIT-TEST-ENVIRONMENT; ignored by root).")

(defparameter *commit-lock* (bordeaux-threads:make-lock "enchiridion commit")
  "Process-wide lock serializing GIT-COMMIT-ALL to prevent .git/index.lock collisions.")

(declaim (ftype (function (string) t) report-history-failure))

(defun report-history-failure (detail)
  "Write one line about a refused commit to standard error."
  (format *error-output*
          "~&enchiridion: history was not recorded: ~A~%"
          detail)
  (finish-output *error-output*))

(defparameter *history-failure-reporter* #'report-history-failure
  "Called with a detail string when GIT-COMMIT-ALL fails; never signals.")

(defun note-history-failure (detail)
  (when (and detail *history-failure-reporter*)
    (handler-case
        (funcall *history-failure-reporter* detail)
      (error () nil))))

(defun git-failure-line (output)
  "Return the most useful line of OUTPUT, trimmed, or NIL."
  (when (and (stringp output) (plusp (length output)))
    (let ((lines (uiop:split-string output :separator (string #\Newline)))
          (trimmable '(#\Space #\Tab #\Return)))
      (or (find-if (lambda (line)
                     (let ((line (string-left-trim trimmable line)))
                       (or (eql 0 (search "fatal:" line))
                           (eql 0 (search "error:" line)))))
                   lines)
          (find-if (lambda (line)
                     (plusp (length (string-trim trimmable line))))
                   lines)))))

(defparameter +unreadable-hash-detail+
  "Commit succeeded; its hash could not be read.")

(defun condition-failure-detail (condition)
  "Return CONDITION's report, with its own detail when it carries one."
  (let ((detail (ignore-errors (enchiridion.errors:error-detail condition))))
    (if (and (stringp detail) (plusp (length detail)))
        (format nil "~A ~A" (princ-to-string condition) detail)
        (princ-to-string condition))))

(defun git-failure-detail (output status)
  "Return one bounded sentence explaining a refused Git command."
  (let* ((trimmable '(#\Space #\Tab #\Return))
         (raw-line (and (not (eq status :timeout))
                        (git-failure-line output)))
         (line (and raw-line (string-trim trimmable raw-line)))
         (detail (cond
                   ((eq status :timeout) "The Git command timed out.")
                   ((and line (plusp (length line))) line)
                   (t (format nil "Git exited with status ~A." status)))))
    (if (> (length detail) 400)
        (subseq detail 0 400)
        detail)))

(defparameter +stale-index-lock-seconds+ 600
  "Minimum age in seconds before an opted-in commit quarantines .git/index.lock.")

(defparameter *stale-lock-recovery-p* nil
  "When T, allow GIT-COMMIT-ALL to quarantine a stale .git/index.lock and retry once (default NIL).")

(defparameter *stale-lock-reporter*
  (lambda (lock quarantine age)
    (format *error-output*
            "~&enchiridion: moved a ~D second~:P old Git index lock aside (~A -> ~A) and retried the commit.~%  Restore it with mv if a Git command in this repository was still running.~%"
            age lock quarantine)
    (finish-output *error-output*))
  "Called with (lock quarantine age) after quarantining a stale index lock.")

(defun note-stale-lock (lock quarantine age)
  (when *stale-lock-reporter*
    (handler-case (funcall *stale-lock-reporter* lock quarantine age)
      (error () nil))))

(defun git-index-lock (directory)
  "Return the index lock path of DIRECTORY's repository."
  (merge-pathnames ".git/index.lock" (uiop:ensure-directory-pathname directory)))

(defun stale-git-lock-p (path &key (now (get-universal-time)))
  "Return PATH's age in seconds if it is a file at least +STALE-INDEX-LOCK-SECONDS+ old, else NIL."
  (let ((written (ignore-errors (file-write-date path))))
    (when (and (integerp written)
               (not (uiop:directory-exists-p path)))
      (let ((age (- now written)))
        (and (>= age +stale-index-lock-seconds+) age)))))

(defun git-lock-quarantine-path (lock &key (now (get-universal-time)))
  "Return a path beside LOCK where a stale lock can be kept."
  (pathname (format nil "~A.stale-~D" (namestring lock) now)))

(defun recover-stale-git-lock (directory)
  "If *STALE-LOCK-RECOVERY-P* is T and .git/index.lock is stale, rename it aside and return the quarantine path."
  (when *stale-lock-recovery-p*
    (let ((lock (git-index-lock directory)))
      (when (probe-file lock)
        (let ((age (stale-git-lock-p lock)))
          (when age
            (let ((quarantine (git-lock-quarantine-path lock)))
              (handler-case
                  (progn (rename-file lock quarantine)
                         (note-stale-lock lock quarantine age)
                         quarantine)
                (error () nil)))))))))

(defun git-lock-failure-p (output)
  "Return T when OUTPUT is a refusal about the repository index lock."
  (and (stringp output) (search "index.lock" output)))

(defun git-lock-hint (detail)
  "Append the *STALE-LOCK-RECOVERY-P* hint to DETAIL when stale-lock recovery is off."
  (if (and (stringp detail) (not *stale-lock-recovery-p*))
      (concatenate 'string
                   detail
                   " (stale-lock recovery is off: bind *STALE-LOCK-RECOVERY-P* to retry past a stale lock)")
      detail))

(declaim (ftype (function (t string &key (:environment t)) t) git-commit-all))

(defun git-commit-all (directory message &key (environment *commit-environment*))
  "Stage everything in DIRECTORY and commit with MESSAGE under *COMMIT-LOCK*.
Returns (values result detail): hash, :NONE if clean, or NIL on refusal (reported via *HISTORY-FAILURE-REPORTER*).
Retries once on .git/index.lock failure if stale-lock recovery succeeds."
  (let (result detail)
    (bordeaux-threads:with-lock-held (*commit-lock*)
      (let ((path (uiop:ensure-directory-pathname directory)))
        (unless (repository-p path)
          (return-from git-commit-all nil))
        (labels ((attempt ()
                   (handler-case
                       (multiple-value-bind (add-output add-status)
                           (git-run path (list "add" "-A") :environment environment)
                         (if (not (eql 0 add-status))
                             (values nil
                                     (git-failure-detail add-output add-status)
                                     (git-lock-failure-p add-output))
                             (multiple-value-bind (output status)
                                 (git-run path (list "commit" "-m" message)
                                          :environment environment)
                               (cond
                                 ((eql 0 status)
                                  (let ((head (git-head path :environment environment)))
                                    (if head
                                        (values head nil nil)
                                        (values nil +unreadable-hash-detail+ nil))))
                                 ((search "nothing to commit" output)
                                  (values :none nil nil))
                                 (t
                                  (values nil
                                          (git-failure-detail output status)
                                          (git-lock-failure-p output)))))))
                     (error (condition)
                       (values nil (condition-failure-detail condition) nil)))))
          ;; Retry once on index.lock failure if stale-lock recovery moved the lock aside.
          (multiple-value-bind (first-result first-detail first-lock-p)
              (attempt)
            (multiple-value-bind (final-result final-detail)
                (if (and (null first-result)
                         first-lock-p
                         (recover-stale-git-lock path))
                    (attempt)
                    (values first-result
                            (if (and first-lock-p (null first-result))
                                (git-lock-hint first-detail)
                                first-detail)))
              (setf result final-result
                    detail final-detail))))))
    (note-history-failure detail)
    (values result detail)))

(declaim (ftype (function (t &key (:limit t) (:pathspec t)) list) git-log))

(defun git-log (directory &key (limit 20) pathspec)
  "Return up to LIMIT commits of DIRECTORY, newest first, as (hash . subject) pairs, or NIL."
  (let ((arguments (append (list "log"
                                 (format nil "-n~D" limit)
                                 "--format=%H%x09%s")
                           (when pathspec
                             (list "--" (namestring pathspec))))))
    (multiple-value-bind (output status) (git-run directory arguments)
      (if (eql 0 status)
          (loop for line in (uiop:split-string output :separator (string #\Newline))
                when (plusp (length line))
                  collect (let ((tab (position #\Tab line)))
                            (if tab
                                (cons (subseq line 0 tab) (subseq line (1+ tab)))
                                (cons line ""))))
          '()))))

(declaim (ftype (function (t t) string) git-show))

(defun git-show (directory revision)
  "Return the message and diff REVISION names, or the empty string."
  (multiple-value-bind (output status)
      (git-run directory (list "show" revision))
    (if (eql 0 status) output "")))

(declaim (ftype (function (t) string) git-diff))

(defun git-diff (directory)
  "Return DIRECTORY's working tree diff, or the empty string."
  (multiple-value-bind (output status)
      (git-run directory (list "diff"))
    (if (eql 0 status) output "")))

(declaim (ftype (function (t t &key (:environment t)) string) git-revert))

(defun git-revert (directory revision &key (environment *commit-environment*))
  "Revert REVISION and return git's output; signals TOOL-ERROR on conflict (leaving tree mid-revert)."
  (multiple-value-bind (output status)
      (git-run directory (list "revert" "--no-edit" revision)
               :environment environment)
    (if (eql 0 status)
        output
        (error 'enchiridion.errors:tool-error :tool "git" :detail output))))

(declaim (ftype (function (t) string) git-current-branch))

(defun git-current-branch (directory)
  "Return the branch DIRECTORY is on, or the empty string."
  (multiple-value-bind (output status)
      (git-run directory (list "branch" "--show-current"))
    (if (eql 0 status)
        (string-trim '(#\Space #\Newline #\Return #\Tab) output)
        "")))
