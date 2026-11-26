;;;; seed.lsp --- Operator seed templates and first-run initialization.
;;;;
;;;; Seed files are created only when absent and never overwritten.

(in-package #:enchiridion.memory)

;;;; Templates.

(defparameter +guide+
  "# Guide

This directory holds one agent. The Markdown files in it are the agent's
identity, its instructions, and its memory. The directory is a git repository of
its own, nested inside the enchiridion checkout, so every change to the agent is
a commit that can be read and reverted.

## The files

| File | Written by | Contents |
| --- | --- | --- |
| `SOUL.md` | the operator, then the agent | identity, voice, and values |
| `OPERATOR.md` | the operator, then the agent | who it works for, and how |
| `WORLD.md` | the operator, then the agent | the environment: paths, commands, conventions |
| `BOOTSTRAP.md` | the operator | the first steps, worked through once |
| `ADAPT.md` | the harness | the bearing and one-preference-at-a-time adaptation |
| `GUIDE.md` | the operator | this file |

Until the bootstrap hands over, the block and file tools refuse agent writes to
the first three files. The built-in shell tool is unavailable during bootstrap. After handover,
the sleep-time agent maintains all three identity files. `ADAPT.md` is
harness-maintained: a maintenance pass may add one evidence-cited preference,
and the bearing line fades from operator emulation toward the agent's own
defaults as substantive memory and corroborated experience accumulate.

## The first run

1. Edit `SOUL.md`. The shipped text is a placeholder. State who the agent is,
   how it speaks, and what it refuses.
2. Edit `OPERATOR.md`. State who the operator is, what a good answer looks
   like, and when the agent may act or interrupt without asking.
3. Edit `WORLD.md`. State the real paths, the real commands, and the real
   conventions on this machine.
4. Run `enchiridion chat`.

The agent reads the three files on its first turn and asks about what they leave
open. The answers belong in the three files, and the operator writes them until
the bootstrap hands over.

## Bootstrap

`BOOTSTRAP.md` holds the handover procedure as a numbered list. The agent
records each step with the meta tool action `bootstrap-step`. The operator can
record one with `enchiridion bootstrap step N`.

The last step archives `BOOTSTRAP.md` as `BOOTSTRAP.done.md`, commits the
directory, and opens the block tool. `enchiridion bootstrap reset` restores the
file and clears the record. The harness documentation records the state machine.

## Commands

| Command | Output |
| --- | --- |
| `enchiridion chat` | a turn-by-turn session in the terminal |
| `enchiridion ask \"...\"` | one turn, its answer, then exit |
| `enchiridion serve` | the supervisor, with the enabled channels |
| `enchiridion blocks` | the memory blocks with character counts |
| `enchiridion skills` | every skill, with its trigger line |
| `enchiridion tools` | every tool, with its schema token cost |
| `enchiridion journey` | everything the agent has learned or written |
| `enchiridion memory \"...\"` | full text search across sessions and memories |
| `enchiridion usage` | the token ledger, with the cache columns |
| `enchiridion undo N` | roll back the Nth commit in this directory |

The REPL accepts every command except `chat` and `serve` with a leading slash.
`/stop`, `/quit`, and `/who` exist only in the REPL because they act on a turn
that is running.

## What the agent can reach

In the container deployment, or a checkout started as root, the supervisor
runs as root, holds the secrets, and agent code runs as uid 1000. In the
container the supervisor reads `.env` from a tmpfs, removes the values from its
environment, and deletes the container copy. The agent cannot read the file or
the supervisor's environment in either setup.

A checkout started as the operator has no uid split. The supervisor, the broker
child, and agent code run as that user, and the agent's file and shell tools can
read any file that user can read. The checkout `.env` stays on disk. Use the
container or a root-started checkout when the key must stay out of reach.

## History

This directory is its own git repository. The kernel attempts a commit after
each successful turn with the message `Turn N via CHANNEL`, using the operator's
Git configuration. A host without a Git identity keeps the files and skips the
commit. The history is separate from the source tree.

    git -C agents/default log
    git -C agents/default diff
    git -C agents/default show HEAD
    enchiridion undo 3

## Changing the agent

The sleep-time agent rewrites the three files it owns as it learns. Read the
diff to see what changed, and revert the commit to undo it.
"
  "The operator walkthrough.")

(defparameter +soul+
  "# Soul

The shipped text in this file is a placeholder. Replace it before the agent's
first run.

## Who it is

Give the agent a name and a short description. A name in the identity makes the
answers specific to this agent.

## How it speaks

State the answer length, whether it uses headings, and whether it shows its
work. Give a limit with a number: \"under six lines unless the question needs
more\" is a rule the agent can follow, and \"be concise\" is not.

## What it will not do

List the refusals. Nothing else in the system stops the agent from a network
call that was asked for politely, so the refusals belong here.

## What it is trying to improve

Two or three goals. The sleep-time agent rewrites this section when it has a
turn and nothing else.
"
  "Identity, voice, and values.")

(defparameter +operator+
  "# Operator

The shipped text in this file is a placeholder. Replace it before the agent's
first run.

## Who the operator is

What the operator works on, what they are building, and what they already know.
State the domain so the agent does not explain it back.

## What a good answer looks like

Detail level, tone, how much to ask before acting, and how much to do without
asking.

## When the agent may act alone

State the boundary. Reading files and writing under this directory are usually
allowed. A network call, a cost, or a change outside this directory usually
needs a question first.

## When the agent may interrupt

State both directions: what is worth an interruption, and what waits for the
next turn. State it, because a missing rule leaves the agent to guess.

## Standing constraints

Deadlines, budgets, and the work the agent must not spend time on.
"
  "Who it works for.")

(defparameter +world+
  "# World

The shipped text in this file is a placeholder. Replace it before the agent's
first run.

The agent reads this file to avoid rediscovering the machine. State only facts
that are true here.

## Where things are

Absolute paths: the source tree, the agent directory, the database, and the
control file.

## How things run

The commands that work on this machine, the container flags, the port numbers,
and the name of the environment variable that holds a key. Never the key.

## Conventions

Indentation, naming, where tests live, the commit message format, and the shape
of the work.

## Lessons

Facts that cost a turn to find. The sleep-time agent appends here. Keep entries
short and dated, and delete the ones that stopped being true.
"
  "The environment it lives in.")

(defparameter +adapt+
  "# Adaptation

Guidance only. Tool access, permissions, refusals, budgets, and the bootstrap
are enforced in code and do not change here. Explicit operator instructions
and `OPERATOR.md` override this section.

Bearing: Emulate the operator's demonstrated style and work habits closely. They are the default while your memory and experience are thin.
"
  "Harness-maintained bearing and learned preferences.")

(defparameter +bootstrap+
  "# Bootstrap

Record each completed step with `meta` action `bootstrap-step`. Continue in the
same turn whenever possible. Ask only for missing facts that block progress.

The operator may edit `SOUL.md`, `OPERATOR.md`, and `WORLD.md` at any time.
Until handover, `blockops` and `file` refuse agent writes to those files.
The built-in shell tool is also unavailable until handover. These tool
restrictions are not a substitute for an OS sandbox.

1. Read `SOUL.md`, `OPERATOR.md`, and `WORLD.md`.
2. Identify missing facts. Ask any blocking questions together; inspect local files first when they may have the answers.
3. Resolve blocking questions without guessing. If none remain, continue without waiting.
4. Save any proposed changes as `proposed/SOUL.md`, `proposed/OPERATOR.md`, or `proposed/WORLD.md`. Skip drafts for files that need no changes.
5. Create a useful reference skill under `skills/` and apply it to the current work.
6. Save a useful, non-secret memory and read it back with `search` scope `memories`.
7. Verify that the operator applied or declined the drafts. If there were no drafts, continue.
8. Record this step to archive the checklist and unlock agent writes. Report the handover.
"
  "The first steps.")

(defun upgrade-stock-bootstrap (directory)
  "Replace the old stock checklist without changing saved progress."
  (let ((path (merge-pathnames "BOOTSTRAP.md" directory)))
    (when (and (probe-file path) (not (enchiridion.compat:symlink-target path)))
      (let ((text (uiop:read-file-string path :external-format :utf-8)))
        (when (and (= (length text) 1151)
                   (string-equal
                    "fd3ac5bd57cfae5202d3636f72db4dd5aeb7d81f2fc36e77a4e76fb685d8dfcc"
                    (ironclad:byte-array-to-hex-string
                     (ironclad:digest-sequence :sha256
                                               (sb-ext:string-to-octets text :external-format :utf-8)))))
          (write-block-file path +bootstrap+))))))

(defparameter +example-skill+
  ";;;; example-welcome.lsp --- A worked example of a skill.
;;;;
;;;; This file was written by enchiridion init. It is an example, not a
;;;; contribution. Replace it or delete it once you have written your own.
;;;;
;;;; A skill is a plugin that teaches the agent something it would otherwise
;;;; work out again. The trigger line is what the index reads at L0, so it is
;;;; charged on every turn and has to stay short.

(defpackage #:example-welcome
  (:use #:cl)
  (:export #:welcome-line #:welcome-p #:welcome-self-test))

(in-package #:example-welcome)

(defparameter +trigger+ \"welcome, hello, introduce yourself\"
  \"The words that make this skill relevant. The agent reads this line in the
skill index, at L0, to decide whether to load the rest of the file. Keep it
short: it is charged on every turn.\")

(defun welcome-p (text)
  \"Return T when TEXT contains any of this skill's trigger words.\"
  (let ((lower (string-downcase text)))
    (loop for word in '(\"welcome\" \"hello\" \"introduce yourself\")
          thereis (and (search word lower) t))))

(defun welcome-line (arguments)
  \"Return the one line the agent says when this skill fires. A handler is
called with the validated arguments, and this one needs none of them.\"
  (declare (ignore arguments))
  \"Hello. I write my own skills and tools; this one is the example that came
with the harness.\")

(defun welcome-self-test ()
  \"Return T when this skill still recognises a greeting and only a greeting.
A self-test takes no arguments: the loader calls it with none.\"
  (and (welcome-p \"hello\")
       (not (welcome-p \"what time is it\"))
       (stringp (welcome-line (make-hash-table :test #'equal)))))

(enchiridion.plugin:define-plugin example-welcome
  :tool (enchiridion.plugin:tool
         \"welcome-line\"
         \"Return the one line this skill teaches, when greeted.\"
         (:object :properties ((:text :string))))
  :handler #'welcome-line
  :self-test #'welcome-self-test)
"
  "The worked example skill.")

(defparameter +example-tool+
  ";;;; example-echo.lsp --- A worked example of a tool.
;;;;
;;;; This file was written by enchiridion init. It is an example, not a
;;;; contribution. Replace it or delete it once you have written your own.
;;;;
;;;; A plugin is a name, a description, one schema, and a handler. The schema
;;;; drives three things at once: the JSON the model sees, the validation of
;;;; whatever the model sends back, and the registry entry. They cannot
;;;; disagree, because there is only one of them.

(defpackage #:example-echo
  (:use #:cl)
  (:export #:echo-text #:echo-run #:echo-self-test))

(in-package #:example-echo)

(defun echo-text (arguments)
  \"Return the :text field of a validated call.

The registry hands a handler the object the schema validated, which is a hash
table with string keys. This accepts a plist too, so the file can be tried by
hand at a REPL without pretending that is the production shape.\"
  (let ((value (if (hash-table-p arguments)
                   (gethash \"text\" arguments)
                   (getf arguments :text))))
    (if (stringp value) value \"\")))

(defun echo-run (arguments)
  \"Return ARGUMENTS back, with a length, so the model can see that a call
round tripped.\"
  (let ((text (echo-text arguments)))
    (format nil \"echo: ~A ~D characters\" text (length text))))

(defun echo-self-test ()
  \"Return T when this file still does what the description says. The loader
runs every self test in a sandbox before it loads anything for real, and it
calls one with no arguments.\"
  (let ((arguments (make-hash-table :test #'equal)))
    (setf (gethash \"text\" arguments) \"hi\")
    (equal (echo-run arguments) \"echo: hi 2 characters\")))

(enchiridion.plugin:define-plugin echo
  :tool (enchiridion.plugin:tool
         \"echo\"
         \"Return the text it was given, with its length.\"
         (:object :properties ((:text :string))))
  :handler #'echo-run
  :self-test #'echo-self-test)
"
  "The worked example tool.")

(defparameter +initial-state+
  "{
  \"schema\": 1,
  \"generation\": 0,
  \"bootstrap\": {
    \"step\": 0,
    \"done\": [],
    \"complete\": false
  }
}
"
  "The initial runtime state.")

(defparameter *seed-templates*
  '(("GUIDE.md"                   :kind :markdown :contents +guide+        :description "operator walkthrough")
    ("SOUL.md"                    :kind :markdown :contents +soul+         :description "identity")
    ("OPERATOR.md"                :kind :markdown :contents +operator+     :description "who it works for")
    ("WORLD.md"                   :kind :markdown :contents +world+        :description "the environment")
    ("ADAPT.md"                   :kind :markdown :contents +adapt+        :description "bearing and learned preferences")
    ("BOOTSTRAP.md"               :kind :markdown :contents +bootstrap+    :description "first steps")
    ("skills/example-welcome.lsp"  :kind :lisp     :contents +example-skill+ :description "example skill")
    ("tools/example-echo.lsp"      :kind :lisp     :contents +example-tool+ :description "example tool")
    ("state.json"                 :kind :json     :contents +initial-state+ :description "runtime state"))
  "Files written by init: name, kind, template contents, and status description.")

(defparameter *seed-subdirectories* '("skills" "tools")
  "Directories init creates before it writes anything into them.")

(declaim (ftype (function (string) (or null (cons string list))) seed-entry))

(defun seed-entry (name)
  "Return the template row for NAME, or NIL when there is no such template."
  (assoc name *seed-templates* :test #'string=))

(defun seed-file-names ()
  "Return the relative names of every file init writes."
  (mapcar #'first *seed-templates*))

(declaim (ftype (function (list (or string keyword)) t) contents-of))

(defun contents-of (row key)
  "Return the value of KEY in ROW, dereferencing bound non-keyword symbols (e.g. +GUIDE+)."
  (let ((value (getf (cdr row) key)))
    (if (and (symbolp value) (boundp value))
        (symbol-value value)
        value)))

(declaim (ftype (function (string) (or null string)) seed-template))

(defun seed-template (name)
  "Return the contents of seed file NAME, or NIL."
  (let ((row (seed-entry name)))
    (and row (contents-of row :contents))))

(declaim (ftype (function (string) (or null string)) seed-description))

(defun seed-description (name)
  "Return the one line description printed beside NAME."
  (let ((row (seed-entry name)))
    (and row (contents-of row :description))))

(declaim (ftype (function (string) (or null (member :markdown :lisp :json))) seed-kind))

(defun seed-kind (name)
  "Return :MARKDOWN, :LISP, or :JSON for NAME, or NIL."
  (let ((row (seed-entry name)))
    (and row (getf (cdr row) :kind))))

;;;; Writing.

(defun write-if-absent (path contents)
  "Write CONTENTS to PATH only if absent. Return :CREATED, :KEPT, or (values :FAILED condition)."
  (cond
    ((probe-file path) (values :kept nil))
    (t
     (handler-case
         (progn
           (ensure-directories-exist path)
           (with-open-file (stream path
                                   :direction :output
                                   :external-format :utf-8
                                   :if-exists :error
                                   :if-does-not-exist :create)
             (write-string contents stream))
           (values :created nil))
       (error (condition) (values :failed condition))))))

;; Result of init-agent: created/existing file lists, (name . condition) problems, and existed-p.
(defstruct (init-result (:constructor %make-init-result))
  (:directory "" :type string)
  (:created '() :type list)
  (:existing '() :type list)
  (:problems '() :type list)
  (:existed-p nil :type boolean))

(defun init-problems (result)
  "Return the alist of (name . condition) for seed files that failed to write."
  (init-result-problems result))

(declaim (ftype function init-created init-existing init-status-line))

(defun init-created (result)
  "Return the relative names RESULT wrote."
  (init-result-created result))

(defun init-existing (result)
  "Return the relative names RESULT found already present."
  (init-result-existing result))

(defun init-status-line (result)
  "Return the one line the first launch prints about RESULT."
  (if (init-result-existed-p result)
      (format nil "Agent directory ~A already has ~D of ~D seed files."
              (init-result-directory result)
              (length (init-result-existing result))
              (length *seed-templates*))
      (format nil "No agent directory found. Creating ~A."
              (init-result-directory result))))

(defun agent-seeded-p (directory)
  "Return T when DIRECTORY contains at least one seed file."
  (not (null (some (lambda (name) (probe-file (merge-pathnames name directory)))
                   (seed-file-names)))))

(declaim (ftype (function (t) t) ensure-agent-repository))

(defun ensure-agent-repository (directory)
  "Initialize a nested git repository in DIRECTORY if needed and commit existing files.
Return the commit hash or NIL."
  (handler-case
      (if (enchiridion.git:repository-p directory)
          (enchiridion.git:git-commit-all directory "Record the agent directory")
          (progn
            (enchiridion.git:git-init directory)
            (enchiridion.git:git-commit-all directory "Create the agent directory")))
    (error () nil)))

(defun init-agent (directory)
  "Create DIRECTORY and write missing seed files without overwriting.
Initializes the nested git repository on success and returns an INIT-RESULT."
  (handler-case
      (progn
        (ensure-directories-exist (merge-pathnames "x" directory))
        (dolist (sub (copy-list *seed-subdirectories*))
          (ensure-directories-exist (merge-pathnames (format nil "~A/x" sub) directory)))
        (let ((populated (agent-seeded-p directory)))
          (let ((created '()) (existing '()) (problems '()))
            (dolist (entry *seed-templates*)
              (let* ((name (car entry))
                     (contents (contents-of entry :contents))
                     (path (merge-pathnames name directory)))
                (multiple-value-bind (outcome condition) (write-if-absent path contents)
                  (case outcome
                    (:created (push name created))
                    (:kept (push name existing))
                    (otherwise (push (cons name condition) problems))))))
            (unless problems
              (ensure-agent-repository directory))
            (%make-init-result :directory (namestring directory)
                                :created (nreverse created)
                                :existing (nreverse existing)
                                :problems (nreverse problems)
                                :existed-p populated))))
    (file-error (condition)
      (%make-init-result :directory (namestring directory)
                          :created '()
                          :existing '()
                          :problems (list (cons :directory condition))
                          :existed-p nil))))
