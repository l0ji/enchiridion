;;;; git-exec.lsp --- Privilege-drop wrapper for running Git on the agent repo.
;;;;
;;;; Requires only sb-posix; drops supplementary groups, GID, and UID before
;;;; execing Git so agent-owned hooks and repo config never run as root.
;;;; Smoke test: sbcl --script src/git-exec.lsp --uid 1000 --gid 1000 --program /usr/bin/git -- --version

(require :sb-posix)

(defun git-exec-argument (arguments name)
  "Return the value after NAME in ARGUMENTS, or NIL."
  (let ((tail (member name arguments :test #'string=)))
    (when tail (second tail))))

(sb-alien:define-alien-routine ("setgroups" git-exec-setgroups) sb-alien:int
  (size sb-alien:unsigned-int)
  (list sb-alien:system-area-pointer))

(defun git-exec-clear-supplementary-groups ()
  "Clear supplementary groups before setuid (setuid does not clear group 0)."
  (when (minusp (git-exec-setgroups 0 (sb-sys:int-sap 0)))
    (error "Could not clear the supplementary groups.")))

(defun git-exec-positive-integer (arguments name)
  "Return the positive integer after NAME, or signal."
  (let ((text (git-exec-argument arguments name)))
    (unless text
      (error "~A is required." name))
    (let ((value (parse-integer text)))
      (unless (plusp value)
        (error "~A must be positive." name))
      value)))

(defun git-exec-drop-privileges (arguments)
  "Drop root privileges before Git reads repo config; no-op when non-root.
Parses --uid/--gid before modifying process credentials."
  (when (zerop (sb-posix:geteuid))
    (let ((uid (git-exec-positive-integer arguments "--uid"))
          (gid (git-exec-positive-integer arguments "--gid")))
      (git-exec-clear-supplementary-groups)
      (sb-posix:setgid gid)
      (sb-posix:setuid uid)
      (unless (and (= uid (sb-posix:getuid) (sb-posix:geteuid))
                   (= gid (sb-posix:getgid) (sb-posix:getegid)))
        (error "Git privilege drop did not take effect.")))))

(defun git-exec-command (arguments)
  "Return the Git program and the arguments after --."
  (let ((program (git-exec-argument arguments "--program"))
        (tail (member "--" arguments :test #'string=)))
    (unless program
      (error "--program PATH is required."))
    (unless tail
      (error "Git arguments must follow --."))
    (values program (rest tail))))

(defun git-exec-run (arguments)
  "Start Git with the arguments after -- and return its exit status."
  (multiple-value-bind (program command) (git-exec-command arguments)
    (let ((process (sb-ext:run-program program command
                                       :search t
                                       :input *standard-input*
                                       :output *standard-output*
                                       :error *error-output*
                                       :wait t)))
      (finish-output)
      (let ((status (sb-ext:process-exit-code process)))
        (if (integerp status) status 1)))))

(handler-case
    (let ((arguments (rest sb-ext:*posix-argv*)))
      (git-exec-drop-privileges arguments)
      (sb-ext:exit :code (git-exec-run arguments)))
  (error (condition)
    (format *error-output* "git-exec: ~A~%" condition)
    (finish-output *error-output*)
    (sb-ext:exit :code 1)))
