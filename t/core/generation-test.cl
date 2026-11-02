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
  (text "[]" :type string)
  (input-tokens 0 :type integer)
  (output-tokens 0 :type integer)
  (last-prompt "" :type string))

(defmethod enchiridion.llm:complete ((backend json-backend) messages
                                     &key model tools budget)
  (declare (ignore model tools budget))
  (setf (json-backend-last-prompt backend)
        (enchiridion.llm:message-content (car (last messages))))
  (enchiridion.llm::%make-completion
   :text (json-backend-text backend)
   :model "json-fake"
   :input-tokens (json-backend-input-tokens backend)
   :output-tokens (json-backend-output-tokens backend)))

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

(deftest a-model-derivation-is-billed-to-the-ledger-and-the-candidate ()
  ;; The deriver used to call the model with nothing recorded, so a T2 pass
  ;; had no cost the budget or the cost gate could see.
  (with-store (store directory)
    (let ((enchiridion.memory:*assertion-deriver*
            (enchiridion.memory:make-model-assertion-deriver
             (make-json-backend :input-tokens 30 :output-tokens 12))))
      (write-body store "alpha is beta")
      (write-body store "gamma is delta")
      (let* ((report (enchiridion.memory:build-candidate store :limit 10))
             (row (first (enchiridion.memory.store:query-rows
                          store "SELECT tokens_used FROM generations WHERE id = ?"
                          (list (getf report :generation-id))))))
        (testing "the batch reports what it spent"
          (ok (= 84 (getf report :tokens))))
        (testing "the candidate carries its cost"
          (ok (= 84 (enchiridion.memory.store:field row "tokens_used"))))
        (testing "the ledger has the spend on the t2 channel"
          (let ((usage (enchiridion.memory.store:usage-total-since
                        store 0 :channel :t2)))
            (ok (= 60 (getf usage :input)))
            (ok (= 24 (getf usage :output)))))))))

(defun ids-of (store table generation &optional (column "id"))
  (mapcar (lambda (row) (enchiridion.memory.store:field row column))
          (enchiridion.memory.store:query-rows
           store (format nil "SELECT ~A FROM ~A WHERE generation_id = ? ORDER BY id"
                         column table)
           (list generation))))

(deftest a-candidate-copies-the-live-layer-and-derives-only-what-is-new ()
  ;; design/memory.md: a candidate copies the live semantic rows, then derives
  ;; episodes not yet processed. Re-deriving the whole log every pass would
  ;; make a pass cost what the log holds, not what it grew by.
  (with-store (store directory)
    (let* ((derived 0)
           (enchiridion.memory:*assertion-deriver*
             (lambda (store episode)
               (incf derived)
               (test-deriver store episode))))
      (write-body store "alpha is beta")
      (write-body store "alpha is beta again")
      (let* ((first (getf (enchiridion.memory:build-candidate store :limit 10)
                          :generation-id))
             (live (ids-of store "assertions" first)))
        ;; A conflict between the two live assertions, so the copy has a
        ;; reference to renumber.
        (enchiridion.memory.store:exec
         store
         "INSERT INTO conflicts (generation_id, kind, left_id, right_id,
                                 detected_ts, basis, run_id)
            VALUES (?, 'test', ?, ?, 0, 'test', 0)"
         (list first (first live) (second live)))
        (enchiridion.memory:promote-generation store first)
        (write-body store "gamma is delta")
        (setf derived 0)
        (let* ((report (enchiridion.memory:build-candidate store :limit 10))
               (second (getf report :generation-id))
               (copied (ids-of store "assertions" second)))
          (testing "only the new episode reaches the deriver"
            (ok (= 1 derived))
            (ok (= 1 (getf report :processed))))
          (testing "the live assertions are copied as rows of their own"
            (ok (= 2 (length copied)))
            (ok (null (intersection copied live))))
          (testing "the copied conflict names the copies, not the live rows"
            (let ((row (first (enchiridion.memory.store:query-rows
                               store "SELECT left_id, right_id FROM conflicts
                                       WHERE generation_id = ?"
                               (list second)))))
              (ok (member (enchiridion.memory.store:field row "left_id") copied))
              (ok (member (enchiridion.memory.store:field row "right_id") copied))))
          (testing "the live generation is untouched"
            (ok (equal live (ids-of store "assertions" first))))
          (testing "the copy counts no writes, so the volume gate sees only new ones"
            (ok (zerop (getf report :assertions)))))))))

(deftest a-rebuild-derives-the-whole-log-again ()
  (with-store (store directory)
    (let* ((derived 0)
           (enchiridion.memory:*assertion-deriver*
             (lambda (store episode)
               (incf derived)
               (test-deriver store episode))))
      (write-body store "alpha is beta")
      (enchiridion.memory:promote-generation
       store (getf (enchiridion.memory:build-candidate store :limit 10) :generation-id))
      (write-body store "gamma is delta")
      (setf derived 0)
      (let ((report (enchiridion.memory:build-candidate store :limit 10 :rebuild t)))
        (ok (= 2 derived))
        (ok (= 1 (length (ids-of store "assertions" (getf report :generation-id)))))))))

;;;; The T2 instruments.

(defun say (store role body &key (session "s") (channel :cli))
  (enchiridion.memory:episode-id
   (enchiridion.memory:write-episode store :session session :role role :body body
                                           :channel channel :derive-p nil)))

(defun canary (family &rest keys &key (name family) (cue "deploy key") (expect "vault")
                                      stale)
  (declare (ignore keys))
  (list :name name :family family :cue cue :expect expect :stale stale))

(deftest canary-coverage-counts-only-valid-families ()
  (let ((enchiridion.memory:*canary-min-families* 4))
    (testing "the four families cover the suite"
      (ok (nth-value 1 (enchiridion.memory:canary-coverage
                        (list (canary "retrieval") (canary "update" :stale "old")
                              (canary "safety") (canary "tail"))))))
    (testing "an update canary with no stale value does not count"
      (ng (nth-value 1 (enchiridion.memory:canary-coverage
                        (list (canary "retrieval") (canary "update")
                              (canary "safety") (canary "tail"))))))
    (testing "a family that is not one of the four does not count"
      (ng (enchiridion.memory:valid-canary-p (canary "vibes"))))))

(deftest a-canary-checks-behaviour-in-the-generation-it-is-given ()
  (with-store (store directory)
    (say store "user" "the deploy key lives in vault under ops")
    (testing "retrieval: the cue brings back the expected text"
      (ok (enchiridion.memory:canary-behaviour-p store (canary "retrieval") nil))
      (ng (enchiridion.memory:canary-behaviour-p
           store (canary "retrieval" :expect "keychain") nil)))
    (testing "safety: the forbidden text never reaches the pack"
      (ok (enchiridion.memory:canary-behaviour-p
           store (canary "safety" :expect "hunter2") nil))
      (ng (enchiridion.memory:canary-behaviour-p store (canary "safety") nil)))
    (testing "update: the new value is there and the stale one does not outrank it"
      (ok (enchiridion.memory:canary-behaviour-p
           store (canary "update" :stale "keychain") nil))
      (ng (enchiridion.memory:canary-behaviour-p
           store (canary "update" :expect "keychain" :stale "vault") nil)))))

(deftest the-canary-table-follows-the-configuration ()
  (with-store (store directory)
    (enchiridion.memory:register-canary store "gone" "anything")
    (ok (= 1 (enchiridion.memory:sync-canaries
              store (list (canary "retrieval" :name "kept") (canary "vibes")))))
    (let ((rows (enchiridion.memory.store:query-rows
                 store "SELECT name, family FROM canary")))
      (ok (= 1 (length rows)))
      (ok (string= "kept" (enchiridion.memory.store:field (first rows) "name")))
      (ok (string= "retrieval" (enchiridion.memory.store:field (first rows) "family"))))))

(deftest utility-tasks-pair-each-question-with-its-answer ()
  (with-store (store directory)
    (let* ((q1 (say store "user" "where is the deploy key"))
           (a1 (say store "assistant" "in vault under ops"))
           (q2 (say store "user" "which port does the api use"))
           (_ (say store "user" "a sleep pass" :channel :sleep))
           (a2 (say store "assistant" "port 9090"))
           (_2 (say store "user" "a question nobody answered"))
           (tasks (enchiridion.memory:utility-tasks store)))
      (declare (ignore _ _2))
      (ok (= 2 (length tasks)))
      (testing "newest first, each cue paired with the reply that followed it"
        (ok (string= "which port does the api use" (getf (first tasks) :cue)))
        (ok (= a2 (getf (first tasks) :expect-episode)))
        (ok (= a1 (getf (second tasks) :expect-episode)))
        (ok (search (princ-to-string q1) (getf (second tasks) :name)))
        (ok (search (princ-to-string q2) (getf (first tasks) :name)))))))

(deftest an-answer-counts-as-recalled-through-its-assertion ()
  (let ((task (list :expect-episode 7)))
    (ok (= 1.0 (enchiridion.memory:answer-scorer
                nil task "" (list (list :item (list :kind "episode" :id 7))))))
    (ok (= 1.0 (enchiridion.memory:answer-scorer
                nil task "" (list (list :item (list :kind "assertion" :id 3
                                                    :episode-id 7))))))
    (ok (= 0.0 (enchiridion.memory:answer-scorer
                nil task "" (list (list :item (list :kind "episode" :id 3))))))))

(deftest the-tail-sample-is-the-questions-with-rare-answers ()
  (with-store (store directory)
    (let ((enchiridion.memory:*tail-rarity-fraction* 0.25)
          (answers '()))
      (dotimes (i 4)
        (say store "user" (format nil "question ~D" i))
        (push (say store "assistant" (format nil "answer ~D" i)) answers))
      ;; Every episode derived; the last answer is the rarest of the eight.
      (enchiridion.memory.store:exec
       store "UPDATE episodes SET derived_ts = 1, rarity_raw = 0.1")
      (enchiridion.memory.store:exec
       store "UPDATE episodes SET rarity_raw = 0.9 WHERE id IN (?, ?)"
       (list (first answers) (second answers)))
      (let ((tail (enchiridion.memory:tail-tasks
                   store (enchiridion.memory:utility-tasks store))))
        (ok (= 2 (length tail)))
        (ok (subsetp (mapcar (lambda (task) (getf task :expect-episode)) tail)
                     (list (first answers) (second answers))))))))

(deftest a-pass-without-its-instruments-is-told-what-is-missing ()
  (with-store (store directory)
    (testing "an empty store with no deriver lacks all four"
      (let ((enchiridion.memory:*assertion-deriver* nil))
        (let ((report (enchiridion.memory:t2-preflight store :canaries '())))
          (ng (getf report :ready-p))
          (ok (eq :instrument-missing (getf report :reason)))
          (ok (equal '(:deriver :canary-coverage :utility-task-set :tail-sampler)
                     (getf report :missing))))))
    (testing "with every instrument present the pass is ready"
      (let ((enchiridion.memory:*assertion-deriver* #'test-deriver)
            (enchiridion.memory:*canary-min-families* 4)
            (enchiridion.memory::*memory-gate-min-n* 2)
            (enchiridion.memory:*tail-min-n* 1)
            (enchiridion.memory:*tail-rarity-fraction* 0.5))
        (dotimes (i 2)
          (say store "user" (format nil "question ~D" i))
          (say store "assistant" (format nil "answer ~D" i)))
        (enchiridion.memory.store:exec
         store "UPDATE episodes SET derived_ts = 1, rarity_raw = 0.1 WHERE role = 'user'")
        (enchiridion.memory.store:exec
         store "UPDATE episodes SET derived_ts = 1, rarity_raw = 0.9 WHERE role = 'assistant'")
        (let ((report (enchiridion.memory:t2-preflight
                       store :canaries (list (canary "retrieval") (canary "update" :stale "x")
                                             (canary "safety") (canary "tail")))))
          (ok (getf report :ready-p))
          (ok (null (getf report :missing))))))))

;;;; The promotion gates.

(defun check-rows (store generation)
  (mapcar (lambda (row) (list (enchiridion.memory.store:field row "kind")
                              (enchiridion.memory.store:field row "result")))
          (enchiridion.memory.store:query-rows
           store "SELECT kind, result FROM generation_checks WHERE generation_id = ?
                   ORDER BY id"
           (list generation))))

(defun status-of (store generation)
  (enchiridion.memory.store:field
   (first (enchiridion.memory.store:query-rows
           store "SELECT status, quarantine_reason FROM generations WHERE id = ?"
           (list generation)))
   "status"))

(defun passing-canaries ()
  (list (canary "retrieval" :cue "alpha" :expect "alpha")
        (canary "update" :cue "alpha" :expect "beta" :stale "zzz")
        (canary "safety" :cue "alpha" :expect "hunter2")
        (canary "tail" :cue "alpha" :expect "beta")))

(defun assertion-scorer (store task pushed rows)
  "Score 1 when the retrieval brought back an assertion: only the candidate
arm can, so the candidate wins every pair."
  (declare (ignore store task pushed))
  (if (some (lambda (row) (equal "assertion" (getf (getf row :item) :kind))) rows)
      1.0 0.0))

(defmacro with-gate-world ((store directory generation) &body body)
  "Five answered questions whose wording the test deriver turns into an
assertion, built into one candidate, with the gate thresholds small enough
for five tasks."
  `(with-store (,store ,directory)
     (let ((enchiridion.memory:*assertion-deriver* #'test-deriver)
           (enchiridion.memory:*canary-min-families* 4)
           (enchiridion.memory::*memory-gate-min-n* 5)
           (enchiridion.memory:*tail-min-n* 1)
           (enchiridion.memory:*tail-rarity-fraction* 1.0))
       (dotimes (i 5)
         (say ,store "user" (format nil "question ~D: alpha is beta" i))
         (say ,store "assistant" (format nil "answer ~D" i)))
       (enchiridion.memory.store:exec ,store "UPDATE episodes SET derived_ts = 1")
       (let ((,generation (getf (enchiridion.memory:build-candidate ,store :limit 100)
                                :generation-id)))
         ,@body))))

(deftest an-unsourced-assertion-is-quarantined-at-provenance ()
  (with-gate-world (store directory generation)
    (enchiridion.memory.store:exec
     store "UPDATE assertions SET span_end = 9999 WHERE generation_id = ?" (list generation))
    (let ((report (enchiridion.memory:gate-candidate
                   store generation :canaries (passing-canaries) :scorer #'assertion-scorer)))
      (ng (getf report :promoted))
      (ok (string= "provenance" (getf report :failed)))
      (ok (string= "quarantined" (status-of store generation)))
      (ok (zerop (enchiridion.memory:live-generation-id store)))
      (ok (equal '(("provenance" "fail")) (check-rows store generation))))))

(deftest an-unchecked-canary-suite-stops-the-gates-before-anything-is-measured ()
  (with-gate-world (store directory generation)
    (let ((report (enchiridion.memory:gate-candidate
                   store generation :canaries '() :scorer #'assertion-scorer)))
      (ok (string= "canary" (getf report :failed)))
      (ok (equal '(("provenance" "pass") ("canary" "fail")) (check-rows store generation)))
      (testing "the utility arms never ran"
        (ok (null (enchiridion.memory:paired-outcomes store generation)))))))

(deftest a-candidate-that-passes-every-gate-is-promoted ()
  (with-gate-world (store directory generation)
    (let ((report (enchiridion.memory:gate-candidate
                   store generation :canaries (passing-canaries) :scorer #'assertion-scorer)))
      (ok (getf report :promoted))
      (ok (= generation (enchiridion.memory:live-generation-id store)))
      (ok (string= "live" (status-of store generation)))
      (ok (equal '(("provenance" "pass") ("canary" "pass") ("utility" "pass")
                   ("tail" "pass") ("cost" "pass"))
                 (check-rows store generation)))
      (testing "a generation is gated once"
        (ok (eq :not-a-candidate
                (getf (enchiridion.memory:gate-candidate store generation) :reason)))))))

(deftest a-failed-post-promotion-check-rolls-the-promotion-back ()
  (with-gate-world (store directory generation)
    (enchiridion.memory:gate-candidate
     store generation :canaries (passing-canaries) :scorer #'assertion-scorer)
    (testing "a check that still holds keeps it live"
      (ok (getf (enchiridion.memory:check-promoted
                 store generation :canaries (passing-canaries) :scorer #'assertion-scorer)
                :held)))
    (let ((report (enchiridion.memory:check-promoted
                   store generation
                   :canaries (cons (canary "safety" :name "leak" :cue "alpha" :expect "alpha")
                                   (passing-canaries))
                   :scorer #'assertion-scorer)))
      (ng (getf report :held))
      (ok (string= "post-canary" (getf report :failed)))
      (ok (zerop (enchiridion.memory:live-generation-id store)))
      (ok (string= "rolled-back" (status-of store generation))))))

;;;; The semantic layer is findable.

(defun context-deriver (store episode)
  "Derive \"serviceN secret kept in vaultN\" from an answer, taking the
subject from the question before it, the way the model deriver is asked to."
  (let* ((body (enchiridion.memory:episode-body episode))
         (context (enchiridion.memory::previous-episode-body store episode))
         (service (and context (search "service" context)))
         (vault (search "vault" body)))
    (if (and service vault)
        (let ((n (char context (+ service 7))))
          (values (list (enchiridion.memory:make-assertion
                         :subject (format nil "service~C secret" n)
                         :relation "kept in"
                         :object (format nil "vault~C" n)
                         :episode-id (enchiridion.memory:episode-id episode)
                         :span-start vault :span-end (+ vault 6)
                         :valid-from 100 :provenance "agent" :authority 3))
                  nil))
        (values nil nil))))

(defun answered-questions (store count)
  "Write COUNT questions whose answers share none of their words."
  (dotimes (i count)
    (say store "user" (format nil "where does service~D keep its secret" i))
    (say store "assistant" (format nil "in vault~D under ops" i))))

(deftest a-claim-is-found-by-words-its-episode-never-used ()
  (with-store (store directory)
    (let ((enchiridion.memory:*assertion-deriver* #'context-deriver))
      (answered-questions store 1)
      (let ((generation (getf (enchiridion.memory:build-candidate store :limit 10)
                              :generation-id)))
        (testing "the answer episode alone does not match the question"
          (ok (null (enchiridion.memory:answer-hit-p
                     (enchiridion.memory:retrieve-rows-for-turn
                      store "where does service0 keep its secret" :generation nil)
                     2))))
        (testing "its claim does, through the claim route"
          (let ((hits (enchiridion.memory:assertion-candidates-for
                       store "service0 secret" :generation generation)))
            (ok (= 1 (length hits)))
            (ok (equal '(0) (getf (first hits) :route-ranks)))))))))

(deftest a-retrieval-with-no-assertions-is-ranked-as-before ()
  (let ((episodes (list (list :kind "episode" :id 1 :lexical 3.0)
                        (list :kind "episode" :id 2 :lexical 1.0))))
    (ok (eq episodes (enchiridion.memory::fuse-semantic-candidates episodes '())))
    (ok (= 3.0 (getf (first episodes) :lexical)))))

(deftest the-deriver-is-shown-the-turn-before-the-record ()
  (with-store (store directory)
    (say store "user" "where does service4 keep its secret")
    (let* ((answer (enchiridion.memory:write-episode
                    store :session "s" :role "assistant" :body "in vault4 under ops"
                          :derive-p nil))
           (backend (make-json-backend))
           (deriver (enchiridion.memory:make-model-assertion-deriver backend)))
      (funcall deriver store answer)
      (let ((prompt (json-backend-last-prompt backend)))
        (ok (search "where does service4 keep its secret" prompt))
        (ok (< (search "service4" prompt) (search "in vault4 under ops" prompt)))))))

(deftest a-candidate-that-adds-recall-passes-the-real-utility-gate ()
  ;; No stub scorer: the answers share no word with their questions, so the
  ;; log alone recalls none of them, and the candidate's claims recall all.
  (with-store (store directory)
    (let ((enchiridion.memory:*assertion-deriver* #'context-deriver)
          (enchiridion.memory:*canary-min-families* 4)
          (enchiridion.memory::*memory-gate-min-n* 5)
          (enchiridion.memory:*tail-min-n* 1)
          (enchiridion.memory:*tail-rarity-fraction* 1.0))
      (answered-questions store 6)
      (enchiridion.memory.store:exec store "UPDATE episodes SET derived_ts = 1")
      (let* ((generation (getf (enchiridion.memory:build-candidate store :limit 100)
                               :generation-id))
             (report (enchiridion.memory:gate-candidate
                      store generation
                      :canaries (list (canary "retrieval" :cue "service1 secret" :expect "vault1")
                                      (canary "update" :cue "service2 secret"
                                                       :expect "vault2" :stale "zzz")
                                      (canary "safety" :cue "service1 secret" :expect "hunter2")
                                      (canary "tail" :cue "service3 secret" :expect "vault3")))))
        (ok (getf report :promoted))
        (multiple-value-bind (pass utility) (enchiridion.memory:utility-gate store generation)
          (ok pass)
          (ok (= 6 (getf utility :wins))))
        (ok (= generation (enchiridion.memory:live-generation-id store)))))))

;;;; The autonomy controls.

(defun gated-generation (store result &key (promoted nil))
  "Insert a generation the gates decided RESULT for, and return its id."
  (enchiridion.memory.store:exec
   store
   "INSERT INTO generations (number, status, created_ts, promotion_result,
                             promotion_checked_ts, promoted_ts)
      VALUES ((SELECT COALESCE(MAX(number), 0) + 1 FROM generations), ?, 0, ?, 0, ?)"
   (list (if promoted "retired" result) result (and promoted 1)))
  (enchiridion.memory.store:last-row-id store))

(defun post-check (store generation canary utility)
  (dolist (pair (list (cons "post-canary" canary) (cons "post-utility" utility)))
    (when (cdr pair)
      (enchiridion.memory.store:exec
       store "INSERT INTO generation_checks (generation_id, kind, result, ts)
                VALUES (?, ?, ?, 0)"
       (list generation (car pair) (cdr pair))))))

(deftest the-quarantine-freeze-waits-for-enough-candidates ()
  (with-store (store directory)
    (dotimes (i 4) (gated-generation store "quarantined"))
    (testing "four quarantines are not yet a rate"
      (ng (enchiridion.memory:quarantine-frozen-p store))
      (ok (= enchiridion.memory:*t2-interval-seconds*
             (enchiridion.memory:t2-interval store))))
    (gated-generation store "quarantined")
    (testing "the fifth freezes promotion and slows T2 to the frozen interval"
      (ok (eq :quarantine-rate (enchiridion.memory:promotion-freeze store)))
      (ok (= enchiridion.memory:*t2-frozen-interval-seconds*
             (enchiridion.memory:t2-interval store))))
    (dotimes (i 6) (gated-generation store "held"))
    (testing "held candidates passed every gate, so they bring the rate down"
      (ok (= 5/11 (getf (enchiridion.memory:quarantine-rate store) :rate)))
      (ng (enchiridion.memory:promotion-freeze store)))))

(deftest a-precision-freeze-holds-until-the-operator-resets-it ()
  (with-store (store directory)
    (dotimes (i 5)
      (post-check store (gated-generation store "promoted" :promoted t)
                  "pass" (if (< i 3) "pass" "fail")))
    (let ((unchecked (gated-generation store "promoted" :promoted t)))
      (declare (ignore unchecked)))
    (testing "three of five checked promotions held: 0.6 is under 0.8"
      (let ((report (enchiridion.memory:promotion-precision store)))
        (ok (= 5 (getf report :checked)))
        (ok (= 3/5 (getf report :precision))))
      (ok (eq :precision (enchiridion.memory:promotion-freeze store))))
    (enchiridion.memory:reset-promotion-precision store)
    (testing "the reset starts the count afresh"
      (ok (zerop (getf (enchiridion.memory:promotion-precision store) :checked)))
      (ng (enchiridion.memory:promotion-freeze store)))))

(deftest a-candidate-that-passes-during-a-freeze-is-held ()
  (with-gate-world (store directory generation)
    (dotimes (i 5) (gated-generation store "quarantined"))
    (let ((report (enchiridion.memory:gate-candidate
                   store generation :canaries (passing-canaries)
                                    :scorer #'assertion-scorer)))
      (ng (getf report :promoted))
      (ok (eq :held (getf report :reason)))
      (ok (eq :quarantine-rate (getf report :freeze)))
      (ok (string= "held" (status-of store generation)))
      (ok (zerop (enchiridion.memory:live-generation-id store)))
      (testing "and it counts toward the rate as a pass"
        (ok (= 5/6 (getf (enchiridion.memory:quarantine-rate store) :rate)))))))
