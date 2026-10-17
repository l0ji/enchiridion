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
