;;;; tool-loop-test.lsp --- The model asks, the kernel runs, the model answers.

(defpackage #:enchiridion-tool-loop-test
  (:use #:cl)
  (:import-from #:rove #:deftest #:ok #:ng #:testing #:signals)
  (:export #:run))

(in-package #:enchiridion-tool-loop-test)

(defstruct (scripted-backend (:constructor make-scripted-backend))
  (replies '() :type list)
  (transcripts '() :type list)
  (tools-seen '() :type list))

(defmethod enchiridion.llm:complete ((backend scripted-backend) messages
                                     &key model tools budget)
  (declare (ignore model budget))
  (push messages (scripted-backend-transcripts backend))
  (push tools (scripted-backend-tools-seen backend))
  (or (pop (scripted-backend-replies backend))
      (error "the scripted backend has no reply left")))

(defmethod enchiridion.llm:model-capabilities ((backend scripted-backend))
  (declare (ignore backend))
  '(:tools t))

(defmethod enchiridion.llm:backend-name ((backend scripted-backend))
  (declare (ignore backend))
  "scripted")

(defun completion (text &key tool-calls)
  (enchiridion.llm::%make-completion
   :text text :tool-calls tool-calls :model "scripted"
   :input-tokens 10 :output-tokens 5))

(defun call (id name arguments)
  (enchiridion.llm::%make-tool-call :id id :name name :arguments arguments))

(defun test-agent (backend &key (tools-p t))
  (enchiridion.kernel:make-agent
   :blocks (list (enchiridion.memory:make-block :label :persona :text "identity"))
   :backend backend :tools-p tools-p))

(deftest a-tool-call-is-run-and-the-model-gets-a-second-chance ()
  (enchiridion.tools:clear-registry)
  (unwind-protect
       (progn
         (enchiridion.tools:register-tool
          (enchiridion.tools:make-tool
           :name "echo"
           :description "Echo text."
           :schema '(:object :required (:text) :properties ((:text :string)))
           :handler (lambda (arguments) (gethash "text" arguments))))
         (let* ((backend (make-scripted-backend
                          :replies (list (completion "" :tool-calls
                                                     (list (call "c1" "echo" "{\"text\":\"hi\"}")))
                                         (completion "done"))))
                (agent (test-agent backend))
                (result (enchiridion.kernel:run-turn agent "go")))
           (ok (string= "done" (enchiridion.llm:completion-text result)))
           (ok (= 2 (length (scripted-backend-transcripts backend))))
           (ok (scripted-backend-tools-seen backend))
           (let* ((transcript (first (scripted-backend-transcripts backend)))
                  (assistant (third transcript))
                  (tool (fourth transcript)))
             (ok (= 4 (length transcript)))
             (ok (string= "assistant" (enchiridion.llm:message-role assistant)))
             (ok (string= "c1" (enchiridion.llm:tool-call-id
                                (first (enchiridion.llm:message-tool-calls assistant)))))
             (ok (string= "tool" (enchiridion.llm:message-role tool)))
             (ok (string= "hi" (enchiridion.llm:message-content tool)))
             (ok (string= "c1" (enchiridion.llm:message-tool-call-id tool))))
           (ok (= 2 (length (enchiridion.kernel:spend agent))))
           (ok (= 1 (enchiridion.kernel:agent-turn agent)))))
    (enchiridion.tools:clear-registry)))

(deftest follow-ups-use-an-unsent-draft-without-recording-it-as-a-reply ()
  (let* ((directory (merge-pathnames (format nil "enchiridion-followup-~D/"
                                            (random most-positive-fixnum))
                                     (uiop:temporary-directory)))
         (store (enchiridion.memory.store:open-store
                 :path (merge-pathnames "memory.db" directory)))
         (backend (make-scripted-backend
                   :replies (list (completion "draft") (completion "answer together"))))
         (agent (test-agent backend :tools-p nil))
         (before-request '("second"))
         (before-final '("" "  " "third")))
    (unwind-protect
         (let ((result (enchiridion.kernel:run-turn
                        agent "first" :store store
                        :steer (lambda (phase)
                                 (ecase phase
                                   (:before-request (shiftf before-request nil))
                                   (:before-final (shiftf before-final nil)))))))
           (ok (equal "answer together" (enchiridion.llm:completion-text result)))
           (destructuring-bind (revised initial) (scripted-backend-transcripts backend)
             (ok (equal '("first" "second")
                        (mapcar #'enchiridion.llm:message-content (rest initial))))
             (ok (equal (list "first" "second" (format nil "Unsent draft:~%draft") "third")
                        (mapcar #'enchiridion.llm:message-content (rest revised)))))
           (ok (equal '(("user" . "first") ("user" . "second") ("user" . "third")
                        ("assistant" . "answer together"))
                      (enchiridion.memory:conversation-window store)))
           (ok (= 2 (length (enchiridion.kernel:spend agent)))))
      (enchiridion.memory.store:close-store store)
      (uiop:delete-directory-tree directory :validate t :if-does-not-exist :ignore))))

(deftest a-follow-up-can-stop-a-planned-tool-before-it-runs ()
  (let ((enchiridion.tools::*registry* (make-hash-table :test #'equal))
        (runs 0))
    (enchiridion.tools:define-tool "fixture"
      :description "Return fixture text."
      :schema (:object)
      :handler (lambda (arguments) (declare (ignore arguments)) (incf runs) "done"))
    (let* ((plan (completion "I'll do it." :tool-calls (list (call "c1" "fixture" "{}"))))
           (backend (make-scripted-backend :replies (list plan (completion "I won't run it."))))
           (agent (test-agent backend))
           (result (enchiridion.kernel:run-turn
                    agent "Run it."
                    :steer (lambda (phase)
                             (when (eq phase :before-tools) '("Wait, don't run it."))))))
      (ok (zerop runs))
      (ok (equal "I won't run it." (enchiridion.llm:completion-text result)))
      (ok (equal '("Run it." "Wait, don't run it.")
                 (mapcar #'enchiridion.llm:message-content
                         (rest (first (scripted-backend-transcripts backend)))))))))

(deftest a-late-follow-up-gets-completed-work-without-replaying-a-tool-call ()
  (let ((enchiridion.tools::*registry* (make-hash-table :test #'equal))
        (runs 0))
    (enchiridion.tools:define-tool "fixture"
      :description "Return fixture text."
      :schema (:object)
      :handler (lambda (arguments)
                 (declare (ignore arguments))
                 (incf runs)
                 "fixture result"))
    (let* ((backend (make-scripted-backend
                     :replies (list (completion "" :tool-calls
                                                (list (call "c1" "fixture" "{}")))
                                    (completion "first reply") (completion "follow-up")
                                    (completion "separate agent"))))
           (agent (test-agent backend))
           (work (nth-value 3 (enchiridion.kernel:run-turn agent "first" :reuse-p t))))
      (ok work)
      (ok (equal "follow-up"
                 (enchiridion.llm:completion-text
                  (enchiridion.kernel:run-turn agent "clarify" :reuse-p t :prior-work work))))
      (ok (= 1 runs))
      (let ((message (second (first (scripted-backend-transcripts backend)))))
        (ok (search "fixture result" (enchiridion.llm:message-content message)))
        (ng (enchiridion.llm:message-tool-calls message)))
      (enchiridion.kernel:run-turn (test-agent backend) "different agent" :prior-work work)
      (ok (= 2 (length (first (scripted-backend-transcripts backend))))))))

(deftest a-follow-up-can-supersede-an-unpublished-status-proposal ()
  (let ((enchiridion.tools::*registry* (make-hash-table :test #'equal)))
    (enchiridion.tools.builtin:register-presence-tools)
    (let* ((backend (make-scripted-backend
                     :replies (list (completion "" :tool-calls
                                                (list (call "c1" "presence"
                                                            "{\"text\":\"away\"}")))
                                    (completion "Heading out.")
                                    (completion "I'll be here."))))
           (agent (test-agent backend))
           (pending '("Actually, don't set a status.")))
      (multiple-value-bind (reply proposal)
          (enchiridion.kernel:run-turn agent "Set your status to away."
                                       :steer (lambda (phase)
                                                (when (eq phase :before-final)
                                                  (shiftf pending nil))))
        (ok (equal "I'll be here." (enchiridion.llm:completion-text reply)))
        (ng proposal)))))

(deftest a-no-reply-marker-is-not-a-successful-silent-turn-after-tools ()
  (let ((enchiridion.tools::*registry* (make-hash-table :test #'equal))
        (runs 0))
    (enchiridion.tools:define-tool "fixture"
      :description "Return fixture text."
      :schema (:object)
      :handler (lambda (arguments) (declare (ignore arguments)) (incf runs) "done"))
    (let* ((marker "[enchiridion:no-reply]")
           (backend (make-scripted-backend
                     :replies (list (completion marker :tool-calls
                                                (list (call "c1" "fixture" "{}")))
                                    (completion marker))))
           (agent (test-agent backend)))
      (multiple-value-bind (result proposal silent-p)
          (enchiridion.kernel:run-turn agent "go" :allow-silence-p t)
        (declare (ignore proposal))
        (ng silent-p)
        (ok (= 1 runs))
        (ok (string= "" (enchiridion.llm:completion-text result)))
        (let ((assistant (third (first (scripted-backend-transcripts backend)))))
          (ok (string= "" (enchiridion.llm:message-content assistant))))))))

(deftest a-presence-call-proposes-beside-the-reply ()
  (enchiridion.tools:clear-registry)
  (unwind-protect
       (progn
         (enchiridion.tools.builtin:register-presence-tools)
         (let* ((backend (make-scripted-backend
                          :replies (list (completion "" :tool-calls
                                                     (list (call "c1" "presence"
                                                                 "{\"text\":\"Working on retries\"}")))
                                         (completion "done"))))
                (agent (test-agent backend)))
           (multiple-value-bind (result proposal)
               (enchiridion.kernel:run-turn agent "go")
             (testing "the reply and the proposal are separate values"
               (ok (string= "done" (enchiridion.llm:completion-text result)))
               (ok (string= "Working on retries" proposal)))
             (testing "the tool result tells the model the channel decides"
               (let ((tool (fourth (first (scripted-backend-transcripts backend)))))
                 (ok (search "Proposed a Fluxer custom status"
                             (enchiridion.llm:message-content tool)))))))
         (let* ((backend (make-scripted-backend
                          :replies (list (completion "" :tool-calls
                                                     (list (call "c1" "presence"
                                                                 "{\"clear\":true}")))
                                         (completion "done"))))
                (agent (test-agent backend)))
           (multiple-value-bind (result proposal)
               (enchiridion.kernel:run-turn agent "go")
             (declare (ignore result))
             (ok (eq :clear proposal))))
         (testing "a call the tool refused proposes nothing"
           (let* ((backend (make-scripted-backend
                            :replies (list (completion "" :tool-calls
                                                       (list (call "c1" "presence"
                                                                   "{\"text\":\"x\",\"clear\":true}")))
                                           (completion "done"))))
                  (agent (test-agent backend)))
             (multiple-value-bind (result proposal)
                 (enchiridion.kernel:run-turn agent "go")
               (ok (string= "done" (enchiridion.llm:completion-text result)))
               (ok (null proposal))))))
    (enchiridion.tools:clear-registry)))

(deftest a-tool-turn-is-recorded-beside-the-question ()
  (enchiridion.tools:clear-registry)
  (let* ((directory (uiop:ensure-directory-pathname
                     (merge-pathnames
                      (format nil "enchiridion-tool-loop-test-~D/"
                              (random most-positive-fixnum))
                      (uiop:ensure-directory-pathname *default-pathname-defaults*))))
         (store (enchiridion.memory.store:open-store
                 :path (merge-pathnames "memory.db" directory))))
    (unwind-protect
         (progn
           (enchiridion.tools:register-tool
            (enchiridion.tools:make-tool
             :name "echo"
             :description "Echo text."
             :schema '(:object :required (:text) :properties ((:text :string)))
             :handler (lambda (arguments) (gethash "text" arguments))))
           (let* ((backend (make-scripted-backend
                            :replies (list (completion "" :tool-calls
                                                       (list (call "c1" "echo"
                                                                   "{\"text\":\"hi\"}")))
                                           (completion "done"))))
                  (agent (test-agent backend)))
             (enchiridion.kernel:run-turn agent "go" :store store)
             (testing "the tool result is a turn of its own"
               (let ((hits (enchiridion.memory.store:search-sessions store "hi")))
                 (ok (= 1 (length hits)))
                 (ok (string= "tool"
                              (enchiridion.memory.store:turn-row-role (first hits))))))
             (testing "and the empty assistant round was not written down"
               (ok (= 1 (length (enchiridion.memory.store:search-sessions
                                 store "done")))))
             (testing "the reply is final and the tool result is not"
               (let ((rows (enchiridion.memory.store:query-rows
                            store "SELECT role, final_p FROM episodes ORDER BY id")))
                 (ok (equal '(("user" nil) ("tool" nil) ("assistant" 1))
                            (mapcar (lambda (row)
                                      (list (enchiridion.memory.store:field row "role")
                                            (enchiridion.memory.store:field row "final_p")))
                                    rows)))))
             (testing "so the transcript is the question, the tool, and the answer"
               (ok (= 3 (getf (first (enchiridion.memory.store:recent-sessions store))
                              :turns)))
               (ok (= 1 (length (enchiridion.memory.store:search-sessions store "go")))))))
      (enchiridion.tools:clear-registry)
      (enchiridion.memory.store:close-store store)
      (uiop:delete-directory-tree directory
                                  :validate t
                                  :if-does-not-exist :ignore))))

(deftest a-tool-preamble-is-interim-and-the-reply-is-final ()
  (enchiridion.tools:clear-registry)
  (let* ((directory (uiop:ensure-directory-pathname
                     (merge-pathnames
                      (format nil "enchiridion-tool-loop-test-~D/"
                              (random most-positive-fixnum))
                      (uiop:ensure-directory-pathname *default-pathname-defaults*))))
         (store (enchiridion.memory.store:open-store
                 :path (merge-pathnames "memory.db" directory))))
    (unwind-protect
         (progn
           (enchiridion.tools:register-tool
            (enchiridion.tools:make-tool
             :name "echo"
             :description "Echo text."
             :schema '(:object :required (:text) :properties ((:text :string)))
             :handler (lambda (arguments) (gethash "text" arguments))))
           (let* ((backend (make-scripted-backend
                            :replies (list (completion "checking"
                                                       :tool-calls
                                                       (list (call "c1" "echo"
                                                                   "{\"text\":\"hi\"}")))
                                            (completion "done"))))
                  (agent (test-agent backend)))
             (enchiridion.kernel:run-turn agent "go" :store store)
             (testing "the round that asked for the tool is interim, the reply final"
               (let ((rows (enchiridion.memory.store:query-rows
                            store "SELECT role, body, final_p FROM episodes ORDER BY id")))
                 (ok (equal '(("user" nil) ("assistant" 0) ("tool" nil)
                              ("assistant" 1))
                            (mapcar (lambda (row)
                                      (list (enchiridion.memory.store:field row "role")
                                            (enchiridion.memory.store:field row "final_p")))
                                    rows)))
                 (ok (string= "done" (enchiridion.memory.store:field
                                      (car (last rows)) "body")))))))
      (enchiridion.tools:clear-registry)
      (enchiridion.memory.store:close-store store)
      (uiop:delete-directory-tree directory
                                  :validate t
                                  :if-does-not-exist :ignore))))

(deftest a-wrap-up-reply-is-written-once-as-final ()
  ;; The last round at the cap still carries the tools, and it can ask for one
  ;; while saying nothing. The reply the operator reads is then the turn's
  ;; earlier words, and that is what must be marked final and stored once.
  (enchiridion.tools:clear-registry)
  (let* ((directory (uiop:ensure-directory-pathname
                     (merge-pathnames
                      (format nil "enchiridion-tool-loop-test-~D/"
                              (random most-positive-fixnum))
                      (uiop:ensure-directory-pathname *default-pathname-defaults*))))
         (store (enchiridion.memory.store:open-store
                 :path (merge-pathnames "memory.db" directory))))
    (unwind-protect
         (progn
           (enchiridion.tools:register-tool
            (enchiridion.tools:make-tool
             :name "echo"
             :description "Echo text."
             :schema '(:object :required (:text) :properties ((:text :string)))
             :handler (lambda (arguments) (gethash "text" arguments))))
           (let* ((backend (make-scripted-backend
                            :replies (list (completion "checking"
                                                       :tool-calls
                                                       (list (call "c1" "echo"
                                                                   "{\"text\":\"one\"}")))
                                            (completion "still checking"
                                                       :tool-calls
                                                       (list (call "c2" "echo"
                                                                   "{\"text\":\"two\"}")))
                                            (completion ""
                                                       :tool-calls
                                                       (list (call "c3" "echo"
                                                                   "{\"text\":\"three\"}"))))))
                  (agent (enchiridion.kernel:make-agent
                          :blocks (list (enchiridion.memory:make-block
                                         :label :persona :text "identity"))
                          :backend backend :tools-p t :tool-rounds 1))
                  (result (enchiridion.kernel:run-turn agent "go" :store store)))
             (testing "the operator reads the last words, not an empty request"
               (ok (string= "still checking"
                            (enchiridion.llm:completion-text result))))
             (testing "the final row is stored once and marked final"
               (let ((rows (enchiridion.memory.store:query-rows
                            store "SELECT role, body, final_p FROM episodes ORDER BY id")))
                 (ok (equal '(nil 0 nil 0 1)
                            (mapcar (lambda (row)
                                      (enchiridion.memory.store:field row "final_p"))
                                    rows)))
                 (ok (string= "still checking"
                              (enchiridion.memory.store:field
                               (car (last rows)) "body")))))))
      (enchiridion.tools:clear-registry)
      (enchiridion.memory.store:close-store store)
      (uiop:delete-directory-tree directory
                                  :validate t
                                  :if-does-not-exist :ignore))))

(deftest a-tool-error-is-text-not-a-crash ()
  (enchiridion.tools:clear-registry)
  (unwind-protect
       (let* ((backend (make-scripted-backend
                        :replies (list (completion "" :tool-calls
                                                   (list (call "c1" "missing" "{}")))
                                       (completion "recovered"))))
              (agent (test-agent backend))
              (result (enchiridion.kernel:run-turn agent "go")))
         (ok (string= "recovered" (enchiridion.llm:completion-text result)))
         (let* ((transcript (first (scripted-backend-transcripts backend)))
                (tool (fourth transcript)))
           (ok (search "error:" (enchiridion.llm:message-content tool)))))
    (enchiridion.tools:clear-registry)))

(deftest a-no-tools-agent-sends-no-tools ()
  (let* ((backend (make-scripted-backend :replies (list (completion "plain"))))
         (agent (test-agent backend :tools-p nil)))
    (enchiridion.kernel:run-turn agent "go")
    (ok (null (first (scripted-backend-tools-seen backend))))))

;;;; The request half.

(deftest tools-reach-the-openai-request ()
  (let ((definition (make-hash-table :test #'equal)))
    (setf (gethash "name" definition) "echo")
    (setf (gethash "description" definition) "Echo.")
    (setf (gethash "parameters" definition)
          (enchiridion.tools:schema-to-json
           '(:object :required (:text) :properties ((:text :string)))))
    (let* ((body (enchiridion.llm:completion-request
                  "m" (list (enchiridion.llm:user-message "hi"))
                  :tools (list definition)))
           (parsed (enchiridion.llm:parse-json body)))
      (ok (string= "auto" (getf parsed :tool_choice)))
      (ok (= 1 (length (getf parsed :tools))))
      (ok (string= "echo" (getf (getf (first (getf parsed :tools)) :function) :name))))))

(deftest an-assistant-tool-call-survives-the-request ()
  (let* ((message (enchiridion.llm:assistant-message
                   "" (list (call "c1" "echo" "{\"text\":\"hi\"}"))))
         (body (enchiridion.llm:completion-request "m" (list message)))
         (parsed (enchiridion.llm:parse-json body))
         (sent (first (getf parsed :messages)))
         (tool-call (first (getf sent :tool_calls))))
    (ok (string= "c1" (getf tool-call :id)))
    (ok (string= "echo" (getf (getf tool-call :function) :name)))
    (ok (string= "{\"text\":\"hi\"}"
                 (getf (getf tool-call :function) :arguments)))))

(deftest operator-file-refreshes-on-the-next-turn
  (let* ((directory (merge-pathnames (format nil "identity-refresh-~D/" (random most-positive-fixnum))
                                     (uiop:temporary-directory)))
         (operator (merge-pathnames "OPERATOR.md" directory))
         (bootstrap (merge-pathnames "BOOTSTRAP.md" directory))
         (backend (make-scripted-backend :replies (list (completion "one") (completion "two")))))
    (unwind-protect
         (progn
           (ensure-directories-exist operator)
           (enchiridion.memory:write-block-file operator "original operator text")
           (enchiridion.memory:write-block-file bootstrap "1. Verify the identity files.")
           (let ((agent (enchiridion.kernel:make-agent :directory directory :backend backend)))
             (multiple-value-bind (text outcome failed)
                 (enchiridion.kernel::execute-tool agent (call "blocked" "shell" "{}"))
               (declare (ignore outcome))
               (ok failed)
               (ok (search "unavailable until bootstrap handover" text)))
             (enchiridion.kernel:run-turn agent "go")
             (enchiridion.memory:write-block-file operator "updated operator text")
             (enchiridion.kernel:run-turn agent "continue")
             (destructuring-bind (latest first) (scripted-backend-transcripts backend)
               (let ((initial (enchiridion.llm:message-content (first first)))
                     (current (enchiridion.llm:message-content (first latest))))
                 (ok (search "original operator text" initial))
                 (ok (search "Until handover, blockops and file refuse your writes" initial))
                 (ok (search "updated operator text" current))
                 (ng (search "original operator text" current))))))
      (uiop:delete-directory-tree directory :validate t :if-does-not-exist :ignore))))

(deftest a-turn-that-edits-soul-md-lands-in-the-agent-repository ()
  ;; The agent edits SOUL.md after bootstrap hands over, and the change lands
  ;; in git. The backend is scripted, so what this proves is the harness
  ;; chain - kernel, tool, file, commit - and not a model's willingness to
  ;; cooperate.
  ;;
  ;; The commit itself needs an identity, and the build sandbox has no global
  ;; git configuration, so *COMMIT-ENVIRONMENT* carries the test one. In
  ;; production it is NIL and the operator's own key signs the commit.
  (let ((directory (uiop:ensure-directory-pathname
                    (merge-pathnames
                     (format nil "enchiridion-handover-test-~D/"
                             (random most-positive-fixnum))
                     (uiop:ensure-directory-pathname *default-pathname-defaults*))))
        (enchiridion.git:*commit-environment*
          (enchiridion.git:git-test-environment)))
    (unwind-protect
         (progn
           (enchiridion.memory:init-agent directory)
           (dotimes (step 8)
             (enchiridion.memory:mark-bootstrap-step directory (1+ step)))
           (enchiridion.tools:clear-registry)
           (enchiridion.tools.builtin:register-builtin-tools)
           (let* ((soul (merge-pathnames "SOUL.md" directory))
                  ;; The heading, read from the template, not a sentence from it.
                  ;; A template rewrite must not break this test.
                  (heading (first (uiop:split-string
                                   (uiop:read-file-string soul)
                                   :separator '(#\Newline))))
                  (arguments (format nil "{\"action\":\"patch\",\"label\":\"soul\",\"old\":~S,\"new\":\"Written by the agent itself.\",\"directory\":~S}"
                                     heading (namestring directory)))
                  (backend (make-scripted-backend
                            :replies (list (completion
                                            "" :tool-calls
                                            (list (call "c1" "blockops" arguments)))
                                           (completion "done"))))
                  (agent (enchiridion.kernel:make-agent
                          :blocks (list (enchiridion.memory:make-block
                                         :label :persona :text "identity"))
                          :backend backend :directory directory)))
             (testing "after handover the write is allowed and the turn finishes"
               (ok (string= "done"
                            (enchiridion.llm:completion-text
                             (enchiridion.kernel:run-turn
                              agent "write down who you are"))))
               (ok (search "Written by the agent itself."
                           (uiop:read-file-string
                            (merge-pathnames "SOUL.md" directory)))))
             (testing "and the turn that wrote it is a commit in the repository"
               (let ((entry (first (enchiridion.git:git-log directory :limit 5))))
                 (ok entry)
                 (ok (search "Agent turn 1" (cdr entry)))))))
      (enchiridion.tools:clear-registry)
      (uiop:delete-directory-tree directory
                                  :validate t
                                  :if-does-not-exist :ignore))))
