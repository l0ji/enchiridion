;;;; seed.cl --- The operator seed files and the first run.
;;;;
;;;; An agent directory is created from these templates the first time
;;;; enchiridion runs with no agent directory present, and the run then stops.
;;;; Nothing starts until the operator has had a chance to edit.
;;;;
;;;; The rule that outranks everything else in this file: a seed file is
;;;; created when absent and never overwritten. Rerunning init against a
;;;; populated directory reports what exists and writes only the gaps, so a
;;;; half finished setup completes without throwing work away.

;; The package is declared in packages.cl. One defpackage per subsystem, in one
;; file, is the rule; a second declaration somewhere else is how an export list
;; ends up in two places and one of them is stale.

(in-package #:enchiridion.memory)

;;;; The templates.
;;;;
;;;; They are Lisp string constants rather than separate files in the source
;;;; tree. One file to keep in sync, and init becomes a single call with no
;;;; file lookup and no path that can be wrong.

(defparameter +guide+
  "# Guide

This directory belongs to one agent. The Markdown files in it are the agent's
memory, and they are in git, so its development is a diff you can read.

## The five files

| File | Who writes it | What it holds |
| --- | --- | --- |
| `SOUL.md` | you, then the agent | identity, voice, values |
| `OPERATOR.md` | you, then the agent | who it works for, what you prefer |
| `WORLD.md` | you, then the agent | the environment: paths, conventions, lessons |
| `BOOTSTRAP.md` | you | the first steps, worked through once |
| `GUIDE.md` | you | this file |

Before bootstrap hands over, the agent cannot edit the first three. After it,
the sleep-time agent owns all three. That is deliberate: you get a guided
start, and then an agent with a personality of its own.

## Do this first

1. Rewrite `SOUL.md`. The current text is a placeholder. Say who the agent
   is, how it talks, and what it will not do.
2. Rewrite `OPERATOR.md`. Who you are, how you like answers, when you want
   to be interrupted and when you do not.
3. Rewrite `WORLD.md`. The real paths on this machine, the real commands,
   the real conventions. This is the file that stops it guessing.
4. Then run `enchiridion chat`.

The agent reads these three on its first turn, asks you the questions they
do not answer, and writes the answers back. Only then does it create its own
first skill.

## Commands worth knowing

| Command | What it does |
| --- | --- |
| `enchiridion chat` | start the REPL |
| `enchiridion ask \"...\"` | one turn, print, exit |
| `enchiridion serve` | run the supervisor with the channels you enabled |
| `enchiridion blocks` | the memory blocks with character counts |
| `enchiridion skills` | every skill, with its tier and trigger line |
| `enchiridion tools` | every tool, with its schema token cost |
| `enchiridion journey` | everything the agent has learned or written |
| `enchiridion memory \"...\"` | full text search across sessions and memories |
| `enchiridion usage` | the token ledger, with cache columns |
| `enchiridion undo N` | roll back the Nth change in this directory |

Every command is also available in the REPL with a leading slash. Only
`/stop` and `/who` are REPL only, because they act on a turn that is running
right now.

## What the agent cannot see

Your keys are not reachable from anything the agent runs. The supervisor
reads `.env` from a tmpfs at startup, holds the values in memory, unsets them
from its own environment, and deletes the file. The agent's own code runs in
a separate process under a different user, with no view of the supervisor's
environment. That is a property of the deployment, not a setting you can turn
off.

## Reverting

This directory is its own git repository, nested inside the enchiridion
checkout. Every change the agent makes here is a commit signed with your key,
so its history is separate from the source tree's history and you can read it
without reading the harness.

    git -C agents/default log
    git -C agents/default diff
    git -C agents/default show HEAD
    enchiridion undo 3

Personality evolution is a diff, not a mystery. Read it if you want to.
"
  "The operator walkthrough.")

(defparameter +soul+
  "# Soul

This file is a placeholder. Replace it before the agent's first run.

## Who it is

Name it. A short paragraph is enough. An agent with no name in its own
identity drifts into the most generic possible assistant, because that is what
the median of the training data sounds like.

## How it talks

Short or long. Does it use headers. Does it say when it is unsure, or does it
guess. Does it show its working, or does it answer.

Be concrete here. \"Be concise\" means nothing. \"Under six lines unless asked
for more\" is a rule it can follow.

## What it will not do

The list that matters most. Things it should refuse even when a message asks
politely. If it will not send mail without asking, write that down, because
nothing else in the system will stop it.

## What it is trying to get better at

Two or three things. This is what the sleep-time agent rewrites when it has
a turn and nothing else.
"
  "Identity, voice, and values.")

(defparameter +operator+
  "# Operator

This file is a placeholder. Replace it before the agent's first run.

## Who you are

What you work on, what you are building, what you already know. An agent that
knows your domain stops explaining it back to you.

## What you want from it

The shape of a good answer. Detail level, tone, how much to ask before acting,
how much to just do.

## When it may act without asking

This is the important one. Reading files: fine. Writing files under this
directory: fine. Anything that reaches the network, anything that costs
money, anything that touches something outside this directory: ask first.

## When it may interrupt you

And when it should queue its question and keep working. Both directions are
worth writing down, because the default is always the same and the default is
usually wrong.

## Standing constraints

Deadlines, budgets, the things it must not spend time on.
"
  "Who it works for.")

(defparameter +world+
  "# World

This file is a placeholder. Replace it before the agent's first run.

This is the file that stops it guessing. Every fact here is one it would
otherwise have to spend a turn discovering.

## Where things are

Real absolute paths. The source tree, the agent directory, the database, the
control file. Not placeholders.

## How things are run

The commands that actually work on this machine. The container flags. The port
numbers. The name of the environment variable that holds the key, never the
key.

## Conventions

Indentation, naming, where tests live, what a commit message looks like here.
The shape of the work it will be doing.

## What has already been learned

Lessons that cost a turn to discover. The sleep-time agent appends here. Keep
entries short and dated, and delete the ones that have stopped being true.
"
  "The environment it lives in.")

(defparameter +bootstrap+
  "# Bootstrap

The first steps. Work through them in order, one turn each, and mark each one
done in `state.json` as you finish it.

1. Read `SOUL.md`, `OPERATOR.md`, and `WORLD.md`.
2. List, in one message, every question those three files do not answer.
3. Wait for the answers. Do not guess at a fact you were not given.
4. Write the answers into the three files.
5. Create one first skill under `skills/`, and use it once in this same
   session.
6. Write one memory, and read it back with the memory tool.
7. Mark each step above done in `state.json`.
8. When every step is done, archive this file to `BOOTSTRAP.done.md` and tell
   the operator the handover is complete.

Until the last step, writes to `SOUL.md`, `OPERATOR.md`, and `WORLD.md` are
refused. That is not a bug. The operator's guidance cannot be edited away in
the first minutes of your life.

After handover this file is read-only history and the sleep-time agent owns
all three of the others.
"
  "The first steps.")

(defparameter +example-skill+
  ";;;; example-welcome.cl --- A worked example of a skill.
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

(defun welcome-line ()
  \"Return the one line the agent says when this skill fires.\"
  \"Hello. I write my own skills and tools; this one is the example that came
with the harness.\")

(defun welcome-self-test ()
  \"Return T when this skill still recognises a greeting and only a greeting.
A self-test takes no arguments: the loader calls it with none.\"
  (and (welcome-p \"hello\")
       (not (welcome-p \"what time is it\"))))

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
  ";;;; example-echo.cl --- A worked example of a tool.
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
    ("BOOTSTRAP.md"               :kind :markdown :contents +bootstrap+    :description "first steps")
    ("skills/example-welcome.cl"  :kind :lisp     :contents +example-skill+ :description "example skill")
    ("tools/example-echo.cl"      :kind :lisp     :contents +example-tool+ :description "example tool")
    ("state.json"                 :kind :json     :contents +initial-state+ :description "runtime state"))
  "Every file init writes: its name, what kind of file it is, its contents,
and the one line the first launch prints beside it. In that order, so the
listing reads top to bottom.")

(defparameter *seed-subdirectories* '("skills" "tools")
  "Directories init creates before it writes anything into them.")

;; string, not (seed-entry (name)): a type specifier cannot be a function call.
(declaim (ftype (function (string) (or null (cons string list))) seed-entry))

(defun seed-entry (name)
  "Return the template row for NAME, or NIL when there is no such template."
  (assoc name *seed-templates* :test #'string=))

(defun seed-file-names ()
  "Return the relative names of every file init writes."
  (mapcar #'first *seed-templates*))

(declaim (ftype (function (list (or string keyword)) t) contents-of))

(defun contents-of (row key)
  "Return the value of KEY in ROW, dereferencing it when it is a symbol that
names a variable.

The template table is quoted so that its rows are data, which means +GUIDE+
arrives here as the symbol and not as the text. Writing the symbol would put
ENCHIRIDION.MEMORY::+GUIDE+ into the operator's SOUL.md.

boundp, not symbolp: :kind holds the keyword :MARKDOWN, and a keyword is a
symbol that names no variable. Dereferencing it asks for the value of a
variable that does not exist, so the one row that is not text was the row that
could not be read."
  (let ((value (getf (cdr row) key)))
    (if (and (symbolp value) (boundp value))
        (symbol-value value)
        value)))

(declaim (ftype (function (string) (or null string)) seed-template))

(defun seed-template (name)
  "Return the contents of the seed file NAME, or NIL when there is no such
template."
  (let ((row (seed-entry name)))
    (and row (contents-of row :contents))))

(declaim (ftype (function (string) (or null string)) seed-description))

(defun seed-description (name)
  "Return the one line description printed beside NAME."
  (let ((row (seed-entry name)))
    (and row (contents-of row :description))))

(declaim (ftype (function (string) (or null (member :markdown :lisp :json))) seed-kind))

(defun seed-kind (name)
  "Return :MARKDOWN, :LISP, or :JSON for NAME, according to which template it
is."
  (let ((row (seed-entry name)))
    (and row (getf (cdr row) :kind))))

;;;; Writing.

(defun write-if-absent (path contents)
  "Write CONTENTS to PATH when nothing is there yet. Return :created, :kept, or
:failed, with the condition as the second value when it failed. Never
overwrites. That single refusal is what lets a rerun of init complete a half
finished setup instead of discarding it.

The condition comes back rather than being logged and dropped: a failed write
that says only 'could not write' is a failure the operator cannot act on."
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

;; defstruct slots take :type and :read-only, and a defstruct takes no
;; :documentation option at all: a trailing :documentation is read as a slot
;; named DOCUMENTATION. The meaning is carried here instead.
;;
;; created is what this run wrote, existing is what it found already there,
;; problems is an alist of name to condition for what it could not write, and
;; existed-p says whether the directory was already populated.
(defstruct (init-result (:constructor %make-init-result))
  (:directory "" :type string)
  (:created '() :type list)
  (:existing '() :type list)
  (:problems '() :type list)
  (:existed-p nil :type boolean))

(defun init-problems (result)
  "Return the alist of seed file name to the condition that stopped it being
written. A silent failure list is a failure nobody can act on."
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
  "Return T when DIRECTORY holds at least one seed file. SOME returns the
probe-file pathname rather than T, and a pathname in a slot typed boolean is a
type error, so the answer is coerced."
  (not (null (some (lambda (name) (probe-file (merge-pathnames name directory)))
                   (seed-file-names)))))

(defun init-agent (directory)
  "Create DIRECTORY and write every seed file that is not already there. Never
overwrite anything. Return an init-result holding what was written and what
was left alone.

A directory that cannot be made is a result with a problem, not a signal. The
caller prints the problems and exits; the operator gets the path and the OS
error instead of a backtrace from inside ASDF's source registry."
  (handler-case
      (progn
        (ensure-directories-exist (merge-pathnames "x" directory))
        (dolist (sub (copy-list *seed-subdirectories*))
          (ensure-directories-exist (merge-pathnames (format nil "~A/x" sub) directory)))
        (let ((populated (agent-seeded-p directory)))
          (let ((created '()) (existing '()) (problems '()))
            (dolist (entry *seed-templates*)
              ;; The row is a name followed by a plist, so :contents has to be
              ;; looked up rather than destructured: there are more than four
              ;; elements in the row.
              ;; let*, not let: PATH uses NAME, and let binds in parallel.
              (let* ((name (car entry))
                     (contents (contents-of entry :contents))
                     (path (merge-pathnames name directory)))
                (multiple-value-bind (outcome condition) (write-if-absent path contents)
                  (case outcome
                    (:created (push name created))
                    (:kept (push name existing))
                    (otherwise (push (cons name condition) problems))))))
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