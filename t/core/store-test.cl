;;;; store-test.cl --- SQLite, FTS5, sessions, memories, and the ledger.
;;;;
;;;; Every test here is about the store keeping its word: the text comes back
;;;; as it went in, a deleted session stops matching, and a secret never
;;;; reaches a column. The FTS index is the part worth testing hardest,
;;;; because a stale index entry is a memory the operator cannot remove.

(defpackage #:enchiridion-store-test
  (:use #:cl)
  (:import-from #:rove #:deftest #:ok #:ng #:testing #:signals)
  (:export #:run))

(in-package #:enchiridion-store-test)

(defparameter +fake-key+ "sk-test-0123456789abcdefghijklmnop"
  "A value long enough for the literal filter. It is not a real key, and it is
never sent anywhere.")

(defun scratch-directory ()
  "Return a fresh directory under the directory this build may write."
  (uiop:ensure-directory-pathname
   (merge-pathnames
    (format nil "enchiridion-store-test-~D/" (random most-positive-fixnum))
    (uiop:ensure-directory-pathname *default-pathname-defaults*))))

(defmacro with-scratch-store ((store) &body body)
  "Bind STORE to an open store in a scratch directory, and remove the file.

The connection is closed before the directory goes, because a directory tree
holding an open SQLite file is a delete that fails on one platform and not on
another."
  `(let* ((directory (scratch-directory))
          (,store (enchiridion.memory.store:open-store
                   :path (merge-pathnames "memory.db" directory))))
     (unwind-protect
          (progn ,@body)
       (ignore-errors (enchiridion.memory.store:close-store ,store))
       (uiop:delete-directory-tree directory
                                   :validate t
                                   :if-does-not-exist :ignore))))

(defun index-hits (store table query)
  "Return how many rows of the FTS TABLE match QUERY, with no join.

A search joins the index to its row table, so a stale index entry for a
deleted row is invisible there: the join drops it. Counting on the index
itself is what proves the trigger ran."
  (getf (first (enchiridion.memory.store::query-rows
                store
                (format nil "SELECT COUNT(*) AS n FROM ~A WHERE ~A MATCH ?"
                        table table)
                (list (enchiridion.memory.store::fts-query query))))
        :n))

(deftest a-store-creates-its-file-and-reopens ()
  (let* ((directory (scratch-directory))
         (path (merge-pathnames "memory.db" directory)))
    (unwind-protect
         (let ((first (enchiridion.memory.store:open-store :path path)))
           (unwind-protect
                (progn
                  (ok (probe-file path))
                  (ok (string= (namestring path)
                               (namestring (enchiridion.memory.store:store-path first))))
                  (testing "opening the same file twice keeps the schema"
                    (let ((second (enchiridion.memory.store:open-store :path path)))
                      (unwind-protect
                           (progn
                             (ok (zerop (enchiridion.memory.store:session-count second)))
                             (enchiridion.memory.store:record-turn
                              second :session "s" :body "hello store"))
                        (enchiridion.memory.store:close-store second))))
                  (testing "and the first connection sees the row the second wrote"
                    (ok (= 1 (enchiridion.memory.store:session-count first)))))
             (enchiridion.memory.store:close-store first)))
      (uiop:delete-directory-tree directory
                                  :validate t
                                  :if-does-not-exist :ignore))))

(deftest a-recorded-turn-comes-back-whole ()
  (with-scratch-store (store)
    (let ((row (enchiridion.memory.store:record-turn
                store :session "session-1" :role :user
                      :body "the index saved 224 tokens"
                      :model "space-bunny" :channel :cli :ts 42)))
      (ok (typep row 'enchiridion.memory.store:turn-row))
      (ok (plusp (enchiridion.memory.store:turn-row-id row)))
      (ok (string= "session-1" (enchiridion.memory.store:turn-row-session row)))
      (ok (string= "user" (enchiridion.memory.store:turn-row-role row)))
      (ok (string= "the index saved 224 tokens"
                   (enchiridion.memory.store:turn-row-body row)))
      (ok (string= "space-bunny" (enchiridion.memory.store:turn-row-model row)))
      (ok (eq :cli (enchiridion.memory.store:turn-row-channel row)))
      (ok (= 42 (enchiridion.memory.store:turn-row-ts row))))))

(deftest sessions-are-counted-and-listed ()
  (with-scratch-store (store)
    (enchiridion.memory.store:record-turn store :session "a" :body "one" :ts 100)
    (enchiridion.memory.store:record-turn store :session "a" :body "two" :ts 200)
    (enchiridion.memory.store:record-turn store :session "b" :body "three" :ts 150)
    (ok (= 2 (enchiridion.memory.store:session-count store)))
    (let ((sessions (enchiridion.memory.store:recent-sessions store)))
      (ok (= 2 (length sessions)))
      (testing "the most recently active session is first"
        (ok (string= "a" (getf (first sessions) :id)))
        (ok (= 2 (getf (first sessions) :turns)))
        (ok (= 100 (getf (first sessions) :started)))
        (ok (= 200 (getf (first sessions) :ended)))))))

(deftest a-search-returns-the-stored-text ()
  (with-scratch-store (store)
    (enchiridion.memory.store:record-turn
     store :session "s" :role "user"
           :body "the reader gives the position, no parser")
    (enchiridion.memory.store:record-turn
     store :session "s" :role "assistant" :body "unrelated words here")
    (let ((hits (enchiridion.memory.store:search-sessions store "parser")))
      (ok (= 1 (length hits)))
      (ok (string= "the reader gives the position, no parser"
                   (enchiridion.memory.store:turn-row-body (first hits))))
      (testing "a prefix finds the word it starts"
        (ok (= 1 (length (enchiridion.memory.store:search-sessions store "pars")))))
      (testing "every term has to be there, the way a model expects"
        (ok (= 1 (length (enchiridion.memory.store:search-sessions store "reader position"))))
        (ok (null (enchiridion.memory.store:search-sessions store "reader xylophone"))))
      (testing "a query with nothing to match is refused, not widened"
        (ok (signals (enchiridion.memory.store:search-sessions store " - ")
                     'enchiridion.errors:schema-error))))))

(deftest a-search-query-is-never-sql ()
  (with-scratch-store (store)
    (enchiridion.memory.store:record-turn
     store :session "s" :body "the cache-write column and the cache read column")
    (testing "a hyphen is a literal and not an operator"
      (ok (= 1 (length (enchiridion.memory.store:search-sessions store "cache-write")))))
    (testing "a quote is a literal, and the word inside it still matches"
      (ok (= 1 (length (enchiridion.memory.store:search-sessions store "\"cache\""))))
      (ok (listp (enchiridion.memory.store:search-sessions store "\" OR 1=1 --"))))
    (testing "FTS keywords are ordinary words"
      (ok (listp (enchiridion.memory.store:search-sessions store "NEAR OR AND NOT"))))
    (testing "a control character is refused rather than handed to the parser"
      (ok (signals (enchiridion.memory.store:search-sessions
                    store (format nil "xylophone~Cmore" (code-char 0)))
                   'enchiridion.errors:schema-error))
      (ok (signals (enchiridion.memory.store:search-sessions
                    store (format nil "xylophone~Cmore" (code-char 7)))
                   'enchiridion.errors:schema-error)))))

(deftest a-deleted-session-stops-matching ()
  (with-scratch-store (store)
    (enchiridion.memory.store:record-turn
     store :session "a" :body "the unique phrase xylophone")
    (enchiridion.memory.store:record-turn
     store :session "b" :body "the unique phrase glockenspiel")
    (ok (= 2 (length (enchiridion.memory.store:search-sessions store "unique"))))
    (ok (= 2 (index-hits store "turns_fts" "unique")))
    (ok (= 1 (enchiridion.memory.store:delete-session store "a")))
    (ok (= 1 (enchiridion.memory.store:session-count store)))
    (testing "the index forgot the row and not only the table"
      (ok (= 1 (length (enchiridion.memory.store:search-sessions store "unique"))))
      (ok (null (enchiridion.memory.store:search-sessions store "xylophone"))))
    (testing "and the index itself is clean, which the join alone cannot show"
      (ok (zerop (index-hits store "turns_fts" "xylophone")))
      (ok (= 1 (index-hits store "turns_fts" "unique"))))))

(deftest an-updated-body-replaces-its-index-entry ()
  (with-scratch-store (store)
    (let ((row (enchiridion.memory.store:record-turn
                store :session "s" :body "the original xylophone")))
      ;; EXEC is internal, and an UPDATE has no public caller yet. The trigger
      ;; it proves is the one a later migration or a sleep pass will lean on.
      (enchiridion.memory.store::exec
       store "UPDATE turns SET body = ? WHERE id = ?"
       (list "the replacement glockenspiel"
             (enchiridion.memory.store:turn-row-id row)))
      (ok (null (enchiridion.memory.store:search-sessions store "xylophone")))
      (ok (= 1 (length (enchiridion.memory.store:search-sessions store "glockenspiel")))))))

(deftest a-memory-round-trips-and-a-duplicate-is-refused ()
  (with-scratch-store (store)
    (let ((id (enchiridion.memory.store:save-memory
               store "tokens" "the index cost 59 and saved 224" :session "s")))
      (ok (plusp id))
      (ok (string= "the index cost 59 and saved 224"
                   (getf (first (enchiridion.memory.store:list-memories store)) :body)))
      (testing "the body and the name are both searchable"
        (ok (= 1 (length (enchiridion.memory.store:search-memories store "index"))))
        (ok (= 1 (length (enchiridion.memory.store:search-memories store "tokens")))))
      (testing "the same name and text again is refused"
        (ok (signals (enchiridion.memory.store:save-memory
                      store "tokens" "the index cost 59 and saved 224")
                     'enchiridion.errors:configuration-error)))
      (testing "and so is a memory with no text"
        (ok (signals (enchiridion.memory.store:save-memory store "empty" "")
                     'enchiridion.errors:configuration-error))))))

(deftest the-harness-blocks-round-trip ()
  (with-scratch-store (store)
    (ok (string= "" (enchiridion.memory.store:session-block store)))
    (ok (string= "" (enchiridion.memory.store:ledger-block store)))
    (ok (string= "reading the index"
                 (enchiridion.memory.store:set-session-block store "reading the index")))
    (ok (string= "1200 in 300 out"
                 (enchiridion.memory.store:set-ledger-block store "1200 in 300 out")))
    (ok (string= "reading the index" (enchiridion.memory.store:session-block store)))
    (ok (string= "1200 in 300 out" (enchiridion.memory.store:ledger-block store)))
    (testing "a second write replaces the first"
      (enchiridion.memory.store:set-session-block store "planning")
      (ok (string= "planning" (enchiridion.memory.store:session-block store))))))

(deftest the-usage-ledger-keeps-every-column ()
  (with-scratch-store (store)
    (enchiridion.memory.store:record-usage store :session "s" :model "space-bunny"
                                           :input 1200 :output 300
                                           :cache-read 900 :cache-write 100
                                           :channel :cli :ts 100)
    (enchiridion.memory.store:record-usage store :session "s" :model "kimi-k3"
                                           :input 10 :output 5 :ts 200)
    (let ((rows (enchiridion.memory.store:usage-rows store)))
      (ok (= 2 (length rows)))
      (ok (string= "space-bunny" (getf (first rows) :model)))
      (ok (= 1200 (getf (first rows) :input)))
      (ok (= 300 (getf (first rows) :output)))
      (ok (= 900 (getf (first rows) :cache_read)))
      (ok (= 100 (getf (first rows) :cache_write)))
      (testing "a row with no cache numbers is a zero and not a null"
        (ok (= 0 (getf (second rows) :cache_read))))
      (testing "the window keeps the newer row only"
        (ok (= 1 (length (enchiridion.memory.store:usage-since store 150))))))))

(deftest a-secret-never-reaches-the-store ()
  (with-scratch-store (store)
    (enchiridion.llm.secrets:clear-secrets)
    (unwind-protect
         (progn
           (enchiridion.llm.secrets:register-secret "OPENCODE_API_KEY" +fake-key+)
           (enchiridion.memory.store:record-turn
            store :session "s"
                  :body (format nil "the key is ~A" +fake-key+)
                  :model +fake-key+)
           (enchiridion.memory.store:save-memory
            store "leak" (format nil "the key is ~A" +fake-key+))
           (let ((turn (first (enchiridion.memory.store:search-sessions store "key"))))
             (ok turn)
             (ok (null (search +fake-key+ (enchiridion.memory.store:turn-row-body turn))))
             (ok (null (search +fake-key+ (enchiridion.memory.store:turn-row-model turn)))))
           (let ((memory (first (enchiridion.memory.store:list-memories store))))
             (ok memory)
             (ok (null (search +fake-key+ (getf memory :body))))))
      (enchiridion.llm.secrets:clear-secrets))))

(deftest a-secret-in-any-column-is-scrubbed ()
  (with-scratch-store (store)
    (enchiridion.llm.secrets:clear-secrets)
    (unwind-protect
         (progn
           (enchiridion.llm.secrets:register-secret "OPENCODE_API_KEY" +fake-key+)
           (enchiridion.memory.store:record-turn
            store :session +fake-key+ :body "harmless" :model +fake-key+)
           (enchiridion.memory.store:save-memory store +fake-key+ "harmless body")
           (enchiridion.memory.store:record-usage store :session +fake-key+
                                                  :model +fake-key+ :input 1)
           (enchiridion.memory.store:set-session-block
            store (format nil "state is ~A" +fake-key+))
           (testing "the session id is scrubbed"
             (ok (null (search +fake-key+
                               (getf (first (enchiridion.memory.store:recent-sessions store))
                                     :id)))))
           (testing "the memory name is scrubbed"
             (ok (null (search +fake-key+
                               (getf (first (enchiridion.memory.store:list-memories store))
                                     :name)))))
           (testing "the usage model is scrubbed"
             (ok (null (search +fake-key+
                               (getf (first (enchiridion.memory.store:usage-rows store))
                                     :model)))))
           (testing "and the harness block is scrubbed"
             (ok (null (search +fake-key+
                               (enchiridion.memory.store:session-block store))))))
      (enchiridion.llm.secrets:clear-secrets))))

(deftest a-store-file-is-recognized-by-its-header ()
  (let* ((directory (scratch-directory))
         (path (merge-pathnames "memory.db" directory))
         (empty (merge-pathnames "empty.db" directory))
         (text (merge-pathnames "notes.txt" directory)))
    (unwind-protect
         (progn
           (testing "a path that is not there is not a store"
             (ok (null (enchiridion.memory.store:store-file-p path))))
           (let ((store (enchiridion.memory.store:open-store :path path)))
             (enchiridion.memory.store:close-store store))
           (ok (enchiridion.memory.store:store-file-p path))
           (testing "a file of zero bytes is not a store"
             (ensure-directories-exist empty)
             (let ((stream (open empty :direction :output
                                       :if-exists :supersede
                                       :if-does-not-exist :create)))
               (close stream))
             (ok (null (enchiridion.memory.store:store-file-p empty))))
           (testing "and neither is text that starts like one"
             (ensure-directories-exist text)
             (with-open-file (stream text :direction :output
                                          :if-exists :supersede
                                          :if-does-not-exist :create)
               (write-string "SQLite format 3 but not really" stream))
             (ok (null (enchiridion.memory.store:store-file-p text)))))
      (uiop:delete-directory-tree directory
                                  :validate t
                                  :if-does-not-exist :ignore))))

(deftest dropping-the-store-removes-every-table ()
  (with-scratch-store (store)
    (enchiridion.memory.store:record-turn store :session "s" :body "xylophone")
    (enchiridion.memory.store:save-memory store "m" "xylophone")
    (enchiridion.memory.store:set-session-block store "x")
    (enchiridion.memory.store:record-usage store :model "m" :input 1)
    (ok (enchiridion.memory.store:drop-store store))
    (testing "SQLite's own bookkeeping table is not one this store created"
      (ok (zerop (length (enchiridion.memory.store::query-rows
                          store "SELECT name FROM sqlite_master
                                  WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")))))))

(deftest the-default-store-path-is-beside-the-seed-files ()
  (ok (string= "/tmp/agent/memory.db"
               (namestring (enchiridion.memory.store:default-store-path "/tmp/agent/"))))
  (testing "and without a directory it still names memory.db"
    (ok (string= "memory.db"
                 (file-namestring (enchiridion.memory.store:default-store-path))))))

(deftest a-task-goes-in-comes-out-and-leaves ()
  (with-scratch-store (store)
    (let ((first (enchiridion.memory.store:enqueue-task store "write the world file"))
          (second (enchiridion.memory.store:enqueue-task store "read the journal")))
      (testing "both wait in order"
        (ok (= 2 (length (enchiridion.memory.store:list-tasks store))))
        (ok (= 2 (length (enchiridion.memory.store:list-tasks store :status :pending))))
        (ok (string= "write the world file"
                     (enchiridion.memory.store:task-row-body first)))
        (ok (< (enchiridion.memory.store:task-row-id first)
               (enchiridion.memory.store:task-row-id second))))
      (testing "the oldest pending task leaves the queue done"
        (let ((taken (enchiridion.memory.store:dequeue-task store)))
          (ok (string= "write the world file"
                       (enchiridion.memory.store:task-row-body taken)))
          (ok (eq :done (enchiridion.memory.store:task-row-status taken)))
          (ok (= 1 (length (enchiridion.memory.store:list-tasks store :status :pending))))
          (ok (= 1 (length (enchiridion.memory.store:list-tasks store :status :done))))))
      (testing "and an empty queue is not an error"
        (enchiridion.memory.store:dequeue-task store)
        (ok (null (enchiridion.memory.store:dequeue-task store))))
      (testing "a removed task is gone"
        (ok (enchiridion.memory.store:remove-task store
                                                  (enchiridion.memory.store:task-row-id
                                                   second)))
        (ok (not (enchiridion.memory.store:remove-task
                  store (enchiridion.memory.store:task-row-id second))))
        (ok (= 1 (length (enchiridion.memory.store:list-tasks store))))))))

(deftest one-connection-with-many-writers-keeps-every-row-id ()
  ;; The supervisor shares one connection with its channel threads, the
  ;; control poll and the heartbeat. A record is an INSERT and then
  ;; LAST_INSERT_ROWID, so without the store's lock two writers interleave and
  ;; one of them reports the other's row id. The count alone would not catch
  ;; that; the ids have to be distinct.
  (with-scratch-store (store)
    (let* ((writers 4)
           (each 10)
           (threads (loop for writer from 1 to writers
                          collect (bordeaux-threads:make-thread
                                   (lambda ()
                                     (loop for turn from 1 to each
                                           do (enchiridion.memory.store:record-turn
                                               store
                                               :session (format nil "s~D" writer)
                                               :role "user"
                                               :body (format nil "writer ~D turn ~D"
                                                             writer turn))))))))
      (dolist (thread threads)
        (bordeaux-threads:join-thread thread))
      (testing "every turn landed"
        (ok (= (* writers each)
               (getf (first (enchiridion.memory.store::query-rows
                             store "SELECT COUNT(*) AS n FROM turns"))
                     :n))))
      (testing "and every row id is its own"
        (let ((ids (mapcar (lambda (row) (getf row :id))
                           (enchiridion.memory.store::query-rows
                            store "SELECT id FROM turns"))))
          (ok (= (* writers each) (length ids)))
          (ok (= (* writers each) (length (remove-duplicates ids)))))))))
