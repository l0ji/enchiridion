;;;; tool-loop-test.cl --- The model asks, the kernel runs, the model answers.

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
             (testing "so the transcript is the question, the tool, and the answer"
               (ok (= 3 (getf (first (enchiridion.memory.store:recent-sessions store))
                              :turns)))
               (ok (= 1 (length (enchiridion.memory.store:search-sessions store "go")))))))
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
                 (ok (search "Turn 1" (cdr entry)))))))
      (enchiridion.tools:clear-registry)
      (uiop:delete-directory-tree directory
                                  :validate t
                                  :if-does-not-exist :ignore))))
