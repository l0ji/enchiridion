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
    "version" "help" "bootstrap" "health" "reload" "channels" "heartbeat" "chat"
    "serve")
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
                      ("journey" 0 2) ("tasks" 0 2) ("channels" 0 2)
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
