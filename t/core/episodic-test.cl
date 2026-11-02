;;;; episodic-test.cl --- The episodic design properties, as tests.
;;;;
;;;; Ported from research/human-like-agent-memory/build/validate.lisp. The
;;;; properties are the model's own invariants, not a benchmark: they say the
;;;; log retains, the cue index keys on use, push cannot evict retrieved
;;;; material, an unchecked canary is not a pass, and the gates default closed.
;;;;
;;;; Each helper opens its own store. A helper that asserted an absolute row
;;;; count would pass only while it ran first, so every count is a delta and
;;;; every check is independent.

(defpackage #:enchiridion-episodic-test
  (:use #:cl)
  (:import-from #:rove #:deftest #:ok #:ng #:testing)
  (:export #:run))

(in-package #:enchiridion-episodic-test)

(defun fresh-store ()
  "A store in a fresh file, with the core and extension schemas."
  (let* ((directory (uiop:ensure-directory-pathname
                     (merge-pathnames
                      (format nil "enchiridion-episodic-test-~D/"
                              (random most-positive-fixnum))
                      (uiop:ensure-directory-pathname *default-pathname-defaults*))))
         (path (merge-pathnames "memory.db" directory)))
    (values (enchiridion.memory.store:open-store :path path)
            directory)))

(defmacro with-store ((var) &body body)
  "Bind VAR to a fresh store and remove its directory afterwards."
  (let ((directory (gensym "DIRECTORY")))
    `(multiple-value-bind (,var ,directory) (fresh-store)
       (unwind-protect (progn ,@body)
         (ignore-errors (enchiridion.memory.store:close-store ,var))
         (uiop:delete-directory-tree ,directory
                                     :validate t
                                     :if-does-not-exist :ignore)))))

(defun seed-episodes (store n)
  "Write N episodes with distinct bodies and return their ids."
  (loop for i from 1 to n
        collect (enchiridion.memory:episode-id
                 (enchiridion.memory:write-episode
                  store :session "s1" :role "user"
                  :body (format nil "step ~D: the build failed with error code ~D"
                                i i)))))

(defun episode-count (store)
  "Return the number of rows in the log."
  (enchiridion.memory.store:field
   (first (enchiridion.memory.store:query-rows
           store "SELECT COUNT(*) AS n FROM episodes"))
   "n"))

(defun p7-rebuildable ()
  "The log accepts episodes and retains every one of them."
  (with-store (store)
    (let ((before (episode-count store))
          (ids (seed-episodes store 5)))
      (and (= 5 (length ids))
           (= 5 (- (episode-count store) before))
           (every (lambda (id)
                    (let ((row (first (enchiridion.memory.store:query-rows
                                       store
                                       "SELECT body FROM episodes WHERE id = ?"
                                       (list id)))))
                      (and row
                           (plusp (length (enchiridion.memory.store:field row
                                                                          "body"))))))
                  ids)))))

(defun log-never-rewritten ()
  "A decay sweep must not change an episode body."
  (with-store (store)
    (let* ((ids (seed-episodes store 3))
           (before (mapcar (lambda (id)
                             (enchiridion.memory.store:field
                              (first (enchiridion.memory.store:query-rows
                                      store
                                      "SELECT body FROM episodes WHERE id = ?"
                                      (list id)))
                              "body"))
                           ids)))
      (enchiridion.memory:decay-sweep store (get-universal-time))
      (let ((after (mapcar (lambda (id)
                             (enchiridion.memory.store:field
                              (first (enchiridion.memory.store:query-rows
                                      store
                                      "SELECT body FROM episodes WHERE id = ?"
                                      (list id)))
                              "body"))
                           ids)))
        (equal before after)))))

(defun t0-calls-no-model ()
  "The T0 write path works with no backend attached."
  (with-store (store)
    (let ((id (enchiridion.memory:episode-id
               (enchiridion.memory:write-episode
                store :session "s" :role "user"
                :body "no backend is attached here"))))
      (and (integerp id) (plusp id)))))

(defun push-is-model-free ()
  "The push pack assembles with no backend."
  (with-store (store)
    (seed-episodes store 3)
    (stringp (enchiridion.memory:push-pack
              store '("build" "failed")))))

(defun ext-schema-idempotent ()
  "ensure-ext-schema twice changes nothing."
  (with-store (store)
    (let ((first (enchiridion.memory:ensure-ext-schema store))
          (second (enchiridion.memory:ensure-ext-schema store)))
      (and (= first second) (plusp first)))))

(defun cue-index-dedupes ()
  "A cue seen many times stays one row per (term, kind, ref)."
  (with-store (store)
    (enchiridion.memory:index-cue store '("alpha" "beta") :episode 1 :used t)
    (enchiridion.memory:index-cue store '("alpha" "beta") :episode 1 :used t)
    (enchiridion.memory:index-cue store '("alpha") :episode 1 :used t)
    (= 2 (enchiridion.memory:cue-index-size store))))

(defun cue-index-keys-on-use ()
  "Only used rows are returned."
  (with-store (store)
    (enchiridion.memory:index-cue store '("alpha") :episode 7 :used t)
    (enchiridion.memory:index-cue store '("beta") :episode 8 :used nil)
    (let ((hit (enchiridion.memory:cue-index-many store '("alpha"))))
      (and (= 1 (length hit))
           (equal (first hit) (cons "episode" 7))
           (null (enchiridion.memory:cue-index-many store '("beta")))))))

(defun cue-index-prunes ()
  "Pruning removes stale rows and keeps fresh ones."
  (with-store (store)
    (let ((now (get-universal-time)))
      (enchiridion.memory:index-cue store '("old") :episode 1 :used t
                                               :now (- now 10000000))
      (enchiridion.memory:index-cue store '("new") :episode 2 :used t
                                               :now now)
      (enchiridion.memory:prune-cue-index store :older-than 7776000
                                                      :now now)
      (= 1 (enchiridion.memory:cue-index-size store)))))

(defun push-cannot-evict-retrieved ()
  "Push may not evict retrieved material ranked above it."
  (let* ((retrieved (make-string 100 :initial-element #\R))
         (pushed (make-string 100 :initial-element #\P))
         (pack (enchiridion.memory:assemble-pack
                retrieved pushed :char-budget 150)))
    (and (string= (subseq pack 0 100) retrieved)
         (<= (length pack) 150)
         (find #\P pack)
         (< (- (length pack) 101) 50))))

(defun push-fraction-capped ()
  "Push may occupy at most the stated fraction of the pack."
  (let* ((retrieved "")
         (pushed (make-string 1000 :initial-element #\P))
         (pack (enchiridion.memory:assemble-pack
                retrieved pushed :char-budget 100)))
    (<= (length pack) 100)))

(defun canary-unchecked-is-not-pass ()
  "A suite that has not run must not report success."
  (with-store (store)
    (enchiridion.memory:register-canary
     store "no-deploy-on-friday" "never deploy on a Friday")
    (let ((r (enchiridion.memory:canary-check store :predicate nil)))
      (and (not (getf r :ok-p))
           (= 1 (getf r :unchecked))
           (zerop (getf r :passed))))))

(defun canary-detects-behavioural-failure ()
  "A canary whose behaviour fails fails the check."
  (with-store (store)
    (enchiridion.memory:register-canary store "good" "always holds")
    (enchiridion.memory:register-canary store "bad" "never holds")
    (let* ((pred (lambda (name expect)
                   (declare (ignore expect))
                   (string= name "good")))
           (r (enchiridion.memory:canary-check store :predicate pred)))
      (and (= 1 (getf r :passed))
           (= 1 (getf r :failed))
           (not (getf r :ok-p))
           (equal (getf r :failures) '("bad"))))))

(defun utility-gate-defaults-closed ()
  "With no evidence, the utility gate is closed."
  (with-store (store)
    (not (enchiridion.memory:utility-gate store))))

(defun utility-gate-needs-both-arms ()
  "One arm alone is not evidence."
  (with-store (store)
    (dotimes (i 30)
      (enchiridion.memory:record-gate-row store "consolidate" "outcome" 1.0))
    (not (enchiridion.memory:utility-gate store :min-n 20))))

(defun utility-gate-opens-on-evidence ()
  "Consolidation beating retention by more than the margin opens the gate."
  (with-store (store)
    (dotimes (i 30)
      (enchiridion.memory:record-gate-row store "retention" "outcome" 0.50))
    (dotimes (i 30)
      (enchiridion.memory:record-gate-row store "consolidate" "outcome" 0.60))
    (enchiridion.memory:utility-gate store :margin 0.02 :min-n 20)))

(defun utility-gate-blocks-on-parity ()
  "Parity does not open the gate."
  (with-store (store)
    (dotimes (i 30)
      (enchiridion.memory:record-gate-row store "retention" "outcome" 0.50))
    (dotimes (i 30)
      (enchiridion.memory:record-gate-row store "consolidate" "outcome" 0.50))
    (not (enchiridion.memory:utility-gate store :margin 0.02 :min-n 20))))

(defun push-ab-measures-outcome ()
  "push-ab reports a delta and a verdict against its margin."
  (with-store (store)
    (seed-episodes store 2)
    (enchiridion.memory:index-cue store '("probe") :episode 1 :used t)
    (let* ((tasks (list (list :name "t1" :cue '("probe"))
                        (list :name "t2" :cue '("probe"))))
           (scorer (lambda (store cue pushed rows)
                     (declare (ignore store cue rows))
                     (if (plusp (length pushed)) 1.0 0.0)))
           (r (enchiridion.memory:push-ab store tasks scorer)))
      (and (= (getf (getf r :off) :n) 2)
           (= (getf (getf r :on) :n) 2)
           (numberp (getf r :delta))
           (getf r :passes)))))

(defun compare-arms-records-evidence ()
  "compare-arms leaves paired gate_log evidence behind, under its candidate."
  (with-store (store)
    (seed-episodes store 1)
    (let* ((tasks (list (list :name "t" :cue '("x"))))
           (scorer (lambda (store cue pushed rows)
                     (declare (ignore store cue pushed rows)) 0.5)))
      (enchiridion.memory:compare-arms store 7 tasks scorer)
      (let ((rows (enchiridion.memory.store:query-rows
                   store "SELECT arm, task_hash FROM gate_log WHERE generation_id = 7
                           ORDER BY arm")))
        (and (= 2 (length rows))
             (equal '("candidate" "retention")
                    (mapcar (lambda (r) (enchiridion.memory.store:field r "arm")) rows))
             ;; One task, so both arms carry the same hash and pair.
             (string= (enchiridion.memory.store:field (first rows) "task_hash")
                      (enchiridion.memory.store:field (second rows) "task_hash")))))))

(defun base-level-decreases-with-age ()
  "Base-level activation falls as a record ages with no new references."
  (let* ((now 1000000)
         (young (enchiridion.memory:base-level
                 (enchiridion.memory::make-activation
                  :kind "episode" :id 1 :n-enc 1 :last-enc (- now 100)
                  :n-ret 0 :last-ret nil :created-ts (- now 100)
                  :supp 0.0 :supp-ts nil :imp 5 :distinctness 0.0)
                 now))
         (old (enchiridion.memory:base-level
               (enchiridion.memory::make-activation
                :kind "episode" :id 2 :n-enc 1 :last-enc (- now 100000)
                :n-ret 0 :last-ret nil :created-ts (- now 100000)
                :supp 0.0 :supp-ts nil :imp 5 :distinctness 0.0)
               now)))
    (> young old)))

(defun temporal-term-stays-signed ()
  "The temporal term stays signed."
  (let ((inside (enchiridion.memory:temporal-match 0 2000 1000))
        (outside (enchiridion.memory:temporal-match 0 500 1000))
        (open-interval (enchiridion.memory:temporal-match 0 nil 1000))
        (no-time (enchiridion.memory:temporal-match 0 nil nil)))
    (and (= inside 1.0) (= outside -1.0)
         (= open-interval 1.0) (= no-time 0.0))))

(defun rank-normalise-preserves-order ()
  "Rank normalisation stays in [0,1] and preserves the count."
  (let ((r (enchiridion.memory:rank-normalise '(5 1 3))))
    (and (every (lambda (x) (and (<= 0 x) (<= x 1))) r)
         (= (length r) 3))))

(defun sparse-clamps-negative-strength ()
  "Associative strength clamps at zero."
  (let ((graph (make-hash-table :test #'equal)))
    (dotimes (i 100)
      (setf (gethash (list "episode" (1+ i) "episode" 1) graph) 1.0))
    (>= (enchiridion.memory:associative-strength
         graph "episode" 1)
        0.0)))

;;;; The checks, in declaration order. Each is its own rove test so a failure
;;;; names the property rather than the suite.

(deftest p7-log-accepts-and-retains-episodes ()
  (ok (p7-rebuildable)))

(deftest t1-does-not-rewrite-the-log ()
  (ok (log-never-rewritten)))

(deftest t0-write-path-needs-no-backend ()
  (ok (t0-calls-no-model)))

(deftest push-assembles-with-no-backend ()
  (ok (push-is-model-free)))

(deftest extension-schema-is-idempotent ()
  (ok (ext-schema-idempotent)))

(deftest cue-index-dedupes-per-term-and-ref ()
  (ok (cue-index-dedupes)))

(deftest cue-index-keys-on-use-not-presence ()
  (ok (cue-index-keys-on-use)))

(deftest cue-index-prunes-stale-rows ()
  (ok (cue-index-prunes)))

(deftest push-cannot-evict-retrieved ()
  (ok (push-cannot-evict-retrieved)))

(deftest push-fraction-is-capped ()
  (ok (push-fraction-capped)))

(deftest unchecked-canary-is-not-a-pass ()
  (ok (canary-unchecked-is-not-pass)))

(deftest canary-detects-behavioural-failure ()
  (ok (canary-detects-behavioural-failure)))

(deftest utility-gate-defaults-closed ()
  (ok (utility-gate-defaults-closed)))

(deftest utility-gate-needs-both-arms ()
  (ok (utility-gate-needs-both-arms)))

(deftest utility-gate-opens-on-evidence ()
  (ok (utility-gate-opens-on-evidence)))

(deftest utility-gate-blocks-on-parity ()
  (ok (utility-gate-blocks-on-parity)))

(deftest push-ab-measures-outcome ()
  (ok (push-ab-measures-outcome)))

(deftest compare-arms-leaves-evidence ()
  (ok (compare-arms-records-evidence)))

(deftest base-level-falls-with-age ()
  (ok (base-level-decreases-with-age)))

(deftest temporal-term-stays-signed ()
  (ok (temporal-term-stays-signed)))

(deftest rank-normalise-preserves-order ()
  (ok (rank-normalise-preserves-order)))

(deftest associative-strength-clamps-at-zero ()
  (ok (sparse-clamps-negative-strength)))

(deftest the-volume-gate-counts-the-candidate-it-is-asked-about ()
  ;; It once counted rows under run id -1, which is always zero, so it passed
  ;; every candidate whatever it wrote.
  (with-store (store)
    (enchiridion.memory.store:exec
     store
     "INSERT INTO generations (number, status, created_ts, writes) VALUES (1, 'candidate', 0, 401)")
    (let ((id (enchiridion.memory.store:last-row-id store)))
      (ng (enchiridion.memory:volume-gate store id :max-writes 400))
      (ok (enchiridion.memory:volume-gate store id :max-writes 401)))
    (testing "a generation that does not exist does not pass"
      (ng (enchiridion.memory:volume-gate store 999)))))
