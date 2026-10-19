;;;; cli-test.cl --- The shared command table and the REPL.
;;;;
;;;; The command table is data, so most of these tests read it rather than run
;;;; it: the plan fixes the names and the argument ranges, and a row that
;;;; drifts is caught here. The rest prove the two behaviours a caller depends
;;;; on: arity is checked before dispatch, and a command that needs a
;;;; supervisor says so and returns 1 instead of signalling.

(defpackage #:enchiridion-cli-test
  (:use #:cl)
  (:import-from #:rove #:deftest #:ok #:ng #:testing)
  (:export #:run))

(in-package #:enchiridion-cli-test)

(defparameter +plan-commands+
  '("init" "ask" "check" "skills" "tools" "blocks" "persona" "operator" "world"
    "memory" "sessions" "journey" "undo" "usage" "budget" "tasks" "secrets"
    "providers" "version" "help" "bootstrap" "health" "reload" "channels"
    "heartbeat" "chat" "serve")
  "PLAN.md section 10's commands in table order. BOOTSTRAP arrived with the
integration step, after CHANNEL-WORK wrote the other twenty-five.")

(defmacro with-empty-context (&body body)
  "Run BODY with a fresh command context that holds nothing live."
  `(let ((enchiridion.channel.cli:*command-context*
           (enchiridion.channel.cli:make-command-context)))
     ,@body))

(defmacro with-scratch-directory ((name &key (prefix "enchiridion-cli-test-"))
                                  &body body)
  "Bind NAME to a fresh temporary directory, run BODY, then remove it.

Scratch lives under *DEFAULT-PATHNAME-DEFAULTS* rather than under TMPDIR, for
the reason seed-test.cl gives: the nix build directory is writable and TMPDIR
is not."
  `(let ((,name (uiop:ensure-directory-pathname
                  (merge-pathnames
                   (format nil "~A~D" ,prefix (random most-positive-fixnum))
                   (uiop:ensure-directory-pathname *default-pathname-defaults*)))))
     (unwind-protect
          (progn ,@body)
       (uiop:delete-directory-tree ,name
                                   :validate t
                                   :if-does-not-exist :ignore))))

(declaim (ftype (function (string) (or null list)) command-row))

(defun command-row (name)
  "Return NAME's row in the shared table, or NIL."
  (find name (enchiridion.channel.cli:command-table)
        :key #'first :test #'string=))

(declaim (ftype (function (string list) (values string integer)) captured-run))

(defun captured-run (name arguments)
  "Run NAME through RUN-COMMAND and return its output and its exit status."
  (let ((status nil))
    (values (with-output-to-string (*standard-output*)
              (setf status (enchiridion.channel.cli:run-command name arguments)))
            status)))

(declaim (ftype (function (string &optional t) (values string t)) captured-repl))

(defun captured-repl (lines &optional context)
  "Run LINES through the REPL and return its output and its result.

CONTEXT defaults to a fresh one that holds nothing live. The REPL binds
*STANDARD-OUTPUT* to the capture stream, so a command that prints is read back
here the way the operator would see it."
  (let ((result nil)
        (context (or context (enchiridion.channel.cli:make-command-context))))
    (values (with-output-to-string (stream)
              (setf result (enchiridion.channel.cli:run-repl
                            :context context
                            :input (make-string-input-stream lines)
                            :output stream)))
            result)))

;;;; The table.

(deftest the-command-set-is-the-plan-set ()
  (ok (equal +plan-commands+ (enchiridion.channel.cli:command-names))))

(deftest every-row-has-the-plan-shape ()
  (dolist (row (enchiridion.channel.cli:command-table))
    (testing (first row)
      (ok (stringp (first row)))
      (ok (integerp (second row)))
      (ok (or (null (third row)) (integerp (third row))))
      (ok (functionp (fourth row)))
      (ok (stringp (fifth row))))))

(deftest the-plan-argument-ranges-are-in-the-table ()
  (dolist (expected '(("ask" 1 nil) ("memory" 1 nil) ("skills" 0 2)
                      ("undo" 1 1) ("reload" 0 0) ("help" 0 1)
                      ("journey" 0 2) ("tasks" 0 nil) ("channels" 0 2)
                      ("heartbeat" 0 1) ("init" 0 1) ("check" 0 0)))
    (destructuring-bind (name minimum maximum) expected
      (let ((row (command-row name)))
        (testing name
          (ok row)
          (ok (eql minimum (second row)))
          (ok (eql maximum (third row))))))))

;;;; Arity.

(deftest run-command-checks-arity-before-dispatch ()
  (with-empty-context
    (testing "too few arguments"
      (multiple-value-bind (text status) (captured-run "undo" '())
        (ok (eql 2 status))
        (ok (search "exactly 1 argument" text))))
    (testing "too many arguments"
      (multiple-value-bind (text status) (captured-run "skills" '("a" "b" "c"))
        (ok (eql 2 status))
        (ok (search "0 to 2" text))))
    (testing "a name that is not a command"
      (multiple-value-bind (text status) (captured-run "not-a-command" '())
        (ok (eql 2 status))
        (ok (search "no command called" text))))))

(deftest a-nil-maximum-means-no-upper-bound ()
  (with-empty-context
    (let ((row (command-row "ask")))
      (testing "the row says so"
        (ok row)
        (ok (null (third row))))
      (testing "and two words reach the handler instead of failing arity"
        (multiple-value-bind (text status) (captured-run "ask" '("two" "words"))
          (ok (eql 1 status))
          (ng (eql 2 status))
          (ok (search "needs a live agent" text)))))))

(deftest run-command-reaches-the-handler ()
  (with-scratch-directory (directory)
    (let ((enchiridion.channel.cli:*command-context*
            (enchiridion.channel.cli:make-command-context
             :directory (namestring directory))))
      (multiple-value-bind (text status) (captured-run "init" '())
        (declare (ignore text))
        (testing "init ran and wrote a seed file"
          (ok (eql 0 status))
          (ok (probe-file (merge-pathnames "SOUL.md" directory))))))))

;;;; Help.

(deftest help-knows-a-command-and-refuses-an-unknown-one ()
  (testing "a known command prints its detail"
    (let ((status nil))
      (let ((text (with-output-to-string (*standard-output*)
                    (setf status (enchiridion.channel.cli:command-help "skills")))))
        (ok (eql 0 status))
        (ok (search "skills" text))
        (ok (search "arguments" text)))))
  (testing "an unknown command is refused with 2"
    (let ((status nil))
      (let ((text (with-output-to-string (*standard-output*)
                    (setf status (enchiridion.channel.cli:command-help "not-a-command")))))
        (ok (eql 2 status))
        (ok (search "no command called" text)))))
  (testing "no name lists every command"
    (let ((status nil))
      (let ((text (with-output-to-string (*standard-output*)
                    (setf status (enchiridion.channel.cli:command-help)))))
        (ok (eql 0 status))
        (dolist (name (enchiridion.channel.cli:command-names))
          (ok (search name text)))))))

(deftest shell-help-keeps-the-bare-names ()
  ;; The shell calls the program by name, so a slash form here would tell the
  ;; operator to type something the shell does not accept.
  (let ((status nil))
    (let ((text (with-output-to-string (*standard-output*)
                  (setf status (enchiridion.channel.cli:command-help)))))
      (ok (eql 0 status))
      (testing "every table command is listed"
        (dolist (name (enchiridion.channel.cli:command-names))
          (ok (search name text))))
      (testing "and none of them carries a slash"
        (ng (search "/" text))))))

(deftest shell-help-still-resolves-a-listed-command ()
  ;; CHAT and SERVE are shell-only for the REPL and ordinary rows for the
  ;; shell, so `enchiridion help chat` has to keep working.
  (dolist (name '("chat" "serve"))
    (testing name
      (let ((status nil))
        (let ((text (with-output-to-string (*standard-output*)
                      (setf status (enchiridion.channel.cli:command-help name)))))
          (ok (eql 0 status))
          (ok (search (format nil "~A -- " name) text)))))))

;;;; The REPL surface.

(deftest repl-only-commands-stay-out-of-the-table ()
  (ok (equal '("stop" "quit" "who") (enchiridion.channel.cli:repl-only-commands)))
  (dolist (name (enchiridion.channel.cli:repl-only-commands))
    (testing name
      (ok (null (find name (enchiridion.channel.cli:command-names) :test #'string=))))))

(deftest the-repl-quits-on-slash-quit ()
  (with-empty-context
    (let* ((input (make-string-input-stream (format nil "/quit~%")))
           (output (make-string-output-stream)))
      (ok (eq :quit (enchiridion.channel.cli:run-repl :input input :output output)))
      (ok (search "enchiridion>" (get-output-stream-string output))))))

(deftest the-repl-says-when-no-agent-can-answer ()
  (with-empty-context
    (let* ((input (make-string-input-stream (format nil "hello~%")))
           (output (make-string-output-stream)))
      (ok (eq :eof (enchiridion.channel.cli:run-repl :input input :output output)))
      (ok (search "no live agent" (get-output-stream-string output))))))

(deftest a-plain-repl-line-calls-the-respond-function ()
  (let* ((seen '())
         (context (enchiridion.channel.cli:make-command-context
                   :respond (lambda (text) (push text seen) 0)))
         (input (make-string-input-stream (format nil "hello there~%")))
         (output (make-string-output-stream)))
    (enchiridion.channel.cli:run-repl :context context :input input :output output)
    (ok (equal '("hello there") seen))))

(deftest slash-stop-calls-the-cancel-function ()
  (let* ((called nil)
         (context (enchiridion.channel.cli:make-command-context
                   :cancel (lambda () (setf called t))))
         (input (make-string-input-stream (format nil "/stop~%/quit~%")))
         (output (make-string-output-stream)))
    (enchiridion.channel.cli:run-repl :context context :input input :output output)
    (ok called)))

(deftest the-repl-who-reports-the-surface ()
  (with-empty-context
    (let* ((input (make-string-input-stream (format nil "/who~%/quit~%")))
           (output (make-string-output-stream)))
      (ok (eq :quit (enchiridion.channel.cli:run-repl :input input :output output)))
      (ok (search "no channel is attached" (get-output-stream-string output))))))

(deftest the-repl-survives-an-interrupt-during-a-turn ()
  ;; Ctrl-C used to be unhandled. --script runs with the debugger disabled, so
  ;; the condition printed a backtrace and exited 1 instead of reaching the
  ;; prompt. The interrupt has to leave the turn, say so, and ask again; the
  ;; /quit that follows proves the loop kept reading.
  #+sbcl
  (let* ((turns 0)
         (context (enchiridion.channel.cli:make-command-context
                   :respond (lambda (text)
                              (declare (ignore text))
                              (incf turns)
                              (enchiridion.compat:signal-interactive-interrupt)
                              1))))
    (multiple-value-bind (text result)
        (captured-repl (format nil "hello~%/quit~%") context)
      (ok (eq :quit result))
      (ok (= 1 turns) "the turn ran once and was abandoned")
      (ok (search "interrupted." text))))
  #-sbcl
  (ok t "this implementation has no interrupt condition"))

(deftest an-interrupt-does-not-cancel-the-next-turn ()
  ;; The cancel function sets a flag that stays set, so an interrupt must not
  ;; reach for it: a turn after the interrupt still has to run.
  #+sbcl
  (let* ((turns 0)
         (cancelled nil)
         (context (enchiridion.channel.cli:make-command-context
                   :cancel (lambda () (setf cancelled t))
                   :respond (lambda (text)
                              (declare (ignore text))
                              (incf turns)
                              (when (= turns 1)
                                (enchiridion.compat:signal-interactive-interrupt))
                              0))))
    (multiple-value-bind (text result)
        (captured-repl (format nil "first~%second~%/quit~%") context)
      (ok (eq :quit result))
      (ok (= 2 turns) "both turns reached the respond function")
      (ok (null cancelled) "the interrupt did not set the cancel flag")
      (ok (search "interrupted." text))))
  #-sbcl
  (ok t "this implementation has no interrupt condition"))

(deftest a-shutdown-interrupt-leaves-the-repl ()
  ;; SIGTERM must stop the process, not just the line. The REPL handler
  ;; declines the shutdown condition, so it reaches the outer handler; here the
  ;; test stands in for the entry point and checks that the loop never got to
  ;; answer the turn itself.
  #+sbcl
  (let ((context (enchiridion.channel.cli:make-command-context
                  :respond (lambda (text)
                             (declare (ignore text))
                             (enchiridion.compat:signal-shutdown-interrupt)
                             0))))
    (ok (eq :stopped
            (catch 'outer-interrupt
              (enchiridion.compat:with-interrupt-handler
                  ((lambda (condition)
                     (declare (ignore condition))
                     (throw 'outer-interrupt :stopped)))
                (enchiridion.channel.cli:run-repl
                 :context context
                 :input (make-string-input-stream (format nil "hello~%/quit~%"))
                 :output (make-string-output-stream)))))
        "the outer handler answered it, so the REPL did not swallow the stop"))
  #-sbcl
  (ok t "this implementation has no shutdown interrupt"))

(deftest repl-help-lists-the-slash-form-and-the-repl-only-commands ()
  ;; The bug this guards: `help` printed bare names, so the operator typed the
  ;; one form the REPL does not read and spent a turn on it.
  (multiple-value-bind (text result) (captured-repl (format nil "/help~%/quit~%"))
    (ok (eq :quit result))
    (testing "every command is labelled the way the operator types it"
      (dolist (name '("/help" "/quit" "/stop" "/who"))
        (ok (search name text))))
    (testing "a command the REPL cannot run stays off the list"
      (ng (search "/chat" text))
      (ng (search "/serve" text)))))

(deftest repl-help-detail-labels-the-command-and-takes-the-slash-form ()
  (testing "the bare name resolves"
    (multiple-value-bind (text result)
        (captured-repl (format nil "/help skills~%/quit~%"))
      (ok (eq :quit result))
      (ok (search "/skills -- " text))
      (ok (search "arguments:" text))))
  (testing "the slash form resolves to the same row"
    (multiple-value-bind (text result)
        (captured-repl (format nil "/help /skills~%/quit~%"))
      (ok (eq :quit result))
      (ok (search "/skills -- " text)))))

(deftest repl-help-refuses-a-shell-only-command ()
  (with-empty-context
    (dolist (name '("chat" "serve"))
      (testing name
        (let ((status nil))
          (let ((text (with-output-to-string (*standard-output*)
                        (setf status (enchiridion.channel.cli:repl-evaluate
                                      (format nil "/help ~A" name))))))
            (ok (eql 2 status))
            (ok (search "shell-only" text))))))))

(deftest a-bare-repl-command-word-hints-at-the-slash ()
  (let* ((turns '())
         (context (enchiridion.channel.cli:make-command-context
                   :respond (lambda (text) (push text turns) 0))))
    (multiple-value-bind (text result)
        (captured-repl (format nil "help~%/quit~%") context)
      (ok (eq :quit result))
      (ok (search "Commands start with a slash" text))
      (ok (search "try `/help`" text)))
    (testing "the hint is not a turn, so the respond function is not called"
      (ok (null turns)))))

(deftest multi-word-and-unknown-repl-lines-stay-turns ()
  (testing "two words are a turn even when the first names a command"
    (let* ((turns '())
           (context (enchiridion.channel.cli:make-command-context
                     :respond (lambda (text) (push text turns) 0))))
      (captured-repl (format nil "help me~%") context)
      (ok (equal '("help me") turns))))
  (testing "a lone word that names nothing is a turn"
    (let* ((turns '())
           (context (enchiridion.channel.cli:make-command-context
                     :respond (lambda (text) (push text turns) 0))))
      (captured-repl (format nil "nonesuch~%") context)
      (ok (equal '("nonesuch") turns))))
  (testing "a shell-only word is a turn, because the REPL cannot run it"
    (let* ((turns '())
           (context (enchiridion.channel.cli:make-command-context
                     :respond (lambda (text) (push text turns) 0))))
      (captured-repl (format nil "chat~%") context)
      (ok (equal '("chat") turns)))))

(deftest repl-messages-name-the-command-with-a-slash ()
  (with-empty-context
    (testing "the arity line labels the command"
      (let ((status nil))
        (let ((text (with-output-to-string (*standard-output*)
                      (setf status (enchiridion.channel.cli:repl-evaluate "/undo")))))
          (ok (eql 2 status))
          (ok (search "/undo takes" text)))))
    (testing "an unknown name points at the slash form of help"
      (let ((status nil))
        (let ((text (with-output-to-string (*standard-output*)
                      (setf status (enchiridion.channel.cli:repl-evaluate "/nonesuch")))))
          (ok (eql 2 status))
          (ok (search "Try `/help`" text)))))
    (testing "the store line labels the command"
      (let ((status nil))
        (let ((text (with-output-to-string (*standard-output*)
                      (setf status (enchiridion.channel.cli:repl-evaluate "/memory q")))))
          (ok (eql 1 status))
          (ok (search "/memory needs the memory store" text)))))
    (testing "the agent line labels the command and names the shell-only start"
      (let ((status nil))
        (let ((text (with-output-to-string (*standard-output*)
                      (setf status (enchiridion.channel.cli:repl-evaluate "/ask hi")))))
          (ok (eql 1 status))
          (ok (search "/ask needs a live agent" text))
          ;; CHAT is shell-only, so it is named as a shell invocation and not
          ;; as `/chat`: the slash form would send the operator to a REPL
          ;; command the REPL does not list.
          (ok (search "`enchiridion chat`" text))
          (ng (search "`/chat`" text)))))
    (testing "the supervisor line labels the command"
      (let ((status nil))
        (let ((text (with-output-to-string (*standard-output*)
                      (setf status (enchiridion.channel.cli:repl-evaluate "/reload")))))
          (ok (eql 1 status))
          (ok (search "/reload: no supervisor" text)))))))

;;;; The supervisor commands.

(deftest reload-channels-and-heartbeat-refuse-without-a-supervisor ()
  (with-empty-context
    (dolist (name '("reload" "channels" "heartbeat"))
      (testing name
        (multiple-value-bind (text status) (captured-run name '())
          (ok (eql 1 status))
          (ok (search "no supervisor is running" text)))))))

(deftest health-refuses-without-a-supervisor ()
  (with-empty-context
    (multiple-value-bind (text status) (captured-run "health" '())
      (ok (eql 1 status))
      (ok (search "no supervisor is running" text)))))

(deftest commands-that-need-a-store-say-so ()
  (with-empty-context
    (dolist (name '("memory" "sessions" "usage" "tasks"))
      (testing name
        (let ((arguments (if (string= name "memory") '("a query") '())))
          (multiple-value-bind (text status) (captured-run name arguments)
            (ok (eql 1 status))
            (ok (search "memory store" text))))))))

;;;; The budget.

(deftest budget-reads-the-budget-section ()
  (let ((enchiridion.channel.cli:*command-context*
          (enchiridion.channel.cli:make-command-context
           :config '(:llm (:backend :openai)
                     :budget (:max-tokens-per-tick 1234) (:max-tokens-per-day 5678)))))
    (multiple-value-bind (text status) (captured-run "budget" '())
      (ok (eql 0 status))
      (testing "a configured cap is printed"
        (ok (search "1234" text))
        (ok (search "5678" text)))
      (testing "and it is not reported as none"
        (ng (search "none" text))))))

;;;; The ledger report.

(deftest the-usage-report-names-the-cache-columns ()
  ;; The definition of done asks for cache read and cache write by name, and
  ;; the grouping is what turns rows into an answer.
  (with-scratch-directory (directory)
    (let ((store (enchiridion.memory.store:open-store
                  :path (merge-pathnames "memory.db" directory))))
      (unwind-protect
           (progn
             (enchiridion.memory.store:record-usage store :model "one"
                                                          :channel :http
                                                          :input 10 :output 2
                                                          :cache-read 3 :cache-write 4)
             (enchiridion.memory.store:record-usage store :model "two"
                                                          :channel :cli
                                                          :input 20 :output 5
                                                          :cache-read 6 :cache-write 7)
             (let ((enchiridion.channel.cli:*command-context*
                     (enchiridion.channel.cli:make-command-context :store store)))
               (multiple-value-bind (text status) (captured-run "usage" '())
                 (ok (eql 0 status))
                 (testing "the header names all four numbers"
                   (ok (search "cache read" text))
                   (ok (search "cache write" text))
                   (ok (search "input" text)))
                 (testing "every grouping is printed"
                   (ok (search "by model" text))
                   (ok (search "by channel" text))
                   (ok (search "by day" text)))
                 (testing "and the sums are the sums"
                   (ok (search "30" text))
                   (ok (search "9" text))))))
        (ignore-errors (enchiridion.memory.store:close-store store))))))

(deftest tasks-can-be-listed-by-status ()
  (with-scratch-directory (directory)
    (let ((store (enchiridion.memory.store:open-store
                  :path (merge-pathnames "memory.db" directory))))
      (unwind-protect
           (progn
             (enchiridion.memory.store:enqueue-task store "still waiting")
             (enchiridion.memory.store:enqueue-task store "being worked on")
             (enchiridion.memory.store:dequeue-task store)
             (let ((enchiridion.channel.cli:*command-context*
                     (enchiridion.channel.cli:make-command-context :store store)))
               ;; DEQUEUE-TASK claims the oldest pending task, which is the
               ;; first one queued, so the one still waiting is the second.
               (multiple-value-bind (text status) (captured-run "tasks" '("list" "pending"))
                 (ok (eql 0 status))
                 (ok (search "being worked on" text))
                 (ng (search "still waiting" text)))
               (multiple-value-bind (text status) (captured-run "tasks" '("list" "running"))
                 (ok (eql 0 status))
                 (ok (search "still waiting" text)))
               (testing "a status nobody has heard of is refused with the four"
                 (multiple-value-bind (text status) (captured-run "tasks" '("list" "nope"))
                   (ok (eql 2 status))
                   (ok (search "pending, running, done or failed" text))))))
        (ignore-errors (enchiridion.memory.store:close-store store))))))
