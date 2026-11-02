;;;; generation-test.cl --- Candidate generations and promotion.
;;;;
;;;; The deriver here is deterministic. That is the point: the generation
;;;; lifecycle, the isolation between a candidate and the live layer, the
;;;; update branch, and rollback must be testable without a model call.

(defpackage #:enchiridion-generation-test
  (:use #:cl)
  (:import-from #:rove #:deftest #:ok #:ng #:testing)
  (:export #:run))

(in-package #:enchiridion-generation-test)

(defun scratch-store ()
  (let* ((directory (uiop:ensure-directory-pathname
                     (merge-pathnames
                      (format nil "enchiridion-generation-test-~D/"
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

(defun write-body (store body)
  (enchiridion.memory:write-episode
   store :session "s" :role "user" :body body :derive-p nil))

(defun simple-assertion (episode subject relation object
                         &key (valid-from 100) (span-end nil))
  (enchiridion.memory:make-assertion
   :subject subject
   :relation relation
   :object object
   :episode-id (enchiridion.memory:episode-id episode)
   :span-start 0
   :span-end (or span-end (length (enchiridion.memory:episode-body episode)))
   :valid-from valid-from
   :provenance "owner"
   :authority 5))

(defun test-deriver (store episode)
  "Derive a triple from the body, plus a change event for the GAMMA case."
  (declare (ignore store))
  (let ((body (enchiridion.memory:episode-body episode)))
    (cond
      ((search "alpha is beta" body)
       (values (list (simple-assertion episode "alpha" "is" "beta"
                                       :valid-from 100))
               nil))
      ((search "alpha is gamma" body)
       (values (list (simple-assertion episode "alpha" "is" "gamma"
                                       :valid-from 200))
               (list (enchiridion.memory::make-change-event
                      :episode-id (enchiridion.memory:episode-id episode)
                      :subject "alpha"
                      :relation "is"
                      :old-object "beta"
                      :new-object "gamma"
                      :event-ts 200
                      :source "owner"))))
      (t (values nil nil)))))

(deftest a-candidate-is-invisible-until-promotion ()
  (with-store (store directory)
    (let ((enchiridion.memory:*assertion-deriver*
            #'test-deriver))
      (write-body store "alpha is beta")
      (write-body store "alpha is beta again")
      (let* ((report (enchiridion.memory:build-candidate
                      store :limit 10))
             (generation (getf report :generation-id)))
        (testing "the build completes with a candidate"
          (ok (getf report :built))
          (ok (= 2 (getf report :assertions)))
          (ok (eq :candidate (getf report :status)))
          (ok (= 2 (enchiridion.memory:generation-assertion-count
                    store generation))))
        (testing "the live layer and the live view are still empty"
          (ok (zerop (enchiridion.memory:live-generation-id store)))
          (ok (zerop (enchiridion.memory:live-assertion-count store))))
        (enchiridion.memory:promote-generation store generation)
        (testing "promotion switches the live view"
          (ok (= generation (enchiridion.memory:live-generation-id store)))
          (ok (= 2 (enchiridion.memory:live-assertion-count store))))
        (enchiridion.memory:rollback-generation store generation)
        (testing "rollback returns the pointer to the parent"
          (ok (zerop (enchiridion.memory:live-generation-id store)))
          (ok (zerop (enchiridion.memory:live-assertion-count store))))))))

(deftest a-build-resumes-the-same-generation ()
  (with-store (store directory)
    (let ((enchiridion.memory:*assertion-deriver*
            #'test-deriver))
      (write-body store "alpha is beta")
      (write-body store "gamma is delta")
      (write-body store "alpha is beta again")
      (let* ((first (enchiridion.memory:build-candidate store :limit 1))
             (id (getf first :generation-id))
             (second (enchiridion.memory:build-candidate store :limit 1))
             (third (enchiridion.memory:build-candidate store :limit 1)))
        (testing "the first batch leaves a building generation"
          (ok (eq :building (getf first :status)))
          (ok (= 2 (getf first :remaining))))
        (testing "the next batch continues the same generation"
          (ok (= id (getf second :generation-id)))
          (ok (= 1 (getf second :remaining))))
        (testing "the last batch finishes it"
          (ok (= id (getf third :generation-id)))
          (ok (eq :candidate (getf third :status)))
          (ok (zerop (getf third :remaining))))))))

(deftest no-deriver-builds-nothing ()
  (with-store (store directory)
    (let ((enchiridion.memory:*assertion-deriver* nil))
      (write-body store "alpha is beta")
      (let ((report (enchiridion.memory:build-candidate store)))
        (ok (not (getf report :built)))
        (ok (eq :no-deriver (getf report :reason)))
        (ok (zerop (enchiridion.memory:generation-assertion-count
                    store 1)))))))

(deftest a-change-event-makes-the-pair-an-update ()
  (with-store (store directory)
    (let ((enchiridion.memory:*assertion-deriver*
            #'test-deriver))
      (write-body store "alpha is beta")
      (write-body store "alpha is gamma")
      (let ((report (enchiridion.memory:build-candidate
                     store :limit 10)))
        (testing "both assertions are present"
          (ok (= 2 (getf report :assertions))))
        (testing "the old interval is closed and no conflict is opened"
          (ok (= 1 (getf report :closed)))
          (ok (zerop (getf report :conflicts)))
          (let ((row (first (enchiridion.memory.store:query-rows
                             store
                             "SELECT COUNT(*) AS n FROM assertions
                               WHERE generation_id = ?
                                 AND tx_to IS NOT NULL"
                             (list (getf report :generation-id))))))
            (ok (= 1 (enchiridion.memory.store:field row "n")))))))))

(deftest an-invalid-span-is-rejected ()
  (with-store (store directory)
    (let ((enchiridion.memory:*assertion-deriver*
            (lambda (store episode)
              (declare (ignore store))
              (values (list (simple-assertion episode "alpha" "is" "beta"
                                              :span-end 0))
                      nil))))
      (write-body store "alpha is beta")
      (let ((report (enchiridion.memory:build-candidate
                     store :limit 10)))
        (ok (= 0 (getf report :assertions)))
        (ok (= 1 (getf report :rejected)))
        (ok (zerop (enchiridion.memory:generation-assertion-count
                    store (getf report :generation-id))))))))

(defstruct (json-backend (:constructor make-json-backend))
  (text "[]" :type string))

(defmethod enchiridion.llm:complete ((backend json-backend) messages
                                     &key model tools budget)
  (declare (ignore messages model tools budget))
  (enchiridion.llm::%make-completion
   :text (json-backend-text backend)
   :model "json-fake"
   :input-tokens 0
   :output-tokens 0))

(deftest the-model-deriver-parses-a-json-array ()
  (with-store (store directory)
    (let* ((backend (make-json-backend
                     :text "```json
[{\"subject\":\"alpha\",\"relation\":\"is\",\"object\":\"beta\",\"polarity\":1,\"span_start\":0,\"span_end\":13,\"valid_from\":null,\"valid_to\":null}]
```"))
           (deriver (enchiridion.memory:make-model-assertion-deriver
                     backend)))
      (let ((episode (write-body store "alpha is beta")))
        (multiple-value-bind (assertions events) (funcall deriver store episode)
          (ok (= 1 (length assertions)))
          (ok (null events))
          (let ((assertion (first assertions)))
            (ok (string= "alpha"
                         (enchiridion.memory:assertion-subject assertion)))
            (ok (string= "beta"
                         (enchiridion.memory:assertion-object assertion)))
            (ok (= 0 (enchiridion.memory:assertion-span-start assertion)))
            (ok (= 13 (enchiridion.memory:assertion-span-end assertion)))))))))

(defun assertion-hits (store cue generation)
  "Return the assertion rows a retrieval for CUE ranks, reading GENERATION."
  (remove-if-not (lambda (row) (string= "assertion" (getf (getf row :item) :kind)))
                 (enchiridion.memory:retrieve-rows-for-turn
                  store cue :generation generation :top-k nil)))

(deftest a-retrieval-reads-only-the-generation-it-names ()
  ;; The utility and tail gates compare a candidate arm with a retention-only
  ;; arm, and a turn reads the live layer. All three are one function with a
  ;; different generation, so they cannot drift apart.
  (with-store (store directory)
    (let ((enchiridion.memory:*assertion-deriver* #'test-deriver))
      (write-body store "alpha is beta")
      (let ((generation (getf (enchiridion.memory:build-candidate store :limit 10)
                              :generation-id)))
        (testing "the candidate arm sees the candidate's assertion"
          (let ((hits (assertion-hits store "alpha" generation)))
            (ok (= 1 (length hits)))
            (ok (string= "alpha is beta" (getf (getf (first hits) :item) :body)))))
        (testing "a turn does not, before promotion"
          (ok (null (assertion-hits store "alpha" :live))))
        (testing "the retention-only arm never does"
          (ok (null (assertion-hits store "alpha" nil))))
        (enchiridion.memory:promote-generation store generation)
        (testing "a turn does once the candidate is live"
          (ok (= 1 (length (assertion-hits store "alpha" :live)))))
        (testing "and the retention-only arm still does not"
          (ok (null (assertion-hits store "alpha" nil))))))))

(defun generation-status-of (store id)
  (enchiridion.memory.store:field
   (first (enchiridion.memory.store:query-rows
           store "SELECT status FROM generations WHERE id = ?" (list id)))
   "status"))

(deftest rolling-back-a-live-generation-makes-its-parent-live-again ()
  (with-store (store directory)
    (let ((enchiridion.memory:*assertion-deriver* #'test-deriver))
      (write-body store "alpha is beta")
      (let ((first (getf (enchiridion.memory:build-candidate store :limit 10)
                         :generation-id)))
        (enchiridion.memory:promote-generation store first)
        (let ((second (getf (enchiridion.memory:build-candidate store :limit 10)
                            :generation-id)))
          (enchiridion.memory:promote-generation store second)
          (ok (string= "retired" (generation-status-of store first)))
          (enchiridion.memory:rollback-generation store second)
          (testing "the pointer and the parent's status agree"
            (ok (= first (enchiridion.memory:live-generation-id store)))
            (ok (string= "live" (generation-status-of store first)))
            (ok (string= "rolled-back" (generation-status-of store second)))))))))
