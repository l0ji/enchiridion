(defpackage #:enchiridion-episodic-hooks-test
  (:use #:cl)
  (:import-from #:rove #:deftest #:ok #:ng #:testing)
  (:export #:run))

(in-package #:enchiridion-episodic-hooks-test)

(defstruct (recording-backend (:constructor make-recording-backend))
  (transcript '() :type list))

(defmethod enchiridion.llm:complete ((backend recording-backend) messages
                                     &key model tools budget)
  (declare (ignore model tools budget))
  (setf (recording-backend-transcript backend) messages)
  (enchiridion.llm::%make-completion
   :text "fake reply"
   :model "fake-model"
   :input-tokens 7
   :output-tokens 3))

(defmethod enchiridion.llm:model-capabilities ((backend recording-backend))
  (declare (ignore backend))
  '(:tools nil))

(defmethod enchiridion.llm:backend-name ((backend recording-backend))
  (declare (ignore backend))
  "recording")

(defun scratch-store ()
  "Return a fresh store and its directory."
  (let* ((directory (uiop:ensure-directory-pathname
                     (merge-pathnames
                      (format nil "enchiridion-episodic-hooks-test-~D/"
                              (random most-positive-fixnum))
                      (uiop:ensure-directory-pathname *default-pathname-defaults*))))
         (store (enchiridion.memory.store:open-store
                 :path (merge-pathnames "memory.db" directory))))
    (values store directory)))

(defmacro with-store ((store directory) &body body)
  `(multiple-value-bind (,store ,directory) (scratch-store)
     (unwind-protect (progn ,@body)
       (ignore-errors (enchiridion.memory.store:close-store ,store))
       (uiop:delete-directory-tree ,directory
                                   :validate t
                                   :if-does-not-exist :ignore))))

(defun make-test-agent (backend)
  (enchiridion.kernel:make-agent
   :blocks (list (enchiridion.memory:make-block
                  :label :persona :text "identity" :limit 100))
   :backend backend
   :tools-p nil))

(defun count-rows (store sql &optional parameters)
  (enchiridion.memory.store:field
   (first (enchiridion.memory.store:query-rows store sql parameters))
   "n"))

(deftest a-turn-with-a-store-writes-one-episode-per-turn ()
  (with-store (store directory)
    (let* ((backend (make-recording-backend))
           (agent (make-test-agent backend))
           (session (enchiridion.kernel:make-session :agent agent)))
      (enchiridion.kernel:run-turn agent "the index is on port 8080"
                                   :session session :store store)
      (testing "the transcript and the log both record the turn pair"
        (ok (= 2 (count-rows store "SELECT COUNT(*) AS n FROM turns")))
        (ok (= 2 (count-rows store "SELECT COUNT(*) AS n FROM episodes"))))
      (testing "a first turn has no earlier record to retrieve"
        (ok (zerop (count-rows store "SELECT COUNT(*) AS n FROM retrievals")))))))


(deftest a-later-turn-receives-a-pack-in-the-user-message-only ()
  (with-store (store directory)
    (let* ((backend (make-recording-backend))
           (agent (make-test-agent backend))
           (session (enchiridion.kernel:make-session :agent agent)))
      (enchiridion.kernel:run-turn agent "the index is on port 8080"
                                   :session session :store store)
      (enchiridion.kernel:run-turn agent "what port is the index on"
                                   :session session :store store)
      (let ((transcript (recording-backend-transcript backend)))
        (testing "the system prompt is the frozen snapshot, not the pack"
          (ok (string= "system" (enchiridion.llm:message-role (first transcript))))
          (ng (search "Retrieved records"
                      (enchiridion.llm:message-content (first transcript)))))
        (testing "the pack reaches the user message"
          (ok (search "Retrieved records"
                      (enchiridion.llm:message-content (second transcript))))
          (ok (search "[ref episode-"
                      (enchiridion.llm:message-content (second transcript))))))
      (testing "the stored user turn is the operator's text, not the pack"
        (let ((row (first (enchiridion.memory.store:search-sessions
                           store "what port is the index on"))))
          (ok row)
          (ok (string= "what port is the index on"
                       (enchiridion.memory.store:turn-row-body row)))))
      (testing "the retrieval prediction was written"
        (ok (plusp (count-rows store "SELECT COUNT(*) AS n FROM retrievals")))))))


(deftest the-transcript-and-saved-memories-are-episodes ()
  (with-store (store directory)
    (enchiridion.memory.store:record-turn store :session "s" :role "user"
                                          :body "the build failed")
    (enchiridion.memory.store:save-memory store "note" "the linker could not find the library")
    (testing "one log holds both rows"
      (ok (= 2 (count-rows store "SELECT COUNT(*) AS n FROM episodes"))))
    (testing "the transcript view sees the turn and not the memory"
      (ok (= 1 (count-rows store "SELECT COUNT(*) AS n FROM turns")))
      (ok (= 1 (length (enchiridion.memory.store:search-sessions store "build")))))
    (testing "the memories view sees the memory and not the turn"
      (ok (= 1 (count-rows store "SELECT COUNT(*) AS n FROM memories")))
      (ok (= 1 (length (enchiridion.memory.store:search-memories store "linker")))))))


(deftest status-reports-the-log-and-the-live-layer ()
  (with-store (store directory)
    (let ((status (enchiridion.memory:memory-status store)))
      (ok (getf status :enabled))
      (ok (= 0 (getf status :live-generation)))
      (ok (= 0 (getf status :episodes))))))


(deftest configuration-binds-the-switches ()
  (let ((enchiridion.memory::*memory-enabled-p* t))
    (unwind-protect
         (progn
           (enchiridion.memory:configure-memory
            '(:memory (:enabled nil) (:retrieve nil) (:push t) (:pack-chars 100)))
           (testing "the master switch and the derived switches follow the section"
             (ok (not (enchiridion.memory:enabled-p)))
             (ok (not (enchiridion.memory:retrieval-enabled-p)))
             (ok (not (enchiridion.memory:push-enabled-p))))
           (testing "the pack budget follows the section"
             (ok (= 100 enchiridion.memory::*memory-pack-chars*)))
           (enchiridion.memory:configure-memory
            '(:memory (:enabled t) (:push t)))
           (testing "push needs the master switch and its own flag"
             (ok (enchiridion.memory:enabled-p))
             (ok (enchiridion.memory:push-enabled-p))))
      (enchiridion.memory:configure-memory
       (enchiridion:default-config)))))
