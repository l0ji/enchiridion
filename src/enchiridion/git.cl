;;;; git.cl --- The agent directory as its own git repository.
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

(in-package #:enchiridion.git)

(defparameter +program+ "git"
  "The program every call runs. Rebinding it is how a test proves the
git-is-missing path without removing git from the machine.")

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
neither, and they build it with GIT-TEST-ENVIRONMENT so PATH survives."
  (enchiridion.compat:run-program-capture
   +program+
   (cons "-C"
         (cons (namestring (uiop:ensure-directory-pathname directory))
               (mapcar #'princ-to-string arguments)))
   :timeout timeout
   :environment environment))

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
  "Return T when git answers. A host without git is a host where journey and
undo say so, rather than a host where a turn dies."
  (handler-case
      (multiple-value-bind (output status) (git-run "." (list "--version"))
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
leaves it NIL, so the operator's own configuration and signing key are used.")

(declaim (ftype (function (t string &key (:environment t)) t) git-commit-all))

(defun git-commit-all (directory message &key (environment *commit-environment*))
  "Stage everything in DIRECTORY and commit it with MESSAGE.

Return the commit hash, or :NONE when there was nothing to commit, or NIL when
git refused: a host with no identity, no key, or no git at all. Nothing here
signals. A turn that changed nothing is the normal case, and neither that nor a
missing git may cost the operator the reply."
  (let ((path (uiop:ensure-directory-pathname directory)))
    (unless (repository-p path)
      (return-from git-commit-all nil))
    (handler-case
        (progn
          (git-run path (list "add" "-A") :environment environment)
          (multiple-value-bind (output status)
              (git-run path (list "commit" "-m" message) :environment environment)
            (cond
              ((eql 0 status) (git-head path :environment environment))
              ((search "nothing to commit" output) :none)
              (t nil))))
      (error () nil))))

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

(declaim (ftype (function (t t) string) git-revert))

(defun git-revert (directory revision)
  "Revert REVISION and return git's output.

A conflict signals a tool error carrying git's own text: the tree is left
mid-revert for the operator to resolve, and hiding that behind a boolean would
be the wrong kind of quiet."
  (multiple-value-bind (output status)
      (git-run directory (list "revert" "--no-edit" revision))
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
