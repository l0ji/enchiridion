;;;; kernel-test.cl --- The prompt compiler, the frozen snapshot, and the turn.
;;;;
;;;; The backend here is a fake. A turn is the boundary between the kernel and
;;;; a provider, and the two facts that matter at that boundary are the bytes
;;;; that leave and the ledger row that comes back. Neither needs a socket.

(defpackage #:enchiridion-kernel-test
  (:use #:cl)
  (:import-from #:rove #:deftest #:ok #:ng #:testing #:signals)
  (:export #:run))

(in-package #:enchiridion-kernel-test)

(defstruct (fake-backend (:constructor make-fake-backend))
  (transcript '() :type list))

(defmethod enchiridion.llm:complete ((backend fake-backend) messages
                                     &key model tools budget)
  (declare (ignore model tools budget))
  (setf (fake-backend-transcript backend) messages)
  (enchiridion.llm::%make-completion
   :text "fake reply"
   :model "fake-model"
   :input-tokens 7
   :output-tokens 3))

(defmethod enchiridion.llm:model-capabilities ((backend fake-backend))
  (declare (ignore backend))
  '(:tools nil))

(defmethod enchiridion.llm:backend-name ((backend fake-backend))
  (declare (ignore backend))
  "fake")

(defun make-test-block (text &key (label :persona) (limit 100) (writable-p t))
  (enchiridion.memory:make-block :label label :text text
                                 :limit limit :writable-p writable-p))

(deftest a-turn-with-a-store-is-recorded ()
  (let* ((directory (uiop:ensure-directory-pathname
                     (merge-pathnames
                      (format nil "enchiridion-kernel-test-~D/"
                              (random most-positive-fixnum))
                      (uiop:ensure-directory-pathname *default-pathname-defaults*))))
         (store (enchiridion.memory.store:open-store
                 :path (merge-pathnames "memory.db" directory))))
    (unwind-protect
         (let* ((blocks (list (make-test-block "voice")))
                (agent (enchiridion.kernel:make-agent
                        :backend (make-fake-backend) :blocks blocks :tools-p nil))
                (session (enchiridion.kernel:make-session :agent agent)))
           (enchiridion.kernel:run-turn agent "what is the index"
                                        :session session :store store)
           (testing "the question is in the transcript, under its session"
             (let ((hits (enchiridion.memory.store:search-sessions store "index")))
               (ok (= 1 (length hits)))
               (ok (string= "user" (enchiridion.memory.store:turn-row-role (first hits))))
               (ok (string= (enchiridion.kernel:session-id session)
                            (enchiridion.memory.store:turn-row-session (first hits))))))
           (testing "the answer is there too, exactly once, and names its model"
             (let ((hits (enchiridion.memory.store:search-sessions store "fake reply")))
               (ok (= 1 (length hits)))
               (ok (string= "fake-model"
                            (enchiridion.memory.store:turn-row-model (first hits))))))
           (testing "and the spend row is in the usage ledger"
             (let ((rows (enchiridion.memory.store:usage-rows store)))
               (ok (= 1 (length rows)))
               (ok (string= "fake-model" (getf (first rows) :model)))
               (ok (= 7 (getf (first rows) :input)))
               (ok (= 3 (getf (first rows) :output)))
               (ok (string= (enchiridion.kernel:session-id session)
                            (getf (first rows) :session))))))
      (enchiridion.memory.store:close-store store)
      (uiop:delete-directory-tree directory
                                  :validate t
                                  :if-does-not-exist :ignore))))

(deftest a-prompt-is-compiled-once-and-flagged-frozen ()
  (let* ((blocks (list (make-test-block "voice")))
         (prompt (enchiridion.kernel:compile-prompt blocks))
         (agent (enchiridion.kernel:make-agent :blocks blocks)))
    (ok (enchiridion.kernel:snapshot-p prompt))
    (ok (plusp (enchiridion.kernel:prompt-tokens prompt)))
    (ok (search "voice" (enchiridion.kernel:prompt-text prompt)))
    (ok (string= (enchiridion.kernel:prompt-text prompt)
                 (enchiridion.kernel:prompt-text
                  (enchiridion.kernel:agent-snapshot agent))))))

(deftest a-write-after-the-snapshot-does-not-change-the-prompt ()
  (let* ((persona (make-test-block "one"))
         (agent (enchiridion.kernel:make-agent :blocks (list persona)))
         (before (enchiridion.kernel:prompt-text
                  (enchiridion.kernel:agent-snapshot agent))))
    (enchiridion.memory:set-block-text persona "two")
    (ok (string= "two" (enchiridion.memory:block-text persona)))
    (testing "the live block changed"
      (ok (string= "two" (enchiridion.memory:block-text persona))))
    (testing "but the compiled prompt did not"
      (ok (string= before
                   (enchiridion.kernel:prompt-text
                    (enchiridion.kernel:agent-snapshot agent)))))))

(deftest a-turn-sends-the-prompt-and-the-user-text ()
  (let* ((backend (make-fake-backend))
         (agent (enchiridion.kernel:make-agent
                 :blocks (list (make-test-block "identity"))
                 :backend backend))
         (completion (enchiridion.kernel:run-turn agent "hello")))
    (ok (string= "fake reply" (enchiridion.llm:completion-text completion)))
    (let ((transcript (fake-backend-transcript backend)))
      (ok (= 2 (length transcript)))
      (ok (string= "system" (enchiridion.llm:message-role (first transcript))))
      (ok (search "identity" (enchiridion.llm:message-content (first transcript))))
      (ok (string= "user" (enchiridion.llm:message-role (second transcript))))
      (ok (string= "hello" (enchiridion.llm:message-content (second transcript)))))
    (ok (= 1 (enchiridion.kernel:agent-turn agent)))
    (let ((rows (enchiridion.kernel:spend agent)))
      (ok (= 1 (length rows)))
      (ok (string= "fake-model"
                   (enchiridion.kernel::spend-row-model (first rows))))
      (ok (= 7 (enchiridion.kernel::spend-row-input (first rows))))
      (ok (= 3 (enchiridion.kernel::spend-row-output (first rows)))))))

(deftest a-secret-in-the-user-text-is-scrubbed-before-the-backend-sees-it ()
  (enchiridion.llm.secrets:clear-secrets)
  (enchiridion.llm.secrets:register-secret "TEST_KEY" "secret-value-123456")
  (unwind-protect
       (let* ((backend (make-fake-backend))
              (agent (enchiridion.kernel:make-agent
                      :blocks (list (make-test-block "identity"))
                      :backend backend)))
         (enchiridion.kernel:run-turn agent "my key is secret-value-123456")
         (let ((text (enchiridion.llm:message-content
                      (second (fake-backend-transcript backend)))))
           (ng (search "secret-value-123456" text))
           (ok (search enchiridion.llm.secrets:+redaction-marker+ text))))
    (enchiridion.llm.secrets:clear-secrets)))

(deftest a-session-collects-turns-and-closes ()
  (let* ((agent (enchiridion.kernel:make-agent
                 :blocks (list (make-test-block "identity"))
                 :backend (make-fake-backend)))
         (session (enchiridion.kernel:make-session :agent agent)))
    (ok (plusp (length (enchiridion.kernel:session-id session))))
    (enchiridion.kernel:run-turn agent "one" :session session)
    (enchiridion.kernel:run-turn agent "two" :session session)
    (ok (= 2 (length (enchiridion.kernel:session-turns session))))
    (enchiridion.kernel:end-session session)
    (ok (signals (enchiridion.kernel:run-turn agent "three" :session session)
                 'enchiridion.errors:configuration-error))))

(deftest the-ledger-stops-at-a-tick-cap ()
  (let* ((agent (enchiridion.kernel:make-agent
                 :blocks (list (make-test-block "identity"))
                 :backend (make-fake-backend)
                 :budget '(:max-tokens-per-tick 5))))
    (ng (enchiridion.kernel:budget-exhausted-p agent))
    (enchiridion.kernel:run-turn agent "hello")
    (ok (enchiridion.kernel:budget-exhausted-p agent))
    (enchiridion.kernel:reset-spend agent)
    (ng (enchiridion.kernel:budget-exhausted-p agent))))

(deftest an-agent-directory-supplies-the-persona-block ()
  (let* ((directory (merge-pathnames
                     (format nil "enchiridion-kernel-test-~D/"
                             (random most-positive-fixnum))
                     (uiop:ensure-directory-pathname *default-pathname-defaults*)))
         (soul (merge-pathnames "SOUL.md" directory)))
    (unwind-protect
         (progn
           (ensure-directories-exist soul)
           (with-open-file (stream soul :direction :output
                                        :if-exists :supersede
                                        :if-does-not-exist :create)
             (write-string "the operator's soul" stream))
           (let ((agent (enchiridion.kernel:make-agent :directory directory)))
             (ok (search "the operator's soul"
                         (enchiridion.kernel:prompt-text
                          (enchiridion.kernel:agent-snapshot agent))))))
      (uiop:delete-directory-tree directory
                                  :validate t
                                  :if-does-not-exist :ignore))))

;;;; The channel a turn arrived on.

(deftest a-turn-records-the-channel-it-arrived-on ()
  ;; Every surface normalises into one loop, so the only place a webhook turn
  ;; and a typed turn differ is the channel they carry. A ledger grouped by
  ;; channel is a lie if the loop does not pass it on.
  (let* ((directory (uiop:ensure-directory-pathname
                     (merge-pathnames
                      (format nil "enchiridion-kernel-test-~D/"
                              (random most-positive-fixnum))
                      (uiop:ensure-directory-pathname *default-pathname-defaults*))))
         (store (enchiridion.memory.store:open-store
                 :path (merge-pathnames "memory.db" directory))))
    (unwind-protect
         (let ((agent (enchiridion.kernel:make-agent
                       :backend (make-fake-backend)
                       :blocks (list (make-test-block "voice"))
                       :tools-p nil)))
           (enchiridion.kernel:run-turn agent "who is asking" :channel :http
                                                          :store store)
           (testing "the transcript row names the channel"
             (let ((row (first (enchiridion.memory.store:search-sessions
                                store "who is asking"))))
               (ok row)
               ;; A turn row carries the channel as a keyword; the usage row
               ;; below carries it as the string SQLite stores.
               (ok (eq :http
                       (enchiridion.memory.store:turn-row-channel row)))))
           (testing "and the spend row names it too"
             (let ((row (first (enchiridion.memory.store:usage-rows store))))
               (ok row)
               (ok (string= "http" (getf row :channel))))))
      (ignore-errors (enchiridion.memory.store:close-store store))
      (uiop:delete-directory-tree directory
                                  :validate t
                                  :if-does-not-exist :ignore))))

;;;; One turn at a time.

;; A backend that stays inside COMPLETE until the test lets it go, so a second
;; turn arrives while the first is really in flight rather than racing a fast
;; one.
(defstruct (blocking-backend (:constructor make-blocking-backend))
  (entered nil :type boolean)
  (release nil :type boolean))

(defmethod enchiridion.llm:complete ((backend blocking-backend) messages
                                     &key model tools budget)
  (declare (ignore messages model tools budget))
  (setf (blocking-backend-entered backend) t)
  (loop until (blocking-backend-release backend) do (sleep 0.01))
  (enchiridion.llm::%make-completion
   :text "released"
   :model "blocking-model"
   :input-tokens 5
   :output-tokens 2))

(defmethod enchiridion.llm:model-capabilities ((backend blocking-backend))
  (declare (ignore backend))
  '(:tools nil))

(defmethod enchiridion.llm:backend-name ((backend blocking-backend))
  (declare (ignore backend))
  "blocking")

(deftest a-busy-agent-refuses-rather-than-queueing ()
  (let* ((backend (make-blocking-backend))
         (agent (enchiridion.kernel:make-agent
                 :backend backend
                 :blocks (list (make-test-block "voice"))
                 :tools-p nil))
         (thread (bordeaux-threads:make-thread
                  (lambda () (enchiridion.kernel:run-turn agent "first")))))
    (unwind-protect
         (progn
           (loop repeat 500 until (blocking-backend-entered backend) do (sleep 0.01))
           (ok (blocking-backend-entered backend))
           (testing "a caller that will not wait is told the agent is busy"
             (ok (handler-case
                     (progn (enchiridion.kernel:run-turn agent "second" :block-p nil)
                            nil)
                   (enchiridion.errors:turn-busy () t))))
           (testing "and a caller that waits gets its turn afterwards"
             (setf (blocking-backend-release backend) t)
             (bordeaux-threads:join-thread thread)
             (enchiridion.kernel:run-turn agent "third")
             (ok (= 2 (enchiridion.kernel:agent-turn agent)))))
      (setf (blocking-backend-release backend) t)
      (when (bordeaux-threads:thread-alive-p thread)
        (bordeaux-threads:join-thread thread)))))

(deftest many-turns-through-one-agent-keep-every-ledger-row ()
  ;; The spend list, the turn counter and the session's turn list are pushed
  ;; without a lock of their own, so the agent's lock is the only thing that
  ;; stops two channels from losing each other's rows.
  (let* ((agent (enchiridion.kernel:make-agent
                 :backend (make-fake-backend)
                 :blocks (list (make-test-block "voice"))
                 :tools-p nil))
         (session (enchiridion.kernel:make-session :agent agent))
         (threads (loop for index from 1 to 8
                        collect (bordeaux-threads:make-thread
                                 (lambda ()
                                   (enchiridion.kernel:run-turn
                                    agent (format nil "turn ~D" index)
                                    :session session))))))
    (dolist (thread threads)
      (bordeaux-threads:join-thread thread))
    (testing "every turn's spend row survived"
      (ok (= 8 (length (enchiridion.kernel:spend agent)))))
    (testing "and every turn was counted"
      (ok (= 8 (enchiridion.kernel:agent-turn agent))))
    (testing "and every completion is in the session"
      (ok (= 8 (length (enchiridion.kernel:session-turns session)))))))
