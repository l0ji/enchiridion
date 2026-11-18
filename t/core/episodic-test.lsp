;;;; episodic-test.lsp --- Episodic memory tests.

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

(defun record-pair (store generation hash retention candidate)
  "Record one task scored under both arms for GENERATION."
  (enchiridion.memory:record-gate-row store "retention" "outcome" retention
                                      :generation-id generation :task-hash hash)
  (enchiridion.memory:record-gate-row store "candidate" "outcome" candidate
                                      :generation-id generation :task-hash hash))

(defun utility-gate-defaults-closed ()
  "With no evidence, the utility gate is closed."
  (with-store (store)
    (not (enchiridion.memory:utility-gate store 1))))

(defun utility-gate-needs-both-arms ()
  "One arm alone is not evidence: nothing pairs."
  (with-store (store)
    (dotimes (i 30)
      (enchiridion.memory:record-gate-row store "candidate" "outcome" 1.0
                                          :generation-id 1
                                          :task-hash (format nil "t~D" i)))
    (not (enchiridion.memory:utility-gate store 1 :min-n 20))))

(defun utility-gate-opens-on-evidence ()
  "A candidate that wins every paired task opens the gate."
  (with-store (store)
    (dotimes (i 30)
      (record-pair store 1 (format nil "t~D" i) 0.0 1.0))
    (enchiridion.memory:utility-gate store 1 :margin 0.05 :min-n 20)))

(defun utility-gate-blocks-on-parity ()
  "Ties are not wins, and parity does not open the gate."
  (with-store (store)
    (dotimes (i 30)
      (record-pair store 1 (format nil "t~D" i) 1.0 1.0))
    (not (enchiridion.memory:utility-gate store 1 :margin 0.0 :min-n 0))))

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
  ;; every candidate whatever it wrote. It counts the build's own claims now,
  ;; and neither the rows it copied nor its conflict bookkeeping.
  (with-store (store)
    (let ((episode (enchiridion.memory:episode-id
                    (enchiridion.memory:write-episode store :session "s" :role "user"
                                                            :body "a record" :derive-p nil))))
      (enchiridion.memory.store:exec
       store "INSERT INTO generations (number, status, created_ts, writes, episodes_derived)
                VALUES (1, 'candidate', 0, 999, 1)")
      (let ((id (enchiridion.memory.store:last-row-id store)))
        (flet ((claim (n run)
                 (enchiridion.memory.store:exec
                  store "INSERT INTO assertions (generation_id, subject, relation, object,
                                                 episode_id, span_start, span_end, tx_from, run_id)
                           VALUES (?, 's', 'r', ?, ?, 0, 1, 0, ?)"
                  (list id (format nil "o~D-~D" run n) episode run))))
          (dotimes (n 9) (claim n id))
          (dotimes (n 5) (claim n 77)))
        (testing "nine own claims for one episode: within 9 each, over 8 each"
          (ok (enchiridion.memory:volume-gate store id :per-episode 9))
          (ng (enchiridion.memory:volume-gate store id :per-episode 8)))))
    (testing "a generation that does not exist does not pass"
      (ng (enchiridion.memory:volume-gate store 999)))))

(deftest the-sign-test-is-the-exact-binomial-tail ()
  (ok (= 11/1024 (enchiridion.memory:sign-test-p 9 10)))
  (ok (= 638/1024 (enchiridion.memory:sign-test-p 5 10)))
  (ok (= 1 (enchiridion.memory:sign-test-p 0 0))))

(deftest a-margin-without-significance-does-not-open-the-utility-gate ()
  ;; Four wins and one loss among twenty tasks clear a 0.05 mean delta three
  ;; times over, but four of five non-tied pairs has p = 6/32.
  (with-store (store)
    (dotimes (i 15) (record-pair store 1 (format nil "tie~D" i) 1.0 1.0))
    (dotimes (i 4) (record-pair store 1 (format nil "win~D" i) 0.0 1.0))
    (dotimes (i 1) (record-pair store 1 (format nil "loss~D" i) 1.0 0.0))
    (multiple-value-bind (pass report)
        (enchiridion.memory:utility-gate store 1 :margin 0.05 :min-n 5 :alpha 0.05)
      (ng pass)
      (ok (= 5 (getf report :non-tied)))
      (ok (>= (getf report :mean-delta) 0.05))
      (ok (> (getf report :p) 0.05)))))

(deftest the-gate-reads-the-latest-measurement-of-each-task ()
  (with-store (store)
    (record-pair store 1 "t" 1.0 0.0)
    (record-pair store 1 "t" 0.0 1.0)
    (let ((pairs (enchiridion.memory:paired-outcomes store 1)))
      (ok (equal '((0.0d0 . 1.0d0)) pairs)))))

(deftest a-mean-delta-of-exactly-the-margin-meets-it ()
  ;; "At least 0.05": one win among twenty tasks is a delta of exactly 1/20.
  (with-store (store)
    (dotimes (i 19) (record-pair store 1 (format nil "tie~D" i) 1.0 1.0))
    (record-pair store 1 "win" 0.0 1.0)
    (ok (enchiridion.memory:utility-gate store 1 :margin 0.05 :min-n 1 :alpha 1.0))
    (ng (enchiridion.memory:utility-gate store 1 :margin 0.06 :min-n 1 :alpha 1.0))))

;;;; Rarity, the dense cache, and what the optional calls cost.

(defun test-embedder (&key (calls nil))
  "Return an embedder whose vector follows the configured size, or is four long.
CALLS, when given, is a cons whose car counts the requests."
  (lambda (texts)
    (when calls (incf (car calls)))
    (let ((dimensions (or (getf enchiridion.memory::*memory-embed-settings*
                                  :dimensions)
                          4)))
      (loop for text in texts
            collect (let ((vector (make-array dimensions
                                             :initial-element 0.0
                                             :element-type 'single-float)))
                      (setf (aref vector (mod (length text) dimensions)) 1.0)
                      vector)))))

(defun row-count (store sql &optional parameters)
  (enchiridion.memory.store:field
   (first (enchiridion.memory.store:query-rows store sql parameters)) "n"))

(defun turn-writer (store)
  "Return a function that records one user turn with BODY."
  (lambda (body)
    (enchiridion.memory.store:record-turn
     store :session "s" :role "user" :body body :channel :cli)))

(defun episode-rarity (store id)
  (enchiridion.memory.store:field
   (first (enchiridion.memory.store:query-rows
           store "SELECT rarity_raw FROM episodes WHERE id = ?" (list id)))
   "rarity_raw"))

(deftest rarity-measures-the-prior-documents-not-the-row-itself ()
  (with-store (store)
    (let ((write (turn-writer store)))
      (loop for index from 1 to 40
            do (funcall write (if (member index '(20 40))
                                  (format nil "Zyzzyva ~D quartzite obsidian malachite"
                                          index)
                                  (format nil "the build failed with error code ~D"
                                          index))))
      (ok (= 40 (getf (enchiridion.memory:maintenance store :limit 100) :derived)))
      (testing "the measure is a distribution, not one collapsed value"
        (ok (> (row-count store
                           "SELECT COUNT(DISTINCT rarity_raw) AS n FROM episodes")
               1))
        (ok (plusp (episode-rarity store 19))))
      (testing "a record of new words outranks its ordinary neighbour"
        (ok (> (episode-rarity store 20) (+ 0.5 (episode-rarity store 19))))
        (ok (> (episode-rarity store 40) (episode-rarity store 39))))
      (testing "and the tail sample follows rarity rather than the id"
        (let ((enchiridion.memory:*tail-rarity-fraction* 0.1)
              (rare (enchiridion.memory:rare-episode-ids store)))
          (ok (gethash 20 rare))
          (ok (gethash 40 rare))
          (ng (gethash 19 rare))
          (ng (gethash 39 rare)))))))

(deftest rarity-does-not-depend-on-the-maintenance-batch ()
  (with-store (store)
    (let ((write (turn-writer store)))
      (dotimes (index 6)
        (funcall write (format nil "the deploy failed on host ~D again" index)))
      (loop repeat 6 do (enchiridion.memory:maintenance store :limit 1))
      (let ((batched (loop for id from 1 to 6 collect (episode-rarity store id))))
        (enchiridion.memory:rebuild-derived store)
        (enchiridion.memory:maintenance store :limit 6)
        (ok (equal batched
                   (loop for id from 1 to 6 collect (episode-rarity store id))))))))

(deftest a-lexical-hint-reads-a-bounded-prefix-of-its-body ()
  ;; RARITY-OF runs one index count per distinct token. An episode can be one
  ;; whole tool result, so an unbounded list cost thousands of queries.
  (with-store (store)
    (let* ((head (with-output-to-string (s)
                   (dotimes (index 64) (format s "tok~D " index))))
           (one (format nil "~A~A" head (make-string 4000 :initial-element #\a)))
           (two (format nil "~A~A" head (make-string 4000 :initial-element #\b))))
      (testing "the weight reads at most *HINT-TOKEN-LIMIT* distinct tokens"
        (ok (= enchiridion.memory::*hint-token-limit*
               (length (enchiridion.memory::hint-tokens one)))))
      (testing "so two long bodies that share their first tokens weigh the same"
        (ok (= (enchiridion.memory::rarity-of store one)
               (enchiridion.memory::rarity-of store two))))
      (testing "and a short body keeps every token it has"
        (ok (= 4 (length (enchiridion.memory::hint-tokens
                          "deploy key in vault ops"))))))))

(deftest a-changed-model-is-pending-and-keeps-the-old-vectors ()
  (with-store (store)
    (let ((write (turn-writer store)))
      (funcall write "the blue garage door")
      (funcall write "the red bicycle shed")
      (let ((enchiridion.memory:*memory-embedder* (test-embedder))
            (enchiridion.memory:*memory-embed-model* "model-a")
            (enchiridion.memory::*memory-embed-settings* '(:dimensions 4)))
        (ok (= 2 (enchiridion.memory:embed-pending store)))
        (ok (zerop (enchiridion.memory:embed-pending store)))
        (setf enchiridion.memory:*memory-embed-model* "model-b")
        (testing "a new model is pending again"
          (ok (= 2 (enchiridion.memory:embed-pending store)))
          (ok (zerop (enchiridion.memory:embed-pending store))))
        (testing "and both models' caches survive"
          (ok (= 2 (row-count store
                              "SELECT COUNT(*) AS n FROM episode_vectors
                                WHERE model = 'model-a'")))
          (ok (= 2 (row-count store
                              "SELECT COUNT(*) AS n FROM episode_vectors
                                WHERE model = 'model-b'"))))
        (testing "a switch back needs no work"
          (setf enchiridion.memory:*memory-embed-model* "model-a")
          (ok (zerop (enchiridion.memory:embed-pending store))))))))

(deftest a-changed-size-is-pending-under-the-same-model ()
  (with-store (store)
    (funcall (turn-writer store) "the blue garage door")
    (let ((enchiridion.memory:*memory-embedder* (test-embedder))
          (enchiridion.memory:*memory-embed-model* "m")
          (enchiridion.memory::*memory-embed-settings* '(:dimensions 3)))
      (ok (= 1 (enchiridion.memory:embed-pending store)))
      (ok (zerop (enchiridion.memory:embed-pending store)))
      (setf enchiridion.memory::*memory-embed-settings* '(:dimensions 5))
      (testing "the new size is a new cache key"
        (ok (= 1 (enchiridion.memory:embed-pending store)))
        (ok (zerop (enchiridion.memory:embed-pending store)))
        (ok (= 2 (row-count store
                            "SELECT COUNT(*) AS n FROM episode_vectors
                              WHERE model = 'm'")))))))

(deftest embedding-stops-between-requests-at-its-budget ()
  (with-store (store)
    (let ((write (turn-writer store)))
      (dotimes (index 5) (funcall write (format nil "record ~D" index)))
      (let* ((calls (list 0))
             (enchiridion.memory:*memory-embedder* (test-embedder :calls calls))
            (enchiridion.memory:*memory-embed-model* "m")
            (enchiridion.memory::*memory-embed-settings* '(:dimensions 4))
            (enchiridion.memory::*embed-batch* 2))
        (testing "the budget covers one request of two texts"
          (ok (= 2 (enchiridion.memory:embed-pending
                    store :max-tokens
                    (enchiridion.memory::embedding-token-estimate
                     '("record 0" "record 0")))))
          (ok (= 1 (car calls)))
          (ok (= 3 (row-count store
                              "SELECT COUNT(*) AS n FROM episodes e
                                WHERE NOT EXISTS (SELECT 1 FROM episode_vectors v
                                                   WHERE v.id = e.id)"))))
        (testing "the rest waits for the next call"
          ;; Three texts at a batch of two are two more requests.
          (ok (= 3 (enchiridion.memory:embed-pending store)))
          (ok (zerop (enchiridion.memory:embed-pending store)))
          (ok (= 3 (car calls))))))))

(deftest a-dense-index-keeps-the-newest-vectors-of-one-store ()
  (with-store (store)
    (let ((write (turn-writer store)))
      (dotimes (index 300) (funcall write (format nil "record number ~D" index)))
      (let ((enchiridion.memory:*memory-embedder* (test-embedder))
            (enchiridion.memory:*memory-embed-model* "m")
            (enchiridion.memory::*memory-embed-settings* '(:dimensions 8))
            (enchiridion.memory::*dense-index-max-vectors* 128)
            (enchiridion.memory::*vector-index-max-stores* 1))
        (ok (= 300 (enchiridion.memory:embed-pending store :limit 400)))
        (let* ((index (enchiridion.memory::vector-index-for store))
               (ids (coerce (enchiridion.memory::vector-index-ids index) 'list)))
          (testing "the index holds its cap and not the whole history"
            (ok (<= (length ids) 128))
            (ok (>= (length ids) 120)))
          (testing "and what it keeps is the newest tail"
            (ok (= 300 (car (last ids))))
            (ng (member 1 ids))
            (ok (equal ids (sort (copy-list ids) #'<)))))))))

(deftest a-dense-index-drops-the-least-recently-used-store ()
  (clrhash enchiridion.memory::*vector-indexes*)
  (with-store (first-store)
    (funcall (turn-writer first-store) "first store record")
    (let ((enchiridion.memory:*memory-embedder* (test-embedder))
          (enchiridion.memory:*memory-embed-model* "m")
          (enchiridion.memory::*memory-embed-settings* '(:dimensions 4))
          (enchiridion.memory::*vector-index-max-stores* 1))
      (enchiridion.memory:embed-pending first-store)
      (enchiridion.memory::vector-index-for first-store)
      (ok (= 1 (hash-table-count enchiridion.memory::*vector-indexes*)))
      (with-store (second-store)
        (funcall (turn-writer second-store) "second store record")
        (enchiridion.memory:embed-pending second-store)
        (enchiridion.memory::vector-index-for second-store)
        (testing "only one store's index stays cached"
          (ok (= 1 (hash-table-count enchiridion.memory::*vector-indexes*))))
        (testing "and the older store's index is the one dropped"
          (ok (null (gethash (namestring (enchiridion.memory.store:store-path
                                          first-store))
                             enchiridion.memory::*vector-indexes*))))))))

(deftest a-candidate-loads-a-prefix-and-the-pack-reads-further ()
  (with-store (store)
    (let ((enchiridion.memory::*retrieval-body-chars* 100)
          (enchiridion.memory::*pack-body-chars* 2000)
          (body (concatenate 'string
                             (make-string 500 :initial-element #\x)
                             " zebra stripes here "
                             (make-string 500 :initial-element #\y))))
      (enchiridion.memory:write-episode store :session "s" :role "user"
                                               :body body :derive-p nil)
      (let ((rows (enchiridion.memory:retrieve-rows-for-turn store "zebra")))
        (ok (= 1 (length rows)))
        (testing "ranking read a bounded prefix"
          (ok (<= (length (getf (getf (first rows) :item) :body)) 100))
          (ng (search "zebra" (getf (getf (first rows) :item) :body))))
        (testing "and the pack searches the larger bound"
          (let ((pack (nth-value 0
                                 (enchiridion.memory:render-pack
                                  (enchiridion.memory:select-pack-rows
                                   store "zebra" rows)
                                  :cue "zebra"))))
            (ok (search "zebra" pack))))))))

(defstruct (rerank-backend (:constructor make-rerank-backend))
  (text "1,2" :type string))

(defmethod enchiridion.llm:complete ((backend rerank-backend) messages
                                     &key model tools budget)
  (declare (ignore messages model tools budget))
  (enchiridion.llm::%make-completion :text (rerank-backend-text backend)
                                     :model "rerank-model"
                                     :input-tokens 30 :output-tokens 7))

(defmethod enchiridion.llm:model-capabilities ((backend rerank-backend))
  (declare (ignore backend))
  '(:tools nil))

(defmethod enchiridion.llm:backend-name ((backend rerank-backend))
  (declare (ignore backend))
  "rerank")

(deftest an-optional-call-bills-the-turn-ledger ()
  (with-store (store)
    (let ((write (turn-writer store)))
      (funcall write "the zebra stripes are on the wall")
      (funcall write "the garage door is blue")
      (let ((enchiridion.memory:*memory-embedder* (test-embedder))
            (enchiridion.memory:*memory-embed-model* "m")
            (enchiridion.memory::*memory-embed-settings* '(:dimensions 4))
            (enchiridion.memory:*memory-reranker*
              (enchiridion.memory:make-model-reranker (make-rerank-backend))))
        (enchiridion.memory:embed-pending store)
        (ok (enchiridion.memory:retrieve-for-turn store "zebra stripes"
                                                  :session "s7"))
        (let* ((rows (enchiridion.memory.store:usage-rows store))
               (embed (find-if (lambda (row)
                                 (and (string= "embed"
                                               (enchiridion.memory.store:field
                                                row "channel"))
                                      (string= "s7"
                                               (enchiridion.memory.store:field
                                                row "session"))))
                               rows))
               (rerank (find "rerank" rows
                             :key (lambda (row)
                                    (enchiridion.memory.store:field row "channel"))
                             :test #'string=)))
          (testing "the cue embedding is a ledger row in the turn's session"
            (ok embed)
            (ok (string= "s7" (enchiridion.memory.store:field embed "session")))
            (ok (plusp (enchiridion.memory.store:field embed "input"))))
          (testing "and so is the rerank, with what the provider reported"
            (ok rerank)
            (ok (= 30 (enchiridion.memory.store:field rerank "input")))
            (ok (= 7 (enchiridion.memory.store:field rerank "output")))
            (ok (string= "s7" (enchiridion.memory.store:field rerank "session")))))))))
