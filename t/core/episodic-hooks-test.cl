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
            '(:memory (:block-limits (:persona 9000)) (:graph-limit 7)
                      (:push-max-fraction 0.25) (:gate-margin 0.3)
                      (:gate-min-n 3) (:t2-writes-per-episode 9)))
           (testing "a block limit the operator sets is the one a block gets"
             (ok (= 9000 (enchiridion.memory:default-block-limit :persona)))
             (ok (= 9000 (enchiridion.memory:block-limit
                          (enchiridion.memory:make-block :label :persona)))))
           (testing "and the limits the operator left out keep their shipped value"
             (ok (= (getf (enchiridion:config-section-value
                           (enchiridion:default-config) :memory :block-limits)
                          :world)
                    (enchiridion.memory:default-block-limit :world))))
           (testing "the retrieval, push, and gate settings follow the section"
             (ok (= 7 enchiridion.memory:*memory-graph-limit*))
             (ok (= 0.25 enchiridion.memory:*push-max-fraction*))
             (ok (= 0.3 enchiridion.memory:*memory-gate-margin*))
             (ok (= 3 enchiridion.memory:*memory-gate-min-n*))
             (ok (= 9 enchiridion.memory:*memory-writes-per-episode*)))
           (enchiridion.memory:configure-memory
            '(:memory (:enabled t) (:push t)))
           (testing "push needs the master switch and its own flag"
             (ok (enchiridion.memory:enabled-p))
             (ok (enchiridion.memory:push-enabled-p))))
      (enchiridion.memory:configure-memory
       (enchiridion:default-config)))))


(deftest every-episode-gets-an-activation-row-from-its-own-time ()
  (with-store (store directory)
    (let ((old (enchiridion.memory.store:record-turn
                store :session "s" :role "user" :body "the old plan" :ts 1000))
          (memory (enchiridion.memory.store:save-memory
                   store "note" "the saved plan" :ts 2000)))
      (testing "a turn's row starts at its write time with one encoding"
        (let ((row (first (enchiridion.memory.store:query-rows
                           store "SELECT * FROM activation WHERE kind = 'episode' AND id = ?"
                           (list (enchiridion.memory.store:turn-row-id old))))))
          (ok (= 1000 (enchiridion.memory.store:field row "created_ts")))
          (ok (= 1 (enchiridion.memory.store:field row "n_enc")))
          (ok (= 3 (enchiridion.memory.store:field row "imp")))))
      (testing "a saved memory starts more important than a turn"
        (ok (= 7 (count-rows store "SELECT imp AS n FROM activation
                                     WHERE kind = 'episode' AND id = ?"
                             (list memory)))))
      (testing "the candidate carries the stored write time, so age can rank"
        (let ((candidate (first (enchiridion.memory:candidates-for
                                 store "old plan" :now 5000))))
          (ok (= 1000 (enchiridion.memory::activation-created-ts
                       (getf candidate :activation))))))
      (testing "deleting the session removes its activation rows"
        (enchiridion.memory.store:delete-session store "s")
        (ok (= 0 (count-rows store "SELECT COUNT(*) AS n FROM activation
                                     WHERE kind = 'episode' AND id = ?"
                             (list (enchiridion.memory.store:turn-row-id old)))))))))

(deftest a-store-without-activation-rows-is-backfilled-on-open ()
  (multiple-value-bind (store directory) (scratch-store)
    (unwind-protect
         (let ((path (enchiridion.memory.store:store-path store)))
           (enchiridion.memory.store:record-turn store :session "s" :body "kept text" :ts 42)
           ;; A store from before the trigger: no activation row, version 1.
           (enchiridion.memory.store::exec store "DELETE FROM activation")
           (enchiridion.memory.store::set-schema-version store 1)
           (enchiridion.memory.store:close-store store)
           (setf store (enchiridion.memory.store:open-store :path path))
           (ok (= 42 (count-rows store "SELECT created_ts AS n FROM activation")))
           (ok (= enchiridion.memory.store::+schema-version+
                  (enchiridion.memory.store::schema-version store))))
      (ignore-errors (enchiridion.memory.store:close-store store))
      (uiop:delete-directory-tree directory :validate t :if-does-not-exist :ignore))))

(deftest a-candidate-carries-its-bm25-relevance ()
  (with-store (store directory)
    (enchiridion.memory.store:record-turn
     store :session "s" :body "zebra zebra zebra stripes")
    (enchiridion.memory.store:record-turn
     store :session "s" :body "a long note that mentions a zebra once among many other words about the weather and the road and the town")
    (let* ((candidates (enchiridion.memory:candidates-for store "zebra stripes"))
           (scores (mapcar (lambda (c) (getf c :lexical)) candidates)))
      (testing "every candidate has a score and the closer match scores higher"
        (ok (= 2 (length candidates)))
        (ok (every #'realp scores))
        (ok (> (getf (find-if (lambda (c) (search "stripes" (getf c :body))) candidates)
                     :lexical)
               (getf (find-if (lambda (c) (search "weather" (getf c :body))) candidates)
                     :lexical)))))
    (testing "with only the lexical weight, the closer match ranks first"
      (let* ((enchiridion.memory:*memory-parameters*
               (let ((p (copy-list enchiridion.memory:*memory-parameters*)))
                 (dolist (key '(:base-weight :spread-weight :temporal-weight
                                :importance-weight :cue-type-weight :context-weight
                                :inhibition-weight :distinct-weight)
                               p)
                   (setf (getf p key) 0.0))
                 (setf (getf p :lexical-weight) 1.0)
                 p))
             (rows (enchiridion.memory:retrieve-rows-for-turn store "zebra stripes")))
        (ok (search "stripes" (getf (getf (first rows) :item) :body)))))))

(deftest a-cue-excerpt-shows-the-matching-middle-of-a-long-record ()
  (let* ((filler (format nil "~{~A~^ ~}" (make-list 120 :initial-element "weather")))
         (body (format nil "~A I graduated with a degree in Business Administration. ~A"
                       filler filler))
         (rows (list (list :item (list :kind "episode" :id 1 :body body)))))
    (testing "the head excerpt misses a fact in the middle"
      (let ((enchiridion.memory:*memory-parameters*
              (list* :pack-excerpt :head enchiridion.memory:*memory-parameters*)))
        (ok (null (search "Business" (enchiridion.memory:render-pack
                                      rows :cue "what degree did I graduate with"))))))
    (testing "the cue excerpt shows it, marked as cut on both sides"
      (let* ((enchiridion.memory:*memory-parameters*
               (list* :pack-excerpt :cue enchiridion.memory:*memory-parameters*))
             (pack (enchiridion.memory:render-pack
                    rows :cue "what degree did I graduate with")))
        (ok (search "Business Administration" pack))
        (ok (search "…" pack))
        (ok (<= (length pack) (+ 400 120)))))
    (testing "the second value is the rows the budget let in"
      (multiple-value-bind (pack included)
          (enchiridion.memory:render-pack (append rows rows) :budget 500)
        (ok pack)
        (ok (= 1 (length included)))))))

(defmacro with-parameters ((&rest overrides) &body body)
  `(let ((enchiridion.memory:*memory-parameters*
           (list* ,@overrides enchiridion.memory:*memory-parameters*)))
     ,@body))

(deftest maintenance-writes-links-only-when-a-term-reads-them ()
  (with-store (store directory)
    (enchiridion.memory.store:record-turn store :session "s" :body "red kite over the hill")
    (enchiridion.memory.store:record-turn store :session "s" :body "a red kite again")
    (testing "with the graph terms at 0, episodes are derived and no link is written"
      (with-parameters (:spread-weight 0.0 :distinct-weight 0.0)
        (ok (= 2 (getf (enchiridion.memory:maintenance store) :derived)))
        (ok (= 0 (count-rows store "SELECT COUNT(*) AS n FROM links")))))
    (testing "turning spread on and rebuilding derives the links"
      (with-parameters (:spread-weight 0.5)
        (ok (= 2 (enchiridion.memory:rebuild-derived store)))
        (ok (= 2 (getf (enchiridion.memory:maintenance store) :derived)))
        (ok (plusp (count-rows store "SELECT COUNT(*) AS n FROM links")))))))

(deftest a-pack-can-carry-dates-roles-and-neighbouring-turns ()
  (with-store (store directory)
    (enchiridion.memory.store:record-turn store :session "s" :role "user"
                                          :body "where should I park" :ts 3900000000)
    (enchiridion.memory.store:record-turn store :session "s" :role "assistant"
                                          :body "the blue garage on fifth" :ts 3900000060)
    (enchiridion.memory.store:record-turn store :session "t" :role "user"
                                          :body "unrelated text" :ts 3900000120)
    (with-parameters (:pack-neighbours 1 :pack-header t)
      (let* ((rows (enchiridion.memory:retrieve-rows-for-turn store "blue garage"))
             (expanded (enchiridion.memory:pack-rows store rows))
             (pack (enchiridion.memory:render-pack expanded :cue "blue garage")))
        (testing "the hit comes first and its session neighbour follows it"
          (ok (= 1 (length rows)))
          (ok (= 2 (length expanded)))
          (ok (search "garage" (getf (getf (first expanded) :item) :body)))
          (ok (search "park" (getf (getf (second expanded) :item) :body))))
        (testing "a turn from another session is not a neighbour"
          (ok (null (search "unrelated" pack))))
        (testing "each record shows its UTC date and role after the ref tag"
          (ok (search "] (2023-08-02, assistant) the blue garage" pack))
          (ok (search "] (2023-08-02, user) where should I park" pack)))))
    (testing "with both off, the pack is what it was"
      (with-parameters (:pack-neighbours 0 :pack-header nil)
        (let ((rows (enchiridion.memory:retrieve-rows-for-turn store "blue garage")))
          (ok (equal rows (enchiridion.memory:pack-rows store rows)))
          (ok (search "[ref episode-2] the blue garage"
                      (enchiridion.memory:render-pack rows :cue "blue garage"))))))))

(deftest a-vector-survives-the-blob-round-trip ()
  (let* ((v (enchiridion.memory::normalise-vector #(3.0 4.0 0.0 -1.5)))
         (back (enchiridion.memory:decode-vector (enchiridion.memory:encode-vector v))))
    (ok (= 16 (length (enchiridion.memory:encode-vector v))))
    (ok (every #'= v back))
    (ok (< (abs (- 1.0 (enchiridion.memory::dot back back))) 1e-5))))

(deftest the-embeddings-wire-returns-vectors-in-input-order ()
  (let* ((sent nil)
         (enchiridion.llm::*http-post-function*
           (lambda (request)
             (setf sent request)
             ;; Out of order on purpose: the index decides the position.
             "{\"data\":[{\"index\":1,\"embedding\":[0.0,1.0]},
                         {\"index\":0,\"embedding\":[1.0,0.0]}]}"))
         (vectors (enchiridion.llm:embed
                   (enchiridion.llm:openai-backend :api-key "test-key")
                   '("first" "second") :model "emb-model" :dimensions 2)))
    (ok (= 2 (length vectors)))
    (ok (= 1.0 (aref (first vectors) 0)))
    (ok (= 1.0 (aref (second vectors) 1)))
    (ok (search "embeddings" (enchiridion.llm::http-request-url sent)))
    (ok (search "\"dimensions\":2" (enchiridion.llm::http-request-body sent)))))

(defun fake-embedder (texts)
  "Map a text to a two-dimensional vector by meaning, for the test only: the
car words and the vehicle words land together, everything else apart."
  (mapcar (lambda (text)
            (if (or (search "car" text) (search "vehicle" text) (search "sedan" text))
                (vector 1.0 0.0)
                (vector 0.0 1.0)))
          texts))

(deftest dense-candidates-reach-a-paraphrase-bm25-cannot ()
  (with-store (store directory)
    (enchiridion.memory.store:record-turn store :session "s" :body "I bought a used sedan last week")
    (enchiridion.memory.store:record-turn store :session "s" :body "the weather was cold and grey")
    (testing "BM25 alone finds nothing for a cue with no shared word"
      (ok (null (enchiridion.memory:retrieve-rows-for-turn store "which vehicle is mine"))))
    (let ((enchiridion.memory:*memory-embedder* #'fake-embedder)
          (enchiridion.memory:*memory-embed-model* "fake"))
      (testing "the embedder writes one vector per episode"
        (ok (= 2 (enchiridion.memory:embed-pending store)))
        (ok (= 0 (enchiridion.memory:embed-pending store))))
      (testing "with dense candidates the paraphrase ranks first"
        (let ((rows (enchiridion.memory:retrieve-rows-for-turn store "which vehicle is mine")))
          (ok (search "sedan" (getf (getf (first rows) :item) :body)))))
      (testing "a failing cue embedding falls back to BM25"
        (let ((enchiridion.memory:*memory-embedder*
                (lambda (texts) (declare (ignore texts)) (error "no network")))
              (*error-output* (make-broadcast-stream)))
          (ok (search "weather"
                      (getf (getf (first (enchiridion.memory:retrieve-rows-for-turn
                                          store "cold weather"))
                                  :item)
                            :body))))))
    (testing "deleting the session removes its vectors"
      (enchiridion.memory.store:delete-session store "s")
      (ok (= 0 (count-rows store "SELECT COUNT(*) AS n FROM episode_vectors"))))))

(deftest a-reranker-only-reorders-and-a-failure-changes-nothing ()
  (let ((rows (loop for i from 1 to 5
                    collect (list :item (list :kind "episode" :id i
                                              :body (format nil "record ~D" i))))))
    (flet ((ids (rows) (mapcar (lambda (r) (getf (getf r :item) :id)) rows)))
      (testing "the named rows come first, in the reranker's order, nothing is lost"
        (ok (equal '(4 2 1 3 5)
                   (ids (enchiridion.memory:rerank-rows
                         rows "q" :pool 5
                         :reranker (lambda (cue bodies)
                                     (declare (ignore cue bodies))
                                     (enchiridion.memory:parse-rerank-reply "4, 2, 2, 9" 5)))))))
      (testing "rows past the pool keep their place"
        (ok (equal '(2 1 3 4 5)
                   (ids (enchiridion.memory:rerank-rows
                         rows "q" :pool 3
                         :reranker (lambda (cue bodies)
                                     (declare (ignore cue bodies))
                                     '(1)))))))
      (testing "an error or an empty reply keeps the score order"
        (let ((*error-output* (make-broadcast-stream)))
          (ok (equal '(1 2 3 4 5)
                     (ids (enchiridion.memory:rerank-rows
                           rows "q" :pool 5
                           :reranker (lambda (cue bodies)
                                       (declare (ignore cue bodies))
                                       (error "timeout")))))))
        (ok (equal '(1 2 3 4 5)
                   (ids (enchiridion.memory:rerank-rows
                         rows "q" :pool 5
                         :reranker (lambda (cue bodies)
                                     (declare (ignore cue bodies))
                                     (enchiridion.memory:parse-rerank-reply "none" 5))))))))))
