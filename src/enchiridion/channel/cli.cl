;;;; cli.cl --- The command table that backs both the shell and the REPL.
;;;;
;;;; One table, two surfaces. A shell command is one program invocation that
;;;; prints and exits; the REPL is the same commands with a live process behind
;;;; them. Keeping the rows in one list is what stops the two from drifting: a
;;;; command added for the shell is a command the REPL already has, and the
;;;; arity check is written once.
;;;;
;;;; Everything here is ordinary Lisp rather than a framework. A row is a list,
;;;; a handler is a function of the argument list, and the live objects a
;;;; handler needs travel in *COMMAND-CONTEXT* rather than in a second
;;;; parameter, so every handler keeps the one argument the table promises.
;;;;
;;;; A handler prints and returns an exit status. It does not signal for a
;;;; usage mistake: the operator gets a line, not a backtrace. The conditions
;;;; stay for the code paths that call these functions in process.

(in-package #:enchiridion.channel.cli)

;;;; The context.

;; Every slot is opaque to this file except GENERATION, RESPOND and CANCEL.
;; A command handler reads what it needs and nothing here depends on the shape
;; of a store, a broker or an agent, which is what lets the same handler run in
;; a one-shot shell process and in the supervisor.
(defstruct command-context
  (directory nil :type t)                 ; the agent directory
  (config nil :type t)                    ; the active configuration
  (store nil :type t)                     ; the open memory store
  (agent nil :type t)                     ; the live agent, or NIL
  (session nil :type t)                   ; the live session, or NIL
  (broker nil :type t)                    ; the broker handle, or NIL
  (generation nil :type (or null integer)) ; the loaded code generation
  (supervisor nil :type t)                ; the supervisor this process owns
  (channel nil :type t)                   ; the channel this command arrived on
  (respond nil :type (or null function))  ; one string in, one turn out
  (cancel nil :type (or null function)))  ; ask the turn in flight to stop

(defparameter *command-context* (make-command-context)
  "The live objects the current command reads.

The caller binds this around RUN-COMMAND or RUN-REPL. A handler never takes a
second argument, so the shell path and the REPL path call the same function
object with the same shape.")

;; The table itself is filled at the end of this file, after every handler it
;; names exists. The special proclamation lets the lookup functions below refer
;; to it before the DEFPARAMETER that gives it a value.
(declaim (special *commands*))

;;;; Small helpers.

(declaim (ftype (function (string &rest t) null) say))

(defun say (control &rest arguments)
  "Write one line to the command output and return NIL."
  (apply #'format *standard-output* control arguments)
  (terpri *standard-output*)
  nil)

(declaim (ftype (function () t) context))

(defun context ()
  "Return the command context the caller bound."
  *command-context*)

(declaim (ftype (function () (or string pathname)) context-directory))

(defun context-directory ()
  "Return the agent directory this command works in."
  (or (command-context-directory (context)) (enchiridion:agent-directory)))

(declaim (ftype (function () pathname) agent-root))

(defun agent-root ()
  "Return the agent directory as a directory pathname."
  (uiop:ensure-directory-pathname (context-directory)))

(declaim (ftype (function (string) (or null integer)) require-respond))

(defun require-respond (command)
  "Return 1 after one readable line when COMMAND has no live agent, else NIL."
  (unless (command-context-respond (context))
    (say "~A needs a live agent. Start one with `chat`, or use `ask` from a shell." command)
    1))

(declaim (ftype (function (string) (or null integer)) require-store))

(defun require-store (command)
  "Return 1 after one readable line when COMMAND has no store, else NIL."
  (unless (command-context-store (context))
    (say "~A needs the memory store, and none is open in this process." command)
    1))

(declaim (ftype (function () t) supervisor-status))

(defun supervisor-status ()
  "Return the status a live supervisor wrote, or NIL when none is running."
  (let ((status (enchiridion.supervisor:read-status)))
    (when (enchiridion.supervisor:status-fresh-p status)
      status)))

(declaim (ftype (function (string) integer) no-supervisor))

(defun no-supervisor (command)
  "Say that COMMAND found no running supervisor and return 1."
  (say "~A: no supervisor is running, so nothing was asked." command)
  1)

(declaim (ftype (function (t) integer) report-control))

(defun report-control (status)
  "Print the one line a supervisor wrote back about STATUS and return 0."
  (let ((report (enchiridion.supervisor:status-report status)))
    (when report (say "~A" report)))
  (say "generation ~A." (enchiridion.supervisor:status-generation status))
  0)

(declaim (ftype (function (t) string) status-channel-line))

(defun status-channel-line (row)
  "Return one line for ROW, a channel entry from the status file."
  (if (hash-table-p row)
      (format nil "~A ~A" (gethash "name" row) (gethash "state" row))
      (format nil "~A" row)))

(declaim (ftype (function (list) string) join-arguments))

(defun join-arguments (arguments)
  "Return ARGUMENTS joined by single spaces."
  (format nil "~{~A~^ ~}" arguments))

(declaim (ftype (function (string) list) split-line))

(defun split-line (line)
  "Split LINE on spaces, dropping the empty parts a run of spaces leaves."
  (remove-if (lambda (part) (zerop (length part)))
             (uiop:split-string line :separator " ")))

(declaim (ftype (function (t) (or null integer)) parse-index))

(defun parse-index (text)
  "Return TEXT as a positive integer, or NIL when it is not one."
  (let ((number (and (stringp text) (parse-integer text :junk-allowed t))))
    (and number (plusp number) number)))

(declaim (ftype (function (t) string) safe-read-file))

(defun safe-read-file (path)
  "Return PATH as a string, or a one line note when it cannot be read."
  (handler-case (uiop:read-file-string path :external-format :utf-8)
    (error (condition) (format nil "cannot read ~A: ~A" path condition))))

(declaim (ftype (function (t) boolean) lisp-source-p))

(defun lisp-source-p (path)
  "Return T when PATH is a .cl file whose name does not start with a dot."
  (let ((name (file-namestring path)))
    (and (plusp (length name))
         (not (char= #\. (char name 0)))
         (equal "cl" (string-downcase (or (pathname-type path) ""))))))

(declaim (ftype (function (string) list) agent-files-in))

(defun agent-files-in (subdirectory)
  "Return the Lisp files directly under SUBDIRECTORY of the agent directory."
  (let* ((root (agent-root))
         (path (merge-pathnames subdirectory root)))
    (when (probe-file path)
      (sort (remove-if-not #'lisp-source-p (uiop:directory-files path))
            #'string< :key #'file-namestring))))

(declaim (ftype (function (list) integer) list-numbered))

(defun list-numbered (files)
  "Print FILES numbered from one and return how many there were."
  (loop for file in files
        for index from 1
        do (say "~2D. ~A" index (file-namestring file)))
  (length files))

(declaim (ftype (function (list t) integer) show-numbered))

(defun show-numbered (files argument)
  "Print the file ARGUMENT names in FILES, counting from one."
  (let ((index (parse-index argument)))
    (unless index
      (say "expected the number of an entry.")
      (return-from show-numbered 2))
    (let ((file (nth (1- index) files)))
      (unless file
        (say "there is no entry ~D." index)
        (return-from show-numbered 1))
      (say "~A" (safe-read-file file))
      0)))

(declaim (ftype (function (list) null) print-row))

(defun print-row (row)
  "Print ROW, one store plist, one column per line, and return NIL."
  (loop for (key value) on row by #'cddr
        do (say "  ~(~A~): ~A" key value))
  nil)

(declaim (ftype (function (t integer) (or null string)) revision-at))

(defun revision-at (directory index)
  "Return the revision at 1-based INDEX in DIRECTORY's log, or NIL."
  (let ((log (ignore-errors (enchiridion.git:git-log directory :limit index))))
    (let ((entry (nth (1- index) log)))
      (and entry (car entry)))))

(declaim (ftype (function (t (or null string)) (or null string)) resolve-revision))

(defun resolve-revision (directory argument)
  "Return the revision ARGUMENT names: a 1-based log position, or a hash."
  (let ((index (parse-index argument)))
    (if index (revision-at directory index) argument)))

;;;; The table and its lookups.
;;;;
;;;; The handlers come first in the file only because a row names one; the
;;;; lookups below read *COMMANDS*, which is filled at the foot of the file.

(declaim (ftype (function () list) command-table))

(defun command-table ()
  "Return the shared command table: one row per command.

A row is (name minimum maximum handler summary). MAXIMUM is NIL for a command
that takes any number of arguments, which only ASK and MEMORY do, because
their argument is free text."
  *commands*)

(declaim (ftype (function (t) (or null list)) find-command))

(defun find-command (name)
  "Return the command row called NAME, or NIL. NAME is a string or a symbol."
  (find (string name) *commands* :key #'first :test #'string-equal))

(declaim (ftype (function () list) command-names))

(defun command-names ()
  "Return every command name, in table order."
  (mapcar #'first *commands*))

(declaim (ftype (function (list) string) arity-text))

(defun arity-text (row)
  "Return a short phrase for how many arguments ROW takes."
  (let ((minimum (second row))
        (maximum (third row)))
    (cond
      ((and (zerop minimum) (eql 0 maximum)) "no arguments")
      ((null maximum) (format nil "at least ~D argument~:P" minimum))
      ((= minimum maximum) (format nil "exactly ~D argument~:P" minimum))
      (t (format nil "~D to ~D arguments" minimum maximum)))))

(declaim (ftype (function (&optional t) integer) command-help))

(defun command-help (&optional name)
  "Print the command list, or the detail for NAME.

Return 0, or 2 for a name that is not a command. The detail is the summary and
the argument range, which is all a caller needs to form a correct call."
  (if name
      (let ((row (find-command name)))
        (unless row
          (say "There is no command called ~A." name)
          (return-from command-help 2))
        (say "~A -- ~A" (first row) (fifth row))
        (say "  arguments: ~A" (arity-text row))
        0)
      (progn
        (dolist (row *commands*)
          (say "~A~VT~A" (first row) 14 (fifth row)))
        0)))

(declaim (ftype (function (t list) integer) run-command))

(defun run-command (name arguments)
  "Run the command NAME with ARGUMENTS and return its exit status.

The table's minimum and maximum are checked before dispatch. An unknown name,
or a call outside the range, prints one line and returns 2 without running
anything. A command that succeeded returns 0; a command that refused its
situation returns 1 and says why."
  (let ((row (find-command name)))
    (unless row
      (say "There is no command called ~A. Try `help`." name)
      (return-from run-command 2))
    (let ((count (length arguments))
          (minimum (second row))
          (maximum (third row)))
      (unless (and (>= count minimum) (or (null maximum) (<= count maximum)))
        (say "~A takes ~A; got ~D." (first row) (arity-text row) count)
        (return-from run-command 2))
      (let ((status (funcall (fourth row) arguments)))
        (if (integerp status) status 0)))))

;;;; The REPL surface.

(declaim (ftype (function () list) repl-only-commands))

(defun repl-only-commands ()
  "Return the commands only the REPL has, because they act on the live turn."
  '("stop" "quit" "who"))

(declaim (ftype (function () t) request-cancel))

(defun request-cancel ()
  "Ask the turn in flight to stop, or say there is nothing to stop."
  (let ((cancel (command-context-cancel (context))))
    (if cancel
        (progn (funcall cancel) (say "cancellation requested.") 0)
        (progn (say "there is no turn to stop.") 1))))

(declaim (ftype (function () integer) report-who))

(defun report-who ()
  "Print which channel is live and what the supervisor says it is doing.

The context slot holds a channel object when a supervisor started one, and a
name when the command came straight from the shell. Both answers are useful,
and neither is worth an error."
  (let ((channel (command-context-channel (context))))
    (cond
      ((null channel)
       (say "no channel is attached to this command context."))
      ((typep channel 'enchiridion.channel:channel)
       (say "channel ~A is ~(~A~)"
            (enchiridion.channel:channel-name channel)
            (enchiridion.channel:channel-state channel)))
      (t
       (say "channel ~(~A~) is attached to this command context." channel))))
  (let ((status (supervisor-status)))
    (if status
        (progn
          (say "supervisor generation ~A" (enchiridion.supervisor:status-generation status))
          (dolist (row (enchiridion.supervisor:status-channels status))
            (say "  ~A" (status-channel-line row))))
        (say "no supervisor is running.")))
  0)

(declaim (ftype (function (string) t) run-plain-turn))

(defun run-plain-turn (text)
  "Send TEXT through the respond function, or say that no agent is live."
  (let ((respond (command-context-respond (context))))
    (unless respond
      (say "There is no live agent to answer that. /quit leaves.")
      (return-from run-plain-turn 1))
    (funcall respond text)))

(declaim (ftype (function (string list) t) evaluate-repl-command))

(defun evaluate-repl-command (name arguments)
  "Evaluate a slash line: one of the REPL-only commands, or a table command."
  (cond
    ((string= name "quit") :quit)
    ((string= name "stop") (request-cancel))
    ((string= name "who") (report-who))
    (t (run-command name arguments))))

(declaim (ftype (function (string) t) repl-evaluate))

(defun repl-evaluate (line)
  "Evaluate one REPL LINE. Return :QUIT to leave the session.

A line beginning with a slash is a command; anything else is a turn sent
through the respond function, so the REPL and the shell share one path."
  (let ((trimmed (string-trim '(#\Space #\Tab #\Return) line)))
    (cond
      ((zerop (length trimmed)) 0)
      ((char= #\/ (char trimmed 0))
       (let ((parts (split-line trimmed)))
         (evaluate-repl-command (string-downcase (subseq (first parts) 1))
                                (rest parts))))
      (t (run-plain-turn trimmed)))))

(declaim (ftype (function (&key (:context t) (:input t) (:output t)) t) run-repl))

(defun run-repl (&key (context *command-context*)
                      (input *standard-input*)
                      (output *standard-output*))
  "Read lines from INPUT and evaluate each, until the operator quits or INPUT
ends. Return :QUIT or :EOF."
  (let ((*command-context* context)
        (*standard-input* input)
        (*standard-output* output))
    (loop
      (format output "~&enchiridion> ")
      (finish-output output)
      (let ((line (read-line input nil :eof)))
        (when (eq line :eof)
          (return :eof))
        (let ((result (repl-evaluate line)))
          (when (eq result :quit)
            (return :quit)))))))

;;;; The handlers.
;;;;
;;;; Each one takes the argument list, reads *COMMAND-CONTEXT*, prints, and
;;;; returns an exit status. Nothing here signals for a usage mistake.

(declaim (ftype (function (list) integer) cmd-init))

(defun cmd-init (arguments)
  "Create the agent directory and its seed files, never overwriting one."
  (declare (ignore arguments))
  (let ((result (enchiridion.memory:init-agent (context-directory))))
    (say "~A" (enchiridion.memory:init-status-line result))
    (dolist (name (enchiridion.memory:init-created result))
      (say "  created ~A" name))
    (dolist (name (enchiridion.memory:init-existing result))
      (say "  kept    ~A" name))
    (dolist (problem (enchiridion.memory:init-problems result))
      (say "  problem ~A" problem))
    (if (enchiridion.memory:init-problems result) 1 0)))

(declaim (ftype (function (list) integer) cmd-ask))

(defun cmd-ask (arguments)
  "Run one turn in a short lived session, print the reply, and exit."
  (let ((missing (require-respond "ask")))
    (if missing missing (funcall (command-context-respond (context))
                                 (join-arguments arguments)))))

(declaim (ftype (function (list) integer) cmd-check))

(defun cmd-check (arguments)
  "Compile the whole tree under safety 3 through the same gate nix runs."
  (declare (ignore arguments))
  (multiple-value-bind (output status)
      (handler-case
          (enchiridion.compat:run-program-capture
           "nix" (list "--option" "eval-cache" "false" "run" ".#check") :timeout 3600)
        (error (condition) (values (format nil "~A" condition) :unavailable)))
    (say "~A" output)
    (if (eql 0 status) 0 1)))

(declaim (ftype (function (t) t) skill-trigger))

(defun skill-trigger (path)
  "Return the trigger line a skill file declares, or NIL.

The trigger is the string in a top-level (defparameter +trigger+ ...) form. The
file is read with *READ-EVAL* NIL and nothing is evaluated: a listing must not
run the code it lists. A file that will not read has no trigger, and that is
not an error for a listing."
  (handler-case
      (with-open-file (stream path :direction :input :external-format :utf-8)
        (let ((*read-eval* nil)
              (*package* (find-package :enchiridion.channel.cli)))
          (loop for form = (read stream nil :eof)
                until (eq form :eof)
                when (and (consp form)
                          (eq (first form) 'defparameter)
                          (symbolp (second form))
                          (string-equal "+TRIGGER+" (symbol-name (second form)))
                          (stringp (third form)))
                  do (return (third form)))))
    (error () nil)))

(declaim (ftype (function (list) integer) cmd-skills))

(defun cmd-skills (arguments)
  "List the agent's skills with their trigger line, or show one.

The trigger line is charged on every turn, which is why it is short and why it
belongs in the listing the operator reads."
  (let ((files (agent-files-in "skills/"))
        (action (string-downcase (or (first arguments) "list"))))
    (cond
      ((string= action "list")
       (if files
           (loop for path in files
                 for index from 1
                 do (say "~D. ~A~@[ -- ~A~]"
                         index (file-namestring path) (skill-trigger path)))
           (say "no skills yet."))
       0)
      ((string= action "show") (show-numbered files (second arguments)))
      (t (say "skills takes list or show NUMBER.") 2))))

(declaim (ftype (function (list) integer) cmd-tools))

(defun cmd-tools (arguments)
  "List every registered tool with its schema token cost, or show one schema."
  (let ((action (string-downcase (or (first arguments) "list"))))
    (cond
      ((string= action "list")
       (let ((tools (enchiridion.tools:list-tools)))
         (if tools
             (dolist (tool tools)
               (say "~A ~D tokens - ~A"
                    (enchiridion.tools:tool-name tool)
                    (enchiridion.tools:schema-tokens (enchiridion.tools:tool-schema tool))
                    (enchiridion.tools:tool-description tool)))
             (say "no tools are registered in this process."))
       0))
      ((string= action "show")
       (let ((name (second arguments)))
         (unless name
           (say "tools show needs a tool name.")
           (return-from cmd-tools 2))
         (let ((tool (find name (enchiridion.tools:list-tools)
                           :key #'enchiridion.tools:tool-name :test #'string-equal)))
           (unless tool
             (say "There is no tool called ~A." name)
             (return-from cmd-tools 1))
           (say "~A" (enchiridion.tools:schema-json-string
                      (enchiridion.tools:tool-schema tool)))
           0)))
      (t (say "tools takes list or show NAME.") 2))))

(defparameter +block-files+
  '(("soul" . "SOUL.md")
    ("persona" . "SOUL.md")
    ("operator" . "OPERATOR.md")
    ("world" . "WORLD.md"))
  "The memory block labels that have a Markdown file, and the file each uses.")

(declaim (ftype (function (list) integer) cmd-blocks))

(defun cmd-blocks (arguments)
  "Show the memory blocks with their character counts and capacity, or name the
file a block is backed by."
  (let ((action (string-downcase (or (first arguments) "show"))))
    (cond
      ((string= action "show")
       (loop for (label . file) in +block-files+
             for path = (merge-pathnames file (agent-root))
             for text = (if (probe-file path) (safe-read-file path) "")
             do (say "~(~A~) ~D/~D ~A"
                     label
                     (length text)
                     (enchiridion.memory:default-block-limit
                      (intern (string-upcase label) :keyword))
                     path))
       0)
      ((string= action "edit")
       (let ((index (parse-index (second arguments))))
         (unless index
           (say "blocks edit needs the number of a block.")
           (return-from cmd-blocks 2))
         (let ((file (nth (1- index) (mapcar #'cdr +block-files+))))
           (unless file
             (say "there is no block ~D." index)
             (return-from cmd-blocks 1))
           (say "~A" (merge-pathnames file (agent-root)))
           0)))
      (t (say "blocks takes show or edit NUMBER.") 2))))

(declaim (ftype (function (list string string) integer) show-or-edit))

(defun show-or-edit (arguments name file)
  "Show or point at the agent file FILE for the command called NAME."
  (let ((path (merge-pathnames file (agent-root)))
        (action (string-downcase (or (first arguments) "show"))))
    (cond
      ((string= action "show") (say "~A" (safe-read-file path)) 0)
      ((string= action "edit") (say "~A" path) 0)
      (t (say "~A takes show or edit." name) 2))))

(declaim (ftype (function (list) integer) cmd-persona))

(defun cmd-persona (arguments)
  "Show or point at SOUL.md, the agent's identity."
  (show-or-edit arguments "persona" "SOUL.md"))

(declaim (ftype (function (list) integer) cmd-operator))

(defun cmd-operator (arguments)
  "Show or point at OPERATOR.md, who the agent works for."
  (show-or-edit arguments "operator" "OPERATOR.md"))

(declaim (ftype (function (list) integer) cmd-world))

(defun cmd-world (arguments)
  "Show or point at WORLD.md, the agent's environment."
  (show-or-edit arguments "world" "WORLD.md"))

(declaim (ftype (function (list) integer) cmd-memory))

(defun cmd-memory (arguments)
  "Search stored memories and past sessions for the query."
  (let ((missing (require-store "memory")))
    (if missing
        missing
        (let* ((store (command-context-store (context)))
               (query (join-arguments arguments))
               (memories (ignore-errors (enchiridion.memory.store:search-memories store query)))
               (turns (ignore-errors (enchiridion.memory.store:search-sessions store query))))
          (say "memories: ~D" (length memories))
          (dolist (row memories) (print-row row))
          (say "turns: ~D" (length turns))
          (dolist (row turns) (print-row row))
          0))))

(declaim (ftype (function (list) integer) cmd-sessions))

(defun cmd-sessions (arguments)
  "List stored sessions with their turn counts."
  (declare (ignore arguments))
  (let ((missing (require-store "sessions")))
    (if missing
        missing
        (let ((store (command-context-store (context))))
          (dolist (row (enchiridion.memory.store:recent-sessions store))
            (say "~A ~D turns" (getf row :id) (getf row :turns)))
          (say "~D session~:P in the store." (enchiridion.memory.store:session-count store))
          0))))

(declaim (ftype (function (list) integer) cmd-journey))

(defun cmd-journey (arguments)
  "List, show, edit or revert the changes written into the agent directory."
  (let* ((directory (context-directory))
         (action (string-downcase (or (first arguments) "list"))))
    (cond
      ((string= action "list")
       (let ((log (ignore-errors (enchiridion.git:git-log directory :limit 20))))
         (if log
             (loop for (revision . subject) in log do (say "~A ~A" revision subject))
             (say "the agent directory has no history yet.")))
       0)
      ((string= action "show")
       (let ((revision (resolve-revision directory (second arguments))))
         (unless revision
           (say "journey show needs a revision or a number.")
           (return-from cmd-journey 2))
         (say "~A" (ignore-errors (enchiridion.git:git-show directory revision)))
         0))
      ((string= action "edit")
       (let ((revision (resolve-revision directory (second arguments))))
         (unless revision
           (say "journey edit needs a revision or a number.")
           (return-from cmd-journey 2))
         (say "edit ~A by hand; the change is ~A." directory revision)
         0))
      ((string= action "rm")
       (let ((revision (resolve-revision directory (second arguments))))
         (unless revision
           (say "journey rm needs a revision or a number.")
           (return-from cmd-journey 2))
         (say "~A" (ignore-errors (enchiridion.git:git-revert directory revision)))
         0))
      (t (say "journey takes list, show, edit or rm.") 2))))

(declaim (ftype (function (list) integer) cmd-undo))

(defun cmd-undo (arguments)
  "Roll back the nth change in the agent directory."
  (let* ((directory (context-directory))
         (revision (resolve-revision directory (first arguments))))
    (unless revision
      (say "undo needs the number of a change.")
      (return-from cmd-undo 2))
    (let ((result (ignore-errors (enchiridion.git:git-revert directory revision))))
      (if result
          (progn (say "reverted ~A." revision) 0)
          (progn (say "could not revert ~A." revision) 1)))))

(declaim (ftype (function (list) integer) cmd-usage))

(defun cmd-usage (arguments)
  "Print the token ledger grouped by model, by channel and by day.

The four numbers a provider reports are the point of the ledger, so cache read
and cache write are named in the header: a report that hides them cannot answer
whether the frozen prompt is keeping the prefix cache warm, which is the most
expensive quiet failure this system has.

The rows come from one SQL grouping rather than from the raw rows, so the
report is the same whether a shell or the webhook asks for it."
  (declare (ignore arguments))
  (let ((missing (require-store "usage")))
    (if missing
        missing
        (let ((store (command-context-store (context))))
          (print-usage-group store :model "model" "by model")
          (print-usage-group store :channel "channel" "by channel")
          (print-usage-group store :day "day" "by day")
          0))))

(declaim (ftype (function (t keyword string string) null) print-usage-group))

(defun print-usage-group (store group-by key heading)
  "Print one grouped ledger section for GROUP-BY."
  (let ((rows (handler-case (enchiridion.memory.store:usage-summary
                              store :group-by group-by)
                (error () '()))))
    (say "~A" heading)
    (if rows
        (progn
          ;; One line per group, built as a string and printed with ~A: a model
          ;; name is text a provider chose, and text is never a format control.
          (say "  ~A" (format nil "~12A ~10@A ~10@A ~11@A ~12@A ~6@A"
                              key "input" "output" "cache read" "cache write" "calls"))
          (dolist (row rows)
            (say "  ~A"
                 (format nil "~12A ~10D ~10D ~11D ~12D ~6D"
                         (format nil "~A" (getf row (intern (string-upcase key) :keyword)))
                         (getf row :input) (getf row :output)
                         (getf row :cache-read) (getf row :cache-write)
                         (getf row :calls)))))
        (say "  the ledger is empty.")))
  nil)

(declaim (ftype (function (list) integer) cmd-budget))

(defun cmd-budget (arguments)
  "Print the token caps and, when an agent is live, how much of each is spent.

The caps live in the :BUDGET section, so they are read with
CONFIG-SECTION-VALUE. CONFIG-VALUE reads the :LLM section and answered none
for a cap that was configured, which made an unattended budget look uncapped."
  (declare (ignore arguments))
  (let ((configuration (command-context-config (context))))
    (say "tick cap: ~A"
         (enchiridion:config-section-value configuration :budget
                                          :max-tokens-per-tick "none"))
    (say "day cap:  ~A"
         (enchiridion:config-section-value configuration :budget
                                          :max-tokens-per-day "none"))
    (let ((agent (command-context-agent (context))))
      (when agent
        (say "tick spent out: ~A" (enchiridion.kernel:budget-exhausted-p agent :window :tick))
        (say "day spent out:  ~A" (enchiridion.kernel:budget-exhausted-p agent :window :day))))
    0))

(declaim (ftype (function (list) integer) cmd-tasks))

(defun cmd-tasks (arguments)
  "List the task queue, add a task, or remove one by id.

`tasks list failed` and its three siblings exist because a task now has a
status that matters: a task the sleep agent failed is not a task that finished,
and the operator has to be able to see which is which."
  (let ((missing (require-store "tasks")))
    (if missing
        missing
        (let ((action (string-downcase (or (first arguments) "list")))
              (store (command-context-store (context))))
          (cond
            ((string= action "list")
             (let* ((word (second arguments))
                    (status (and word (intern (string-upcase word) :keyword))))
               (when (and status
                          (not (member status '(:pending :running :done :failed)
                                       :test #'eq)))
                 (say "tasks list takes pending, running, done or failed.")
                 (return-from cmd-tasks 2))
               (let ((tasks (enchiridion.memory.store:list-tasks
                             store :status status)))
                 (if tasks
                     (dolist (task tasks)
                       (say "~D ~(~A~) ~A"
                            (enchiridion.memory.store:task-row-id task)
                            (enchiridion.memory.store:task-row-status task)
                            (enchiridion.memory.store:task-row-body task)))
                     (say "no tasks~@[ with status ~(~A~)~]." status))))
             0)
            ((string= action "add")
             (unless (rest arguments)
               (say "tasks add needs the text of the task.")
               (return-from cmd-tasks 2))
             (let ((task (enchiridion.memory.store:enqueue-task
                          store (join-arguments (rest arguments)))))
               (say "task ~D queued." (enchiridion.memory.store:task-row-id task))
               0))
            ((string= action "rm")
             (let ((id (parse-index (second arguments))))
               (unless id
                 (say "tasks rm needs the id of a task.")
                 (return-from cmd-tasks 2))
               (if (enchiridion.memory.store:remove-task store id)
                   (say "task ~D removed." id)
                   (say "there is no task ~D." id))
               0))
            (t (say "tasks takes list, add or rm.") 2))))))

(declaim (ftype (function (list) integer) cmd-secrets))

(defun cmd-secrets (arguments)
  "List the loaded secret names and their sources, never their values."
  (declare (ignore arguments))
  (let ((names (enchiridion.llm.secrets:secret-names)))
    (if names
        (dolist (name names)
          (say "~A from ~(~A~)" name (enchiridion.llm.secrets:secret-source name)))
        (say "no secrets are loaded."))
    0))

(declaim (ftype (function (list) integer) cmd-version))

(defun cmd-version (arguments)
  "Print the version and the provenance of the checkout."
  (declare (ignore arguments))
  (say "enchiridion 0.1.0")
  (let ((root (enchiridion:project-root)))
    (if root
        (let ((branch (ignore-errors (enchiridion.git:git-current-branch root)))
              (head (ignore-errors (enchiridion.git:git-head root))))
          (say "source ~A" root)
          (when (and branch (plusp (length branch)))
            (say "branch ~A" branch))
          (when (and head (plusp (length head)))
            (say "head   ~A" head)))
        (say "no checkout was found above this directory.")))
  0)

(declaim (ftype (function (list) integer) cmd-help))

(defun cmd-help (arguments)
  "Print the command list, or the detail for one command."
  (command-help (first arguments)))

(declaim (ftype (function (list) integer) cmd-health))

(defun cmd-health (arguments)
  "Read the status file and report whether a supervisor is up.

The heartbeat line is the answer to the question the status file could never
answer before: unattended work either happened, or said why it did not."
  (declare (ignore arguments))
  (let ((status (supervisor-status)))
    (unless status
      (say "no supervisor is running.")
      (return-from cmd-health 1))
    (say "supervisor pid ~A, generation ~A."
         (enchiridion.supervisor:status-pid status)
         (enchiridion.supervisor:status-generation status))
    (let ((report (enchiridion.supervisor:status-report status)))
      (when report (say "~A" report)))
    (let ((beat (enchiridion.supervisor:status-heartbeat status)))
      (when (hash-table-p beat)
        (say "heartbeat ~:[off~;on~], ~D tick~:P, last at ~A~@[: ~A~]"
             (gethash "enabled" beat)
             (or (gethash "ticks" beat) 0)
             (or (gethash "last-tick" beat) 0)
             (let ((line (gethash "report" beat)))
               (if (and (stringp line) (plusp (length line))) line nil)))))
    (dolist (row (enchiridion.supervisor:status-channels status))
      (say "channel ~A" (status-channel-line row)))
    0))

(declaim (ftype (function (list) integer) cmd-reload))

(defun cmd-reload (arguments)
  "Ask the running supervisor to verify and load the agent code again.

Return 1 when the supervisor refused the generation. A refused reload keeps the
last good code serving, which is the right behaviour and the wrong exit status:
an operator script that reloads and carries on has to be able to see that the
agent is still running the old code."
  (declare (ignore arguments))
  (let ((status (enchiridion.supervisor:request-control "reload")))
    (cond
      ((null status) (no-supervisor "reload"))
      ((enchiridion.supervisor:status-report-ok-p status)
       (report-control status))
      (t
       (report-control status)
       1))))

(declaim (ftype (function (list) integer) cmd-channels))

(defun cmd-channels (arguments)
  "List, enable or disable a channel on the running supervisor."
  (let ((action (string-downcase (or (first arguments) "list"))))
    (unless (member action '("list" "enable" "disable") :test #'string=)
      (say "channels takes list, enable NAME or disable NAME.")
      (return-from cmd-channels 2))
    (let* ((line (if (rest arguments)
                     (format nil "channels ~A ~A" action (second arguments))
                     (format nil "channels ~A" action)))
           (status (enchiridion.supervisor:request-control line)))
      (if status (report-control status) (no-supervisor "channels")))))

(declaim (ftype (function (list) integer) cmd-heartbeat))

(defun cmd-heartbeat (arguments)
  "Turn the heartbeat on or off, or ask for one tick."
  (let ((action (string-downcase (or (first arguments) "on"))))
    (unless (member action '("on" "off" "run") :test #'string=)
      (say "heartbeat takes on, off or run.")
      (return-from cmd-heartbeat 2))
    (let ((status (enchiridion.supervisor:request-control
                   (format nil "heartbeat ~A" action))))
      (if status (report-control status) (no-supervisor "heartbeat")))))

(declaim (ftype (function (list) integer) cmd-chat))

(defun cmd-chat (arguments)
  "Start the REPL and return when the operator quits."
  (declare (ignore arguments))
  (run-repl :context (context))
  0)

(declaim (ftype (function (list) integer) cmd-serve))

(defun cmd-serve (arguments)
  "Start the supervisor and poll its control file until the process stops.

The poll loop and not a loop of POLL-CONTROL calls: the loop rewrites the
status file on every tick, and that rewrite is what keeps the file fresh
enough for a shell command in another process to believe it."
  (declare (ignore arguments))
  (let ((supervisor (command-context-supervisor (context))))
    (unless supervisor
      (say "serve needs a supervisor in the command context.")
      (return-from cmd-serve 1))
    (enchiridion.supervisor:supervisor-start supervisor)
    (enchiridion.supervisor:supervisor-poll-loop supervisor)
    0))

;;;; Filling the table.
;;;;
;;;; This runs last, so every function the rows name already exists. The rows
;;;; are plain data: name, minimum, maximum, handler, summary. MAXIMUM is NIL
;;;; for ASK and MEMORY, whose argument is free text of any length.

(declaim (ftype (function (list) integer) cmd-bootstrap))

(defun cmd-bootstrap (arguments)
  "Show the bootstrap state, list the remaining steps, or reset it.

The agent marks a step done with the meta tool, not from here: this is the
operator's view of a state machine the agent works through."
  (let ((action (string-downcase (or (first arguments) "status")))
        (directory (context-directory)))
    (cond
      ((string= action "status")
       (say "~A" (enchiridion.memory:bootstrap-status-line directory))
       0)
      ((string= action "run")
       (let ((remaining (enchiridion.memory:bootstrap-remaining directory)))
         (if remaining
             (progn
               (say "bootstrap has ~D step~:P left:" (length remaining))
               (dolist (step remaining)
                 (say "  ~D. ~A" (car step) (cdr step)))
               0)
             (progn
               (say "bootstrap is complete; the agent owns the seed files.")
               0))))
      ((string= action "reset")
       (enchiridion.memory:reset-bootstrap directory)
       (say "bootstrap reset to its first step.")
       0)
      (t
       (say "bootstrap takes status, run or reset.")
       2))))

(declaim (ftype (function () list) build-command-table))

(defun build-command-table ()
  "Return the shared command table."
  (list
   (list "init" 0 1 #'cmd-init "Create the agent directory and seed files")
   (list "ask" 1 nil #'cmd-ask "One turn in a short lived session")
   (list "check" 0 0 #'cmd-check "Compile the tree under safety 3")
   (list "skills" 0 2 #'cmd-skills "List or show skills")
   (list "tools" 0 2 #'cmd-tools "List or show tools")
   (list "blocks" 0 2 #'cmd-blocks "Blocks with character counts and capacity")
   (list "persona" 0 1 #'cmd-persona "SOUL.md")
   (list "operator" 0 1 #'cmd-operator "OPERATOR.md")
   (list "world" 0 1 #'cmd-world "WORLD.md")
   (list "memory" 1 nil #'cmd-memory "Search sessions and memories")
   (list "sessions" 0 0 #'cmd-sessions "Stored sessions with turn counts")
   (list "journey" 0 2 #'cmd-journey "Everything the agent has learned or written")
   (list "undo" 1 1 #'cmd-undo "Roll back the nth change in the agent directory")
   (list "usage" 0 0 #'cmd-usage "Token ledger by model, day and channel")
   (list "budget" 0 0 #'cmd-budget "Spend against the caps")
   (list "tasks" 0 nil #'cmd-tasks "The task queue")
   (list "secrets" 0 0 #'cmd-secrets "Names and sources, never values")
   (list "version" 0 0 #'cmd-version "Version and build provenance")
   (list "help" 0 1 #'cmd-help "Command list, or detail for one")
   (list "bootstrap" 0 1 #'cmd-bootstrap "Bootstrap state, remaining steps, or a reset")
   (list "health" 0 0 #'cmd-health "Read the running supervisor's status")
   (list "reload" 0 0 #'cmd-reload "Ask a running supervisor to reload its code")
   (list "channels" 0 2 #'cmd-channels "List, enable or disable a channel")
   (list "heartbeat" 0 1 #'cmd-heartbeat "Turn the heartbeat on, off, or run one")
   (list "chat" 0 0 #'cmd-chat "Start the REPL")
   (list "serve" 0 0 #'cmd-serve "Start the supervisor and its channels")))

(defparameter *commands* (build-command-table)
  "The shared command table. One list of rows backs the shell and the REPL, so
the two surfaces cannot drift. A row is (name minimum maximum handler summary).")

;;;; The CLI channel.

(defclass cli-channel (enchiridion.channel:channel)
  ((context :accessor cli-channel-context :initarg :context :initform nil :type t
            :documentation "The command context the REPL reads.")
   (output :accessor cli-channel-output :initarg :output :initform *standard-output* :type t
           :documentation "The stream command output and the REPL prompt go to."))
  (:documentation
   "The terminal channel. Starting it runs the REPL to completion, and sending
through it prints, so the supervisor can own it on a thread exactly like every
other channel."))

(declaim (ftype (function (&key (:context t) (:output t)) cli-channel) make-cli-channel))

(defun make-cli-channel (&key (context *command-context*) (output *standard-output*))
  "Return a stopped CLI channel over CONTEXT, printing to OUTPUT."
  (make-instance 'cli-channel :name "cli" :context context :output output))

(defmethod enchiridion.channel:channel-start ((channel cli-channel) &key config)
  "Run the REPL to completion and return CHANNEL.

The channel is live for as long as the REPL reads, which is what a supervisor
owning this channel on a thread needs to see.

A terminal is what makes this channel real. Under `serve` in a container there
is no terminal: the REPL would read end of file at once, the channel would
return, and the supervisor's restart loop would start a new one every second
for the life of the process. A channel with no terminal says so once and stops
instead, and the operator reads that line rather than a restart every second."
  (declare (ignore config))
  (unless (interactive-stream-p *standard-input*)
    (format *error-output*
            "~&enchiridion: stdin is not a terminal, so the cli channel stays down.~%")
    (finish-output *error-output*)
    (setf (enchiridion.channel:channel-live-p channel) nil
          (enchiridion.channel:channel-state channel) :stopped)
    (return-from enchiridion.channel:channel-start channel))
  (setf (enchiridion.channel:channel-live-p channel) t
        (enchiridion.channel:channel-state channel) :live)
  (unwind-protect
       (run-repl :context (cli-channel-context channel)
                 :output (cli-channel-output channel))
    (setf (enchiridion.channel:channel-live-p channel) nil
          (enchiridion.channel:channel-state channel) :stopped))
  channel)

(defmethod enchiridion.channel:channel-stop ((channel cli-channel))
  "Mark CHANNEL stopped and return it."
  (setf (enchiridion.channel:channel-live-p channel) nil
        (enchiridion.channel:channel-state channel) :stopped)
  channel)

(defmethod enchiridion.channel:channel-send ((channel cli-channel) target text &key reply-to)
  "Print TEXT on CHANNEL's output stream and return it."
  (declare (ignore target))
  (format (cli-channel-output channel) "~A~%" text)
  (when reply-to
    (format (cli-channel-output channel) "  (reply to ~A)~%" reply-to))
  text)

(defmethod enchiridion.channel:channel-status ((channel cli-channel))
  "Return CHANNEL's state."
  (enchiridion.channel:channel-state channel))

(declaim (ftype (function (&key (:context t)) cli-channel) start-cli))

(defun start-cli (&key (context *command-context*))
  "Create the CLI channel, run the REPL to completion, and return the channel."
  (let ((channel (make-cli-channel :context context)))
    (enchiridion.channel:channel-start channel)
    channel))
