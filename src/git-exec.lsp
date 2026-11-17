;;;; git-exec.lsp --- Drop to the agent identity before Git reads a repository.
;;;;
;;;; Git runs the hooks and local configuration it finds in the repository, and
;;;; the agent owns that repository. A root supervisor therefore cannot run Git
;;;; there: the ownership check refuses, and where an operator bypassed it, an
;;;; agent-written hook would run as root. This bootstrap is started instead.
;;;; It requires only sb-posix, drops the supplementary groups, the group
;;;; id, and the user id, and only then starts Git. No file under the agent
;;;; directory is read before the drop.
;;;;
;;;; The four identity calls repeat broker-exec.lsp rather than sharing a file.
;;;; A shared bootstrap would be one more path the root process loads before it
;;;; drops, and the broker bootstrap carries ASDF and verification code this
;;;; script must never reach.
;;;;
;;;; Run it by hand for a smoke test:
;;;;
;;;;   sbcl --script src/git-exec.lsp --uid 1000 --gid 1000 \
;;;;     --program /usr/bin/git -- --version

(require :sb-posix)

(defun git-exec-argument (arguments name)
  "Return the value after NAME in ARGUMENTS, or NIL."
  (let ((tail (member name arguments :test #'string=)))
    (when tail (second tail))))

(sb-alien:define-alien-routine ("setgroups" git-exec-setgroups) sb-alien:int
  (size sb-alien:unsigned-int)
  (list sb-alien:system-area-pointer))

(defun git-exec-clear-supplementary-groups ()
  "Clear every supplementary group before the uid drop.
SETUID does not change the group list, so a child that keeps group 0 can still
read group-owned files after it becomes the agent."
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
  "Drop root privileges before Git reads repository configuration.

Only a root process drops. A non-root process has no identity to shed, and a
test or a host checkout must not try. The uid and gid are parsed before the
first identity call, so a malformed command line stops before the group list is
touched."
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
