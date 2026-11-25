;;;; cli-test.lsp --- The shared command table and the REPL.
;;;;
;;;; The command table is data, so most of these tests read it rather than run
;;;; it: the names and the argument ranges are part of the contract, and a row
;;;; that drifts is caught here. The rest prove the two behaviours a caller
;;;; depends on: arity is checked before dispatch, and a command that needs a
;;;; supervisor says so and returns 1 instead of signalling.

(defpackage #:enchiridion-cli-test
  (:use #:cl)
  (:import-from #:rove #:deftest #:ok #:ng #:testing)
  (:export #:run))

(in-package #:enchiridion-cli-test)

(defparameter +plan-commands+
  '("init" "ask" "check" "skills" "tools" "blocks" "persona" "operator" "world"
    "memory" "sessions" "journey" "undo" "usage" "budget" "tasks"
    "secrets"
    "providers" "version" "help" "bootstrap" "doctor" "health" "reload"
    "channels" "heartbeat" "chat" "serve")
  "The commands in table order.")

(defmacro with-empty-context (&body body)
  "Run BODY with a fresh command context that holds nothing live."
  `(let ((enchiridion.channel.cli:*command-context*
           (enchiridion.channel.cli:make-command-context)))
     ,@body))

(defmacro with-scratch-directory ((name &key (prefix "enchiridion-cli-test-"))
                                  &body body)
  "Bind NAME to a fresh temporary directory, run BODY, then remove it.

Scratch lives under *DEFAULT-PATHNAME-DEFAULTS* rather than under TMPDIR, for
the reason seed-test.lsp gives: the nix build directory is writable and TMPDIR
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

(deftest a-session-search-prints-its-turns ()
  ;; A session search returns turn rows, and printing one as a plist failed.
  (let ((text (with-output-to-string (*standard-output*)
                (enchiridion.channel.cli::print-row
                 (enchiridion.memory.store::%make-turn-row
                  :id 7 :session "s" :role "user" :body "where is the key" :ts 1)))))
    (ok (search "  id: 7" text))
    (ok (search "  body: where is the key" text))))

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
                      ("heartbeat" 0 1) ("init" 0 1) ("check" 0 0)
                      ("doctor" 0 0)))
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

(deftest a-provider-with-a-key-is-listed ()
  ;; Every provider with a loaded key used to fail to print: the key column
  ;; named the variable again and took the source's argument.
  (let ((text (with-output-to-string (*standard-output*)
                (enchiridion.channel.cli::print-provider-list
                 (list (list :id "opencode" :name "OpenCode Go" :supported-p t
                             :api "openai-chat" :profile "openai"
                             :base-url "https://example.invalid/v1" :api-key-env "OPENCODE_API_KEY"
                             :key-present-p t :source :shipped)
                       (list :id "openai" :name "OpenAI" :supported-p t
                             :api "openai-chat" :profile "openai"
                             :base-url "https://api.openai.com/v1/" :api-key-env "OPENAI_API_KEY"
                             :key-present-p nil :source :shipped))))))
    (ok (search "OPENCODE_API_KEY key (shipped)" text))
    (ok (search "OPENAI_API_KEY no key (shipped)" text))))

(deftest the-memory-commands-show-and-steer-t2 ()
  (with-scratch-directory (directory)
    (let ((store (enchiridion.memory.store:open-store
                  :path (merge-pathnames "memory.db" directory))))
      (unwind-protect
           (let ((enchiridion.channel.cli:*command-context*
                   (enchiridion.channel.cli:make-command-context :store store)))
             (testing "preflight reports the counts without building a candidate"
               (let ((enchiridion.memory:*memory-gate-min-n* 100)
                     (enchiridion.memory:*tail-min-n* 50)
                     (enchiridion.memory:*assertion-deriver* nil))
                 (multiple-value-bind (text status) (captured-run "memory" '("preflight"))
                   (ok (zerop status))
                   (ok (search "utility pairs: 0/100" text))
                   (ok (search "tail pairs: 0/50 (0 answers awaiting rarity)" text))
                   (ok (search "assertion deriver: not installed" text)))))
             (testing "an empty store has no generations"
               (ok (search "no generations yet" (captured-run "memory" '("candidates")))))
             (enchiridion.memory.store:exec
              store "INSERT INTO generations (number, status, created_ts, episodes_derived, writes,
                                              tokens_used, promotion_result, quarantine_reason)
                       VALUES (1, 'quarantined', 0, 40, 180, 61000, 'quarantined', 'utility')")
             (enchiridion.memory.store:exec
              store "INSERT INTO generation_checks (generation_id, kind, result, value, detail, ts)
                       VALUES (1, 'utility', 'fail', 0.4, '(:PAIRS 120)', 0)")
             (testing "candidates lists each generation with its verdict"
               (let ((text (captured-run "memory" '("candidates"))))
                 (ok (search "1 quarantined: 40 episodes processed, 0 assertions, 180 writes, 61000 tokens" text))
                 (ok (search "(utility)" text))))
             (testing "gates shows its checks"
               (ok (search "utility fail" (captured-run "memory" '("gates" "1")))))
             (testing "an unknown generation is refused with a pointer"
               (multiple-value-bind (text status) (captured-run "memory" '("gates" "99"))
                 (ok (eql 2 status))
                 (ok (search "memory candidates" text))))
             (testing "promote goes through the gates, so a quarantined one is refused"
               (multiple-value-bind (text status) (captured-run "memory" '("promote" "1"))
                 (ok (eql 1 status))
                 (ok (search "not-a-candidate" text))))
             (testing "canaries reports coverage by family"
               (let ((enchiridion.memory:*memory-canaries*
                       (list (list :name "r" :family "retrieval" :cue "deploy key" :expect "vault"))))
                 (ok (search "1 family covered (retrieval)" (captured-run "memory" '("canaries")))))))
        (ignore-errors (enchiridion.memory.store:close-store store))))))


;;;; Command requirements.

(defparameter +capability-keywords+
  '(:config :directory :git :store :secrets :backend :agent :supervised)
  "The capabilities a command row may name.")

(defparameter +expected-base-requirements+
  '(("init" (:config :directory :git))
    ("ask" (:config :directory :secrets :store :backend :agent))
    ("check" ())
    ("skills" (:directory))
    ("tools" ())
    ("blocks" (:config :directory))
    ("persona" (:directory))
    ("operator" (:directory))
    ("world" (:directory))
    ("memory" (:config :store))
    ("sessions" (:config :store))
    ("journey" (:config :directory :git))
    ("undo" (:config :directory :git))
    ("usage" (:config :store))
    ("budget" (:config))
    ("tasks" (:config :store))
    ("secrets" (:config :secrets))
    ("providers" (:config))
    ("version" ())
    ("help" ())
    ("bootstrap" (:directory))
    ("doctor" ())
    ("health" ())
    ("reload" ())
    ("channels" ())
    ("heartbeat" ())
    ("chat" (:config :directory :secrets :store :backend :agent :supervised))
    ("serve" (:config :directory :secrets :store :backend :agent :supervised)))
  "The default capability set every command row promises.")

(deftest every-row-carries-requirement-metadata ()
  (dolist (row (enchiridion.channel.cli:command-table))
    (testing (first row)
      (let ((spec (sixth row)))
        (ok (listp spec))
        (ok (listp (getf spec :default)))
        (dolist (capability (getf spec :default))
          (ok (member capability +capability-keywords+)))
        (dolist (entry (getf spec :actions))
          (ok (consp entry))
          (ok (stringp (car entry)))
          (ok (listp (cdr entry)))
          (dolist (capability (cdr entry))
            (ok (member capability +capability-keywords+))))))))

(deftest each-command-states-its-base-requirements ()
  (dolist (expected +expected-base-requirements+)
    (destructuring-bind (name requirements) expected
      (multiple-value-bind (actual known-p)
          (enchiridion.channel.cli:command-requirements name)
        (testing name
          (ok known-p)
          (ok (equal requirements actual)))))))

(deftest subcommand-requirements-differ-where-the-work-differs ()
  (flet ((requirements (name arguments)
           (multiple-value-bind (actual known-p)
               (enchiridion.channel.cli:command-requirements name arguments)
             (ok known-p)
             actual)))
    (testing "providers only asks for a key when it asks a provider"
      (ok (equal '(:config) (requirements "providers" '("list"))))
      (ok (equal '(:config) (requirements "providers" '("show" "deepseek"))))
      (ok (equal '(:config) (requirements "providers" '("refresh"))))
      (ok (equal '(:config :secrets)
                 (requirements "providers" '("models" "deepseek"))))
      (ng (member :backend (requirements "providers" '("models" "deepseek")))))
    (testing "blocks reads configured limits only when it shows them"
      (ok (equal '(:config :directory) (requirements "blocks" '())))
      (ok (equal '(:config :directory) (requirements "blocks" '("show"))))
      (ok (equal '(:directory) (requirements "blocks" '("edit" "1")))))
    (testing "memory preflight and derivation need the backend and its directory"
      (ok (equal '(:config :store) (requirements "memory" '("status"))))
      (ok (equal '(:config :store) (requirements "memory" '("search" "x"))))
      (ok (equal '(:config :directory :secrets :store :backend)
                 (requirements "memory" '("preflight"))))
      (ok (equal '(:config :directory :secrets :store :backend)
                 (requirements "memory" '("build"))))
      (ok (equal '(:config :directory :secrets :store :backend)
                 (requirements "memory" '("promote" "1"))))
      (ok (equal '(:config :directory :secrets :store :backend)
                 (requirements "memory" '("regate" "1")))))
    (testing "bootstrap commits only when it records a step"
      (ok (equal '(:directory) (requirements "bootstrap" '("status"))))
      (ok (equal '(:directory) (requirements "bootstrap" '("run"))))
      (ok (equal '(:directory) (requirements "bootstrap" '("reset"))))
      (ok (equal '(:config :directory :git)
                 (requirements "bootstrap" '("step" "1")))))
    (testing "an unknown action falls back to the command default"
      (ok (equal '(:config :store) (requirements "memory" '("nonesuch"))))
      (ok (equal '(:config) (requirements "providers" '("nonesuch")))))
    (testing "action names are case-insensitive"
      (ok (equal '(:directory) (requirements "blocks" '("EDIT" "1")))))
    (testing "an unknown command has no requirements and no known flag"
      (multiple-value-bind (actual known-p)
          (enchiridion.channel.cli:command-requirements "not-a-command")
        (ng known-p)
        (ok (null actual))))))

(deftest command-problem-is-pure-and-run-command-still-prints ()
  (let ((problems nil)
        (output (make-string-output-stream)))
    (let ((*standard-output* output))
      (setf problems
            (list (enchiridion.channel.cli:command-problem
                   "not-a-command" '())
                  (enchiridion.channel.cli:command-problem "undo" '())
                  (enchiridion.channel.cli:command-problem "undo" '("1"))
                  (enchiridion.channel.cli:command-problem
                   "providers" '("nonesuch")))))
    (let ((unknown (first problems))
          (arity (second problems))
          (valid (third problems))
          (unvalidated-action (fourth problems)))
      (ok (string= "" (get-output-stream-string output)))
      (ok unknown)
      (ok (search "no command called" unknown))
      (ok arity)
      (ok (search "exactly 1 argument" arity))
      (ok (null valid))
      (ok (null unvalidated-action)))
    (multiple-value-bind (text status) (captured-run "undo" '())
      (ok (eql 2 status))
      (ok (search "exactly 1 argument" text)))))

;;;; The control commands.

(deftest an-unanswered-request-is-not-reported-as-a-missing-supervisor ()
  ;; Running out of the wait answered "no supervisor is running, so nothing was
  ;; asked", which sends the operator to start a second one.
  (with-empty-context
    (let* ((status nil)
           (text (with-output-to-string (*standard-output*)
                   (setf status
                         (enchiridion.channel.cli::report-control-state
                          "reload" nil :timeout
                          "the request is still queued and runs when the supervisor reaches it.")))))
      (ok (eql 1 status))
      (ok (search "did not answer within 5 seconds" text))
      (ok (search "still queued" text))
      (ng (search "no supervisor is running" text)))))

(deftest a-missing-supervisor-is-still-reported-as-one ()
  (with-empty-context
    (let* ((status nil)
           (text (with-output-to-string (*standard-output*)
                  (setf status
                        (enchiridion.channel.cli::report-control-state
                         "reload" nil :no-supervisor nil)))))
      (ok (eql 1 status))
      (ok (search "no supervisor is running" text)))))

(deftest heartbeat-time-prints-utc-or-never ()
  (ok (equal "2026-11-20T04:57:36Z"
             (enchiridion.channel.cli::heartbeat-time-line 4004139456)))
  (ok (equal "never" (enchiridion.channel.cli::heartbeat-time-line 0)))
  (ok (equal "never" (enchiridion.channel.cli::heartbeat-time-line nil))))

(deftest health-prints-the-states-a-reader-could-not-see ()
  ;; A channel configured and off, a status write failing, a schedule with no
  ;; thread: none of the three was visible in `health`.
  (let* ((directory (uiop:ensure-directory-pathname
                     (merge-pathnames
                      (format nil "enchiridion-cli-test-~D/" (random most-positive-fixnum))
                      (uiop:ensure-directory-pathname *default-pathname-defaults*))))
         (run (merge-pathnames "run/" directory))
         (supervisor (enchiridion.supervisor:make-supervisor
                      :directory (namestring directory)
                      :run-directory (namestring run)
                      :heartbeat-p nil
                      :channels '())))
    (unwind-protect
         (progn
           (enchiridion.supervisor:supervisor-write-status supervisor)
           (let* ((status (enchiridion.supervisor:read-status run))
                  (beat (enchiridion.supervisor:status-heartbeat status))
                  (writes (enchiridion.supervisor:status-writes status)))
             ;; The table is edited rather than provoked: this test is the
             ;; printer's, and the supervisor tests write the two states.
             (setf (gethash "enabled" beat) t
                   (gethash "alive" beat) nil
                   (gethash "ticks" beat) 0
                   (gethash "last-tick" beat) 4004139456)
             (setf (gethash "ok" writes) nil
                   (gethash "report" writes) "the disk is full"
                   (gethash "age" writes) 3)
             (with-empty-context
               (let ((text (with-output-to-string (*standard-output*)
                             (enchiridion.channel.cli::report-health status))))
                 (ok (search "last tick: never" text))
                 (ok (search "no live thread" text))
                 (ok (search "status writes failing: the disk is full" text))
                 (ok (search "channel http disabled" text))))))
      (ignore-errors (enchiridion.supervisor:supervisor-stop supervisor))
      (uiop:delete-directory-tree directory :validate t :if-does-not-exist :ignore))))
