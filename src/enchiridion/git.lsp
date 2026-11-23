;;;; git.lsp --- The agent directory as its own git repository.
;;;;
;;;; The agent directory is a repository of its own, nested inside whatever
;;;; holds the checkout. Personality evolution and authored code are therefore
;;;; a diff the operator can read, and `enchiridion undo` rolls back an agent
;;;; change without ever touching the harness.
;;;;
;;;; Every call goes through ENCHIRIDION.COMPAT. No call here ever writes git
;;;; identity and none passes `-c user.*`: the operator's global configuration
;;;; and signing key are the only ones used. A host with no global identity is
;;;; a host where git refuses the commit, which GIT-COMMIT-ALL reports as NIL
;;;; rather than as a failure of the turn.
;;;;
;;;; A root supervisor is the other case. The agent repository belongs to the
;;;; agent uid, and Git runs the hooks and local configuration it finds there,
;;;; so running Git as root would both trip Git's ownership check and execute
;;;; agent-written hooks as root. When this process is root, GIT-RUN starts
;;;; src/git-exec.lsp instead: that bootstrap drops the supplementary groups,
;;;; the gid, and the uid before it starts Git. No safe.directory entry is
;;;; written and no repository configuration is trusted. A root process with no
;;;; configured identity refuses instead of falling back to root.

(in-package #:enchiridion.git)

(defparameter +program+ "git"
  "The program every call runs. Rebinding it is how a test proves the
git-is-missing path without removing git from the machine.")

(defun git-program ()
  "Return the Git executable. ENCHIRIDION_GIT lets a Nix wrapper name the
store path, because the broker child starts with a fixed PATH."
  (or (uiop:getenv "ENCHIRIDION_GIT") +program+))

(defparameter +ignored+
  '("state.json" "state.json.*" "memory.db" "memory.db-*" "private/" "tmp/" "*.fasl")
  "What the agent repository ignores. State and the database are runtime, not
history: the agent's history is the seed files, the skills, and the tools.")

(defparameter +commit-timeout+ 30
  "Seconds a git call may take. A hook that waits on a lock forever would hang
the turn that asked for it, and a turn is not the place to wait.")

(defparameter +test-environment-keys+
  '("GIT_AUTHOR_NAME" "GIT_AUTHOR_EMAIL" "GIT_COMMITTER_NAME"
    "GIT_COMMITTER_EMAIL" "GIT_CONFIG_NOSYSTEM" "GIT_CONFIG_GLOBAL")
  "The variables GIT-TEST-ENVIRONMENT sets and this process's environment is
not allowed to carry.")

(declaim (ftype (function (t) t) enchiridion.errors:error-detail))

(defparameter *git-identity* nil
  "The (UID . GID) repository Git runs as when this process is root, or NIL.
The supervisor sets it from :SANDBOX :AGENT-UID and :AGENT-GID before any
repository action. A root process with no identity refuses to run repository
Git rather than running it as root.")

(defparameter +root-environment-keys+
  '("PATH" "LANG" "LC_ALL" "LC_CTYPE" "TZ" "SBCL_HOME" "LD_LIBRARY_PATH"
    "ENCHIRIDION_HOME")
  "The only process variables a dropped Git child may inherit.

GIT_* names can redirect Git at another repository or install a signing
program, and SSH_AUTH_SOCK and the gpg agent sockets hand the agent the
supervisor's credentials. None of those crosses the drop. HOME and TMPDIR are
computed rather than inherited, for the same reason.")

(defun git-exec-path ()
  "Return the privilege-drop bootstrap beside the trusted source.

A root process reads it only from an absolute ENCHIRIDION_SOURCE. The working
directory is agent-writable in a split run, and a bootstrap loaded from there
would run as root before it could drop. A non-root process never starts the
bootstrap, and ASDF's own source directory is the fallback for a checkout."
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
  "Return the SBCL that runs the bootstrap, from the same trusted runtime.
A root process requires an absolute path: a bare name would be looked up on a
PATH an agent-writable directory could be on, before the drop has happened."
  (let ((program (or (uiop:getenv "ENCHIRIDION_SBCL")
                     (enchiridion.compat:lisp-runtime-path))))
    (when (zerop (enchiridion.compat:process-uid))
      (unless (uiop:absolute-pathname-p (pathname program))
        (error 'enchiridion.errors:configuration-error
               :key :sandbox
               :detail "A root process needs an absolute SBCL path.")))
    program))

(defun checked-git-identity ()
  "Return *GIT-IDENTITY* as a (UID . GID) cons, or signal.
A root process with no identity, or one that is not two positive integers, must
not run repository Git at all: the fallback would be the supervisor's uid."
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
  "Return the allowlisted environment a dropped Git child gets.

HOME is the state root and never root's home, so the agent's own
Git configuration and signing key are the ones used. TMPDIR is the agent's tmp
directory, because /tmp is root-owned in the container."
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
  "Return the program, arguments, and child environment GIT-RUN should use.

A non-root process gets the plain Git command and ENVIRONMENT unchanged: the
host operator's configuration and signing key stay in charge. A root process
gets the bootstrap and the allowlisted environment, and never the caller's
ENVIRONMENT, which could be a test or a supervisor variable carrying a key."
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
  "Run git with ARGUMENTS in DIRECTORY and return its combined output and
status, the way ENCHIRIDION.COMPAT:RUN-PROGRAM-CAPTURE returns them.

The directory is passed with -C rather than as the child's working directory,
because the compat launcher starts the child where this process stands. A
directory that does not exist yet still reaches git: git's own sentence about
the path is more useful than a Lisp error about a pathname.

ENVIRONMENT replaces the child environment when it is given. The tests use it
to supply an author and to switch signing off in a build sandbox that has
neither, and they build it with GIT-TEST-ENVIRONMENT so PATH survives. A root
process ignores it and passes the allowlist GIT-ROOT-ENVIRONMENT builds, because
an inherited key or signing socket must not cross the drop."
  (multiple-value-bind (program command child-environment)
      (git-invocation directory arguments :environment environment)
    (enchiridion.compat:run-program-capture program command
                                            :timeout timeout
                                            :environment child-environment)))

(declaim (ftype (function () list) git-test-environment))

(defun git-test-environment ()
  "Return this process's environment with a test author and no global git
configuration.

The sandbox a nix build runs in has no `~/.gitconfig`, so a commit there has
no identity and, if the host config were reachable, would try to sign with a
key the sandbox does not have. PATH and everything else survives, because the
environment is replaced and not merely added to."
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
  "Return T when Git answers. Main refuses to start when this is NIL.

The version check runs as this process, without the repository bootstrap: no
repository or configuration is consulted, so a root supervisor can check Git
before the sandbox identity is known."
  (handler-case
      (multiple-value-bind (output status)
          (enchiridion.compat:run-program-capture
           (git-program) (list "--version") :timeout +commit-timeout+)
        (declare (ignore output))
        (eql 0 status))
    (error () nil)))

(declaim (ftype (function (t) boolean) repository-p))

(defun repository-p (directory)
  "Return T when DIRECTORY itself is the top of a git work tree.

The check is for DIRECTORY's own .git and not for `rev-parse
--is-inside-work-tree`, because the agent directory is nested inside the
checkout. A plain directory inside another repository answers yes to
rev-parse, and that answer would make the harness commit the agent's change
into the project's history."
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
  "Write the ignore file into DIRECTORY when there is none, and return its path.
An operator who edited it keeps their edit: this file is created, never
overwritten, for the same reason a seed file is."
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
  "Create a repository at DIRECTORY, write its ignore file, and return git's
output. An existing repository is left alone."
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
  "The child environment GIT-COMMIT-ALL gives git, or NIL to inherit.

Tests bind this to GIT-TEST-ENVIRONMENT, because a nix build sandbox has no
global git configuration and therefore no identity to commit under. Production
leaves it NIL, so the operator's own configuration and signing key are used.
A root process ignores it for the allowlist GIT-ROOT-ENVIRONMENT builds.")

(defparameter *commit-lock* (bordeaux-threads:make-lock "enchiridion commit")
  "The lock around GIT-COMMIT-ALL, one per process.

Every agent directory is one repository with one index. A turn on a channel
thread and a sleep pass on the heartbeat thread both end in a commit, and two
git commands at once collide on .git/index.lock: git refuses, the commit is
reported, and one turn's changes would never land. The lock makes the second
commit wait instead of losing the work.")

(declaim (ftype (function (string) t) report-history-failure))

(defun report-history-failure (detail)
  "Write one line about a refused commit to standard error."
  (format *error-output*
          "~&enchiridion: history was not recorded: ~A~%"
          detail)
  (finish-output *error-output*))

(defparameter *history-failure-reporter* #'report-history-failure
  "Called with a detail string when GIT-COMMIT-ALL cannot record a commit.

The default writes one line to *ERROR-OUTPUT*. A caller may bind this to its
own log. Reporting never signals and never replaces the turn's reply: a host
with no identity still answers the operator, and the operator can see why the
change is not in the history.")

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
  "How old .git/index.lock must be before an opted-in commit moves it aside.
Ten minutes is longer than the thirty second commit timeout, and the age is the
only evidence Git leaves about the writer. Age is not proof: recovery is off
unless the operator opts in (see *STALE-LOCK-RECOVERY-P*).")

(defparameter *stale-lock-recovery-p* nil
  "Whether a refused commit may move a stale index lock aside and retry.
Default NIL: another process, container, or hand-run Git command can hold a
lock longer than any threshold. An operator who knows this process is the
repository's only writer binds it to T; otherwise the refusal is reported
through *HISTORY-FAILURE-REPORTER*.")

(defparameter *stale-lock-reporter*
  (lambda (lock quarantine age)
    (format *error-output*
            "~&enchiridion: moved a ~D second~:P old Git index lock aside (~A -> ~A) and retried the commit.~%  Restore it with mv if a Git command in this repository was still running.~%"
            age lock quarantine)
    (finish-output *error-output*))
  "Called with the lock path, where it was moved, and its age in seconds.
The default writes two lines to *ERROR-OUTPUT* and never signals.")

(defun note-stale-lock (lock quarantine age)
  (when *stale-lock-reporter*
    (handler-case (funcall *stale-lock-reporter* lock quarantine age)
      (error () nil))))

(defun git-index-lock (directory)
  "Return the index lock path of DIRECTORY's repository."
  (merge-pathnames ".git/index.lock" (uiop:ensure-directory-pathname directory)))

(defun stale-git-lock-p (path &key (now (get-universal-time)))
  "Return PATH's age in seconds when it is old enough that its writer may be
gone. A directory or a vanished file answers NIL. The report shows the age."
  (let ((written (ignore-errors (file-write-date path))))
    (when (and (integerp written)
               (not (uiop:directory-exists-p path)))
      (let ((age (- now written)))
        (and (>= age +stale-index-lock-seconds+) age)))))

(defun git-lock-quarantine-path (lock &key (now (get-universal-time)))
  "Return a path beside LOCK where a stale lock can be kept."
  (pathname (format nil "~A.stale-~D" (namestring lock) now)))

(defun recover-stale-git-lock (directory)
  "Move DIRECTORY's index lock aside when it is stale, and return its new path.
The lock is renamed, not deleted, so a live writer's lock can be restored and a
crash leaves evidence. A directory, a young lock, recovery not opted in, and a
failed rename all answer NIL, and the caller keeps the original refusal."
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
  "Return DETAIL with the stale-lock opt-in named, when recovery is off.
Otherwise the operator sees a fatal Git line and no name for the setting."
  (if (and (stringp detail) (not *stale-lock-recovery-p*))
      (concatenate 'string
                   detail
                   " (stale-lock recovery is off: bind *STALE-LOCK-RECOVERY-P* to retry past a stale lock)")
      detail))

(declaim (ftype (function (t string &key (:environment t)) t) git-commit-all))

(defun git-commit-all (directory message &key (environment *commit-environment*))
  "Stage everything in DIRECTORY and commit it with MESSAGE.

Return two values: the commit hash, :NONE when there was nothing to commit, or
NIL when Git refuses; and a short detail string when the refusal lost history.
A host with no identity, no key, or a refusing commit hook is reported through
*HISTORY-FAILURE-REPORTER* instead of being swallowed, and the turn's reply is
still delivered. A turn that changed nothing is the normal case and reports
nothing.

The whole stage-and-commit pair is one unit under *COMMIT-LOCK*: another
thread's `git add` between this one's add and commit would commit the wrong
set of files. A refusal about .git/index.lock gets one retry after a lock older
than +STALE-INDEX-LOCK-SECONDS+ is moved aside; a younger lock is left alone,
because another command may hold it."
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
          ;; One retry, and only for a lock refusal: moving a stale lock lets
          ;; the next tick record the change instead of repeating the refusal.
          ;; A younger lock may belong to another command and is left alone.
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
  "Return up to LIMIT commits of DIRECTORY, newest first, each (hash . subject).
A repository with no commits yet returns the empty list.

LIMIT is a keyword and not an optional argument, because an ordinary lambda
list may not hold &OPTIONAL and &KEY at the same time."
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
  "Revert REVISION and return git's output.

A revert is a commit, so it takes the same ENVIRONMENT GIT-COMMIT-ALL does;
without one, a host with no identity refuses it.

A conflict signals a tool error carrying git's own text: the tree is left
mid-revert for the operator to resolve, and hiding that behind a boolean would
be the wrong kind of quiet."
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
