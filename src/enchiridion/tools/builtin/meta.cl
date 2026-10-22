;;;; meta.cl --- Journey, author, undo, and reload.
;;;;
;;;; This tool is the agent's hand on its own history. Journey reads the agent
;;;; repository. Author writes a new tool or skill file. Undo reverts the last
;;;; commit, and it asks for confirmation because a revert is a real change.
;;;;
;;;; Reload records a request. The supervisor consumes it after the loader can
;;;; verify a generation. The tool does not pretend the code is already loaded.

(in-package #:enchiridion.tools.builtin)

(defun commit-author-change (directory path)
  "Commit the file just written when DIRECTORY is a git repository.
A directory that is not a repository is not an error: the file is written
either way, and the commit is what turns it into a journey entry."
  (handler-case
      (enchiridion.git:git-commit-all
       directory
       (format nil "Author ~A" (file-namestring path)))
    (error () nil)))

(defun meta-directory (args)
  "Return the agent repository META acts on."
  (let ((path (argument args "directory")))
    (cond
      (path (uiop:ensure-directory-pathname path))
      ((uiop:getenv "ENCHIRIDION_HOME")
       (merge-pathnames "agents/default/"
                        (uiop:ensure-directory-pathname
                         (uiop:getenv "ENCHIRIDION_HOME"))))
      (t (uiop:ensure-directory-pathname *default-pathname-defaults*)))))

(defun git-capture (directory &rest arguments)
  "Run git in DIRECTORY and return its combined output and status."
  (enchiridion.compat:run-program-capture
   "git" (cons "-C" (cons (namestring directory) arguments)) :timeout 20))

(defun meta-journey (directory limit)
  "Return the last LIMIT commits in DIRECTORY."
  (multiple-value-bind (output status)
      (git-capture directory "log" "--oneline" "-n" (princ-to-string limit))
    (cond
      ((eq status :timeout)
       (error 'enchiridion.errors:tool-error
              :tool "meta" :detail "git log timed out."))
      ((not (zerop status))
       (error 'enchiridion.errors:tool-error
              :tool "meta" :detail output))
      (t (cap-result output)))))

(defun safe-author-name (name)
  "Return NAME when it is one path segment of letters, digits, dash, underscore."
  (unless (and (stringp name)
               (plusp (length name))
               (cl-ppcre:scan "^[A-Za-z0-9_-]+$" name))
    (error 'enchiridion.errors:schema-error
           :detail "name must be one segment of letters, digits, dash, or underscore."))
  name)

(declaim (ftype (function (t) string) meta-run))

(defun meta-run (args)
  "Run a meta action: journey, author, bootstrap-step, undo, or reload."
  (let* ((action (string-downcase (or (argument args "action") "journey")))
         (directory (meta-directory args)))
    (cond
      ((string= action "journey")
       (meta-journey directory (or (argument args "limit") 20)))
      ((string= action "author")
       (let* ((name (safe-author-name (argument args "name")))
              (kind (string-downcase (or (argument args "kind") "tool")))
              (text (argument args "text"))
              (subdirectory (cond ((string= kind "tool") "tools/")
                                  ((string= kind "skill") "skills/")
                                  (t (error 'enchiridion.errors:schema-error
                                            :detail "kind must be tool or skill."))))
              (path (merge-pathnames (concatenate 'string subdirectory name
                                                  (if (string= kind "tool") ".cl" ".md"))
                                     directory)))
         (unless (stringp text)
           (error 'enchiridion.errors:schema-error :detail "text must be a string."))
         (when (probe-file path)
           (error 'enchiridion.errors:tool-error
                  :tool "meta" :detail (format nil "~A already exists." (namestring path))))
         (ensure-directories-exist path)
         (with-open-file (stream path :direction :output
                                      :if-exists :error
                                      :if-does-not-exist :create
                                      :external-format :utf-8)
           (write-string text stream))
         (format nil "wrote ~A~@[ and committed ~A~]"
                 (namestring path)
                 (commit-author-change directory path))))
      ((string= action "bootstrap-step")
       (let* ((step (argument args "step"))
              (steps (enchiridion.memory:bootstrap-steps directory)))
         (unless (and (integerp step) (plusp step))
           (error 'enchiridion.errors:schema-error
                  :detail "step must be a positive integer."))
         (unless (member step (mapcar #'car steps) :test #'=)
           (error 'enchiridion.errors:schema-error
                  :detail (format nil "There is no bootstrap step ~D." step)))
         (enchiridion.memory:mark-bootstrap-step directory step)
         (cap-result
          (format nil "bootstrap step ~D recorded. ~A"
                  step (enchiridion.memory:bootstrap-status-line directory)))))
      ((string= action "undo")
       (unless (string= (or (argument args "confirm") "") "yes")
         (error 'enchiridion.errors:schema-error
                :detail "undo requires confirm yes."))
       (multiple-value-bind (output status)
           (git-capture directory "revert" "--no-edit" "HEAD")
         (if (eq status :timeout)
             (error 'enchiridion.errors:tool-error
                    :tool "meta" :detail "git revert timed out.")
             (if (zerop status)
                 (cap-result output)
                 (error 'enchiridion.errors:tool-error
                        :tool "meta" :detail output)))))
      ((string= action "reload")
       (let ((path (enchiridion:control-path)))
         (ensure-directories-exist path)
         (with-open-file (stream path :direction :output :if-exists :append
                                      :if-does-not-exist :create
                                      :external-format :utf-8)
           (write-string "reload" stream)
           (terpri stream))
         (format nil "reload requested in ~A" (namestring path))))
      (t (error 'enchiridion.errors:schema-error
                :detail (format nil "Unknown meta action ~A." action))))))

(defparameter +meta-tools+
  (list
   (enchiridion.tools:make-tool
    :name "meta"
    :description "Read the journey, author a tool or skill, record a bootstrap step, undo, or request a reload."
    :schema '(:object :properties
              ((:action :string) (:directory :string) (:limit :integer)
               (:name :string) (:kind :string) (:text :string) (:confirm :string)
               (:step :integer)))
    :handler #'meta-run)))

(defun register-meta-tools ()
  "Register the meta tool. Idempotent."
  (dolist (tool +meta-tools+)
    (enchiridion.tools:register-tool tool))
  (length +meta-tools+))
