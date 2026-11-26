;;;; store.lsp --- SQLite + FTS5 store for sessions, memories, blocks, and usage.
;;;;
;;;; External-content FTS5 tables are kept in sync by triggers; all strings are
;;;; scrubbed on write. Schema statements are executed individually via DBI.

(in-package #:enchiridion.memory.store)

;;;; The store object.

;; PATH is the db file, CONNECTION is the DBI handle, LOCK serialises thread access.
(defstruct (store (:constructor %make-store))
  (path #p"" :type pathname)
  (connection nil :type t)
  (lock nil :type t))

(defmacro with-store-lock ((store) &body body)
  "Run BODY while holding STORE's recursive lock (or directly if lock is NIL).
Serialises thread access to the shared DBI connection and keeps INSERT +
LAST_INSERT_ROWID atomic."
  (let ((lock (gensym "LOCK")))
    `(let ((,lock (store-lock ,store)))
       (if ,lock
           (bordeaux-threads:with-recursive-lock-held (,lock) ,@body)
           (progn ,@body)))))

(defmacro with-store-transaction ((store) &body body)
  "Run BODY in a BEGIN IMMEDIATE SQLite transaction while holding STORE's lock.
Commits on normal return, rolls back on non-local exit. Nested use is not supported."
  (let ((store-var (gensym "STORE"))
        (committed (gensym "COMMITTED")))
    `(let ((,store-var ,store))
       (with-store-lock (,store-var)
         (exec ,store-var "BEGIN IMMEDIATE")
         (let ((,committed nil))
           (unwind-protect
                (prog1 (progn ,@body)
                  (exec ,store-var "COMMIT")
                  (setf ,committed t))
             (unless ,committed
               (ignore-errors (exec ,store-var "ROLLBACK")))))))))

(defparameter *store-path* nil
  "Default database path for OPEN-STORE, bound by main from operator config.")

(declaim (ftype (function (&optional t) pathname) default-store-path))

(defun default-store-path (&optional directory)
  "Return memory.db under DIRECTORY, or under ENCHIRIDION_HOME/agents/default/
(falling back to cwd when ENCHIRIDION_HOME is unset)."
  (let ((home (uiop:getenv "ENCHIRIDION_HOME")))
    (merge-pathnames
     "memory.db"
     (if directory
         (uiop:ensure-directory-pathname directory)
         (merge-pathnames
          "agents/default/"
          (uiop:ensure-directory-pathname
           (if (and home (plusp (length home))) home (uiop:getcwd))))))))

(defparameter +sqlite-header+ "SQLite format 3"
  "15-byte SQLite 3 file header prefix (followed on disk by a NUL byte).")

(declaim (ftype (function (t) boolean) store-file-p))

(defun store-file-p (path)
  "Return T when PATH starts with the 16-byte SQLite 3 magic header, without
creating or opening the database."
  (handler-case
      (with-open-file (stream path :direction :input
                                   :element-type '(unsigned-byte 8)
                                   :if-does-not-exist nil)
        (when stream
          (let* ((length (length +sqlite-header+))
                 (header (make-array (1+ length)
                                     :element-type '(unsigned-byte 8)
                                     :initial-element 0)))
            (and (= (read-sequence header stream) (1+ length))
                 (loop for index from 0 below length
                       always (= (aref header index)
                                 (char-code (char +sqlite-header+ index))))
                 (zerop (aref header length))))))
    (error () nil)))

;;;; The schema (one statement per element, in dependency order).

(defparameter +schema+
  (append
   (list
    ;; Harness-managed session and ledger blocks.
    "CREATE TABLE IF NOT EXISTS blocks (
       name TEXT PRIMARY KEY,
       body TEXT NOT NULL,
       ts INTEGER NOT NULL)"

    "CREATE TABLE IF NOT EXISTS usage (
       id INTEGER PRIMARY KEY AUTOINCREMENT,
       session TEXT NOT NULL DEFAULT '',
       model TEXT NOT NULL DEFAULT '',
       input INTEGER NOT NULL DEFAULT 0,
       output INTEGER NOT NULL DEFAULT 0,
       cache_read INTEGER NOT NULL DEFAULT 0,
       cache_write INTEGER NOT NULL DEFAULT 0,
       channel TEXT NOT NULL DEFAULT 'cli',
       ts INTEGER NOT NULL)"
    "CREATE INDEX IF NOT EXISTS usage_ts ON usage(ts)"

    ;; Persistent task queue shared by CLI and sleep agent.
    "CREATE TABLE IF NOT EXISTS tasks (
       id INTEGER PRIMARY KEY AUTOINCREMENT,
       body TEXT NOT NULL,
       status TEXT NOT NULL DEFAULT 'pending',
       ts INTEGER NOT NULL)"
    "CREATE INDEX IF NOT EXISTS tasks_status ON tasks(status, id)"

    ;; Adaptation audit log (evidence + before/after text for revert).
    "CREATE TABLE IF NOT EXISTS adaptations (
       id INTEGER PRIMARY KEY AUTOINCREMENT,
       kind TEXT NOT NULL,
       category TEXT NOT NULL DEFAULT '',
       text TEXT NOT NULL,
       evidence TEXT NOT NULL DEFAULT '',
       before_text TEXT NOT NULL DEFAULT '',
       after_text TEXT NOT NULL DEFAULT '',
       ts INTEGER NOT NULL,
       reverted_p INTEGER NOT NULL DEFAULT 0)"
    "CREATE INDEX IF NOT EXISTS adaptations_ts ON adaptations(ts)")
   ;; Episodic DDL loads before this file (see enchiridion.asd).
   enchiridion.memory:+episodic-schema+)
  "Idempotent CREATE statements (base + episodic DDL) executed one per call.")

(defparameter +store-tables+
  (append
   '("blocks" "usage" "tasks" "adaptations")
   enchiridion.memory:*episodic-tables*)
  "What DROP-STORE removes, child table before parent table. The episodic
memory list is child-first because its foreign keys are on.")

(defparameter +store-views+
  (append
   '("turns" "memories")
   enchiridion.memory:*episodic-views*)
  "Views dropped before tables in DROP-STORE (TURNS and MEMORIES are views over EPISODES).")

;;;; Legacy migration: merge old turns/memories tables into episodes + views.
;;;; Idempotent via partial unique keys on source_turn_id / source_memory_id.

(defun sqlite-table-exists-p (store name)
  "Return T when NAME is a table in STORE."
  (not (null (query-rows store
                         "SELECT name FROM sqlite_master
                           WHERE type = 'table' AND name = ?"
                         (list name)))))

(defun migrate-legacy-memory (store)
  "Merge old TURNS and MEMORIES rows into EPISODES, then create the views.
A new store has neither table and only gets the views. Return T."
  (with-store-transaction (store)
    (when (sqlite-table-exists-p store "turns")
      (exec store
            "INSERT OR IGNORE INTO episodes
               (session, role, body, model, ts, channel, provenance, authority,
                cue_type, depth, span, context_key, horizon, source_turn_id)
             SELECT session, role, body, model, ts, channel,
                    CASE role WHEN 'user' THEN 'owner'
                              WHEN 'assistant' THEN 'agent'
                              ELSE 'untrusted' END,
                    CASE role WHEN 'user' THEN 5
                              WHEN 'assistant' THEN 3
                              ELSE 1 END,
                    'episodic', 0, '',
                    session || ',' || session || ',' || lower(channel),
                    2592000, id
               FROM turns")
      (dolist (trigger '("turns_ai" "turns_ad" "turns_au"))
        (exec store (format nil "DROP TRIGGER IF EXISTS ~A" trigger)))
      (exec store "DROP TABLE IF EXISTS turns_fts")
      (exec store "DROP TABLE IF EXISTS turns"))
    (when (sqlite-table-exists-p store "memories")
      (exec store
            "INSERT OR IGNORE INTO episodes
               (session, role, body, model, name, ts, channel, provenance,
                authority, cue_type, depth, span, context_key, horizon,
                source_memory_id)
             SELECT session, 'memory', body, '', name, ts, 'cli', 'owner',
                    5, 'semantic', 0, '', session || ',' || session || ',cli',
                    2592000, id
               FROM memories")
      (dolist (trigger '("memories_ai" "memories_ad" "memories_au"))
        (exec store (format nil "DROP TRIGGER IF EXISTS ~A" trigger)))
      (exec store "DROP TABLE IF EXISTS memories_fts")
      (exec store "DROP TABLE IF EXISTS memories"))
    ;; Drop retired single-pass consolidation table.
    (exec store "DROP TABLE IF EXISTS log_runs")
    (exec store
          "CREATE VIEW IF NOT EXISTS turns AS
             SELECT id, session, role, body, model, channel, ts
               FROM episodes WHERE role <> 'memory'")
    (exec store
          "CREATE VIEW IF NOT EXISTS memories AS
             SELECT id, name, body, session, ts
               FROM episodes WHERE role = 'memory'"))
  t)

;;;; Talking to the database.

(declaim (ftype (function (string) string) scrubbed))

(defun scrubbed (text)
  "Scrub loaded secrets and known secret patterns from TEXT before writing to SQLite."
  (enchiridion.llm.secrets:scrub text))

(declaim (ftype (function (store string &optional list) integer) exec))

(defun exec (store statement &optional parameters)
  "Run one non-query statement on STORE and return the affected row count.
Calls cl-sqlite directly instead of DBI:DO-SQL (which leaks prepared statements on
SELECT changes()), mapping sqlite-error to DBI error classes."
  (with-store-lock (store)
    (let ((handle (dbi.driver:connection-handle (store-connection store))))
      (handler-case (apply #'sqlite:execute-non-query handle statement parameters)
        (sqlite:sqlite-error (e)
          (error (if (eq (sqlite:sqlite-error-code e) :error)
                     'dbi:dbi-programming-error
                     'dbi:dbi-database-error)
                 :message (sqlite:sqlite-error-message e)
                 :error-code (sqlite:sqlite-error-code e))))
      (sqlite:execute-single handle "SELECT changes()"))))

(declaim (ftype (function (list) list) normalise-row))

(defun normalise-row (row)
  "Return ROW with keyword keys upcased (DBI interns SQLite column names verbatim)."
  (loop for (key value) on row by #'cddr
        collect (intern (string-upcase (symbol-name key)) :keyword)
        collect value))

(declaim (ftype (function (store string &optional list) list) query-rows))

(defun query-rows (store statement &optional parameters)
  "Run one query on STORE and return every row as a plist keyed by column."
  (with-store-lock (store)
    ;; Free the prepared statement to avoid leaking it on the connection.
    (let ((query (dbi:prepare (store-connection store) statement)))
      (unwind-protect
           (progn (dbi:execute query parameters)
                  (mapcar #'normalise-row (dbi:fetch-all query)))
        (dbi:free-query-resources query)))))

(declaim (ftype (function (t string) t) field))

(defun field (row name)
  "Return column NAME of ROW, a plist the driver keyed by the column name."
  (getf row (intern (string-upcase name) :keyword)))

(declaim (ftype (function (store) integer) last-row-id))

(defun last-row-id (store)
  "Return the row id the most recent insert on STORE's connection created."
  (field (first (query-rows store "SELECT last_insert_rowid() AS id")) "id"))

;;;; The search string.

(defparameter +query-whitespace+ '(#\Space #\Tab #\Newline #\Return)
  "Whitespace delimiters split on by FTS-QUERY.")

(defun bad-query-character-p (character)
  "Return T for non-whitespace ASCII control characters (including NUL) rejected
before reaching SQLite's FTS5 parser."
  (and (not (member character +query-whitespace+))
       (let ((code (char-code character)))
         (or (< code 32) (= code 127)))))

(defun quote-term (term)
  "Return TERM as an FTS5 quoted prefix query."
  (with-output-to-string (stream)
    (write-char #\" stream)
    (loop for character across term
          do (when (char= character #\")
               (write-char #\" stream))
             (write-char character stream))
    (write-char #\" stream)
    (write-char #\* stream)))

(declaim (ftype (function (string) string) fts-query))

(defun fts-query (text)
  "Convert TEXT into a quoted-prefix FTS5 MATCH string, or signal SCHEMA-ERROR.
Rejects control characters and queries with no alphanumeric terms."
  (when (find-if #'bad-query-character-p text)
    (error 'enchiridion.errors:schema-error
           :detail "The query has a control character."))
  (let ((terms (remove-if (lambda (term)
                            (notany #'alphanumericp term))
                          (uiop:split-string text :separator +query-whitespace+))))
    (when (null terms)
      (error 'enchiridion.errors:schema-error
             :detail "The query has no searchable terms."))
    (format nil "~{~A~^ ~}" (mapcar #'quote-term terms))))

;;;; Opening and closing.

(defparameter +schema-version+ 11
  "Current schema version stored in PRAGMA user_version (v11: shadow canary proposals).
Bumped whenever an existing table, column, or FTS tokenizer changes so OPEN-STORE
runs the idempotent schema/column/index migration path.")

(defparameter +added-columns+
  '(("memory_state" "precision_reset_generation" "INTEGER")
    ("memory_state" "last_t2_episode" "INTEGER")
    ("generations" "episodes_derived" "INTEGER NOT NULL DEFAULT 0")
    ("generations" "claim_owner" "TEXT NOT NULL DEFAULT ''")
    ("generations" "claim_ts" "INTEGER")
    ("episodes" "final_p" "INTEGER"))
  "Columns added to an existing table after it shipped: table, column, type.
CREATE TABLE IF NOT EXISTS never adds one to a table that exists, so
ADD-MISSING-COLUMNS does.")

(defun column-exists-p (store table column)
  "Return T when TABLE in STORE has COLUMN."
  (not (null (find column (query-rows store (format nil "PRAGMA table_info(~A)" table))
                   :key (lambda (row) (field row "name")) :test #'string=))))

(defun add-missing-columns (store)
  "Add each of +ADDED-COLUMNS+ that STORE's tables lack. Idempotent."
  (loop for (table column type) in +added-columns+
        unless (column-exists-p store table column)
          do (exec store (format nil "ALTER TABLE ~A ADD COLUMN ~A ~A" table column type))))

(defun added-columns-present-p (store)
  "Return T when every column in +ADDED-COLUMNS+ is in STORE."
  (every (lambda (entry)
           (column-exists-p store (first entry) (second entry)))
         +added-columns+))

(defun tables-present-p (store)
  "Return T when every table +STORE-TABLES+ names exists in STORE.
A store missing one is rebuilt from the schema list."
  (let* ((names +store-tables+)
         (placeholders (format nil "~{~A~^,~}"
                               (make-list (length names) :initial-element "?")))
         (row (first (query-rows
                      store
                      (format nil "SELECT COUNT(*) AS n FROM sqlite_master
                                     WHERE type = 'table' AND name IN (~A)"
                              placeholders)
                      names))))
    (= (or (field row "n") 0) (length names))))

(defun episode-vector-key-p (store)
  "Return T when EPISODE_VECTORS is keyed by episode, model and size."
  (some (lambda (row)
          (and (string= (field row "name") "model")
               (plusp (or (field row "pk") 0))))
        (query-rows store "PRAGMA table_info(episode_vectors)")))

(defun migrate-episode-vectors (store)
  "Migrate pre-v7 EPISODE_VECTORS from PRIMARY KEY (id) to (id, model, dims),
preserving existing rows. No-op when already migrated."
  (unless (episode-vector-key-p store)
    (exec store "ALTER TABLE episode_vectors RENAME TO episode_vectors_old")
    (exec store "CREATE TABLE episode_vectors (
                   id    INTEGER NOT NULL REFERENCES episodes(id) ON DELETE CASCADE,
                   model TEXT    NOT NULL,
                   dims  INTEGER NOT NULL,
                   vec   BLOB    NOT NULL,
                   PRIMARY KEY (id, model, dims))")
    (exec store "INSERT OR IGNORE INTO episode_vectors (id, model, dims, vec)
                   SELECT id, model, dims, vec FROM episode_vectors_old")
    (exec store "DROP TABLE episode_vectors_old"))
  t)

(defun drop-unstemmed-index (store)
  "Drop EPISODES_FTS if it lacks the porter tokenizer and return T so the caller
recreates and rebuilds it from EPISODES."
  (let ((sql (field (first (query-rows store
                                       "SELECT sql FROM sqlite_master
                                         WHERE name = 'episodes_fts'"))
                    "sql")))
    (when (and sql (not (search "porter" sql)))
      (exec store "DROP TABLE episodes_fts")
      t)))

(declaim (ftype (function (store) integer) schema-version))

(defun schema-version (store)
  "Return the schema version STORE records, 0 for a store that records none."
  (let ((value (field (first (query-rows store "PRAGMA user_version"))
                      "user_version")))
    (if (integerp value) value 0)))

(defun set-schema-version (store version)
  "Record VERSION as STORE's schema version. A pragma takes no parameter, so
the number is written into the statement, and only an integer is accepted."
  (check-type version (integer 0 *))
  (exec store (format nil "PRAGMA user_version = ~D" version)))

(defun schema-current-p (store)
  "Return T when STORE matches +SCHEMA-VERSION+ and has all expected tables and
added columns (version alone can be out of sync after a partial migration)."
  (and (= (schema-version store) +schema-version+)
       (tables-present-p store)
       (added-columns-present-p store)))

(defun open-store (&key path (mode nil) (busy-timeout 15000))
  "Open (or create) the SQLite store at PATH (defaults to *STORE-PATH* then DEFAULT-STORE-PATH).
Enables PRAGMA foreign_keys, sets BUSY-TIMEOUT (ms), refuses newer schema versions,
and runs idempotent schema/migration setup if needed. Applies MODE on new files."
  (let* ((path (pathname (or path *store-path* (default-store-path))))
         (created-p (null (probe-file path)))
         (connection
           (handler-case
               (progn
                 (ensure-directories-exist path)
                 (dbi:connect :sqlite3
                              :database-name (namestring path)
                              :busy-timeout busy-timeout))
             (error (condition)
               (error 'enchiridion.errors:configuration-error
                      :key :memory
                      :detail (format nil "Cannot open the memory store ~A: ~A"
                                      path condition))))))
    (let ((store (%make-store :path path :connection connection
                              :lock (bordeaux-threads:make-recursive-lock
                                     "enchiridion store"))))
      (handler-case
          ;; Foreign keys are per connection and must be enabled before writes.
          (exec store "PRAGMA foreign_keys = ON")
        (error (condition)
          (ignore-errors (dbi:disconnect connection))
          (error 'enchiridion.errors:configuration-error
                 :key :memory
                 :detail (format nil "Cannot open the memory store ~A: ~A"
                                 path condition))))
      ;; Refuse databases from a newer schema version.
      (let ((version (schema-version store)))
        (when (> version +schema-version+)
          (ignore-errors (dbi:disconnect connection))
          (error 'enchiridion.errors:configuration-error
                 :key :memory
                 :detail (format nil "The memory store ~A has schema ~D, but this build knows schema ~D. Run the newer image or restore a backup."
                                 path version +schema-version+))))
      ;; Skip write-locking schema/migration work when the store is already current.
      (unless (schema-current-p store)
        (handler-case
            (with-store-transaction (store)
              (let ((reindex (drop-unstemmed-index store)))
                (dolist (statement +schema+)
                  (exec store statement))
                (add-missing-columns store)
                (when (< (schema-version store) 10)
                  ;; Without a generation, the old watermark could only be a skip
                  (exec store "UPDATE memory_state
                                  SET last_t2_ts = NULL, last_t2_episode = NULL
                                WHERE NOT EXISTS (SELECT 1 FROM generations)"))
                (migrate-episode-vectors store)
                (when reindex
                  (exec store "INSERT INTO episodes_fts(episodes_fts) VALUES ('rebuild')"))))
          (error (condition)
            (ignore-errors (dbi:disconnect connection))
            (error 'enchiridion.errors:configuration-error
                   :key :memory
                   :detail (format nil "Cannot create the memory store schema in ~A: ~A"
                                   path condition))))
        ;; Run legacy turns/memories merge (or create compatibility views on a fresh store).
        (handler-case
            (progn
              (migrate-legacy-memory store)
              (set-schema-version store +schema-version+))
          (error (condition)
            (ignore-errors (dbi:disconnect connection))
            (error 'enchiridion.errors:configuration-error
                   :key :memory
                   :detail (format nil "Cannot merge the old memory tables in ~A: ~A"
                                   path condition)))))
      (when (and created-p mode)
        (enchiridion.compat:set-file-mode path mode))
      store)))

(declaim (ftype (function (store) boolean) close-store))

(defun close-store (store)
  "Disconnect STORE and return T. Closing twice is not an error."
  (let ((connection (store-connection store)))
    (when connection
      (dbi:disconnect connection)
      (setf (store-connection store) nil)
      t)))

;;;; Turns.

;; Transcript row; CHANNEL is a keyword in Lisp and lower-case text in SQLite.
(defstruct (turn-row (:constructor %make-turn-row))
  (id 0 :type integer)
  (session "" :type string)
  (role "" :type string)
  (body "" :type string)
  (model "" :type string)
  (channel :cli :type keyword)
  (ts 0 :type integer))

(defun normalise-role (role)
  "Return ROLE as a lower case string. A keyword and a string are one value."
  (check-type role (or string symbol))
  (string-downcase (string role)))

(defun normalise-channel (channel)
  "Return CHANNEL as a keyword. A keyword and a string are one value."
  (check-type channel (or string symbol))
  (intern (string-upcase (string channel)) :keyword))

(defun turn-row-from (row)
  "Return ROW, one turns row as a plist, as a TURN-ROW."
  (%make-turn-row :id (field row "id")
                  :session (field row "session")
                  :role (field row "role")
                  :body (field row "body")
                  :model (field row "model")
                  :channel (normalise-channel (field row "channel"))
                  :ts (field row "ts")))

(defun turn-context-key (session channel)
  "Return the context_key triple for a transcript row (empty project component;
kept in sync with CONTEXT-KEY-FOR in the memory layer)."
  (format nil ",~A,~A" session (string-downcase (string channel))))

(defun record-turn (store &key session (role "user") (body "") model
                              (channel :cli) (ts (get-universal-time)) final-p)
  "Scrub and insert one turn into EPISODES, returning it as a TURN-ROW.
SESSION defaults to \"default\". FINAL-P is T (1) for final replies, 0 for tool-call
rounds, or NIL when unspecified."
  (check-type body string)
  (check-type session (or null string))
  (check-type ts integer)
  (check-type final-p (or null (eql t) (integer 0 1)))
  (let ((session (scrubbed (or session "default")))
        (role (scrubbed (normalise-role role)))
        (body (scrubbed body))
        (model (scrubbed (or model "")))
        (channel (normalise-channel (scrubbed (string channel)))))
    (check-type model string)
    ;; Hold the lock across INSERT and LAST-ROW-ID so concurrent inserts cannot interleave.
    (with-store-lock (store)
      (exec store
            "INSERT INTO episodes
               (session, role, body, model, ts, channel, provenance, authority,
                cue_type, depth, span, context_key, horizon,
                source_turn_id, source_memory_id, final_p)
               VALUES (?, ?, ?, ?, ?, ?,
                       CASE ? WHEN 'user' THEN 'owner'
                              WHEN 'assistant' THEN 'agent'
                              ELSE 'untrusted' END,
                       CASE ? WHEN 'user' THEN 5
                              WHEN 'assistant' THEN 3
                              ELSE 1 END,
                       'episodic', 0, '', ?, 2592000, NULL, NULL, ?)"
            (list session role body model ts (string-downcase (string channel))
                  role
                  role
                  (turn-context-key session channel)
                  (if (eq final-p t) 1 final-p)))
      (%make-turn-row :id (last-row-id store)
                      :session session
                      :role role
                      :body body
                      :model model
                      :channel channel
                      :ts ts))))

(declaim (ftype (function (store) integer) session-count))

(defun session-count (store)
  "Return the number of distinct transcript sessions (excluding role = 'memory')."
  (or (field (first (query-rows store
                                "SELECT COUNT(DISTINCT session) AS n FROM episodes
                                  WHERE role <> 'memory'"))
             "n")
      0))

(defun recent-sessions (store &key (limit 20))
  "Return the most recently active transcript sessions newest first, each a plist
with :ID, :STARTED, :ENDED, and :TURNS."
  (query-rows store
              "SELECT session AS id,
                      MIN(ts) AS started,
                      MAX(ts) AS ended,
                      COUNT(*) AS turns
                 FROM episodes
                WHERE role <> 'memory'
                GROUP BY session
                ORDER BY ended DESC
                LIMIT ?"
              (list limit)))

(declaim (ftype (function (store t) integer) delete-session))

(defun delete-session (store id)
  "Delete session ID and all its episodes (including saved memories). Return rows removed."
  ;; Delete referencing change_events and assertions first (no ON DELETE CASCADE,
  ;; foreign keys ON); assertion conflicts cascade automatically.
  (with-store-transaction (store)
    (dolist (table '("change_events" "assertions"))
      (exec store
            (format nil "DELETE FROM ~A WHERE episode_id IN
                           (SELECT id FROM episodes WHERE session = ?)"
                    table)
            (list id)))
    (exec store "DELETE FROM episodes WHERE session = ?" (list id))))

(defun search-sessions (store query &key (limit 20))
  "Return turns whose body matches QUERY via FTS5, best match first, as TURN-ROW structs."
  (let ((match (fts-query query)))
    (loop for row in (query-rows store
                                 "SELECT e.id, e.session, e.role, e.body,
                                         e.model, e.channel, e.ts
                                    FROM episodes_fts
                                    JOIN episodes e ON e.id = episodes_fts.rowid
                                   WHERE episodes_fts MATCH ?
                                     AND e.role <> 'memory'
                                   ORDER BY rank
                                   LIMIT ?"
                                 (list match limit))
          collect (turn-row-from row))))

;;;; Memories.

(defun save-memory (store name body &key session (ts (get-universal-time)))
  "Store one scrubbed memory called NAME and return its row id.
An empty body or an exact name/body duplicate is refused. The duplicate check
and insert share a transaction across connections."
  (check-type name string)
  (check-type body string)
  (check-type ts integer)
  (let ((name (scrubbed name))
        (body (scrubbed body))
        (session (scrubbed (or session ""))))
    (when (zerop (length body))
      (error 'enchiridion.errors:configuration-error
             :key :memory :detail "A memory needs text."))
    (with-store-transaction (store)
      (when (query-rows store
                        "SELECT id FROM episodes
                          WHERE role = 'memory' AND name = ? AND body = ?"
                        (list name body))
        (error 'enchiridion.errors:configuration-error
               :key :memory
               :detail (format nil "Memory ~A already holds that text." name)))
      (exec store
            "INSERT INTO episodes
               (session, role, body, model, name, ts, channel, provenance,
                authority, cue_type, depth, span, context_key, horizon,
                source_turn_id, source_memory_id)
               VALUES (?, 'memory', ?, '', ?, ?, 'cli', 'owner', 5,
                       'semantic', 0, '', ?, 2592000, NULL, NULL)"
            (list session body name ts
                  (scrubbed (turn-context-key session :cli))))
      (last-row-id store))))

(defun list-memories (store &key (limit 100))
  "Return stored memories newest first, each a plist with :ID, :NAME, :BODY,
:SESSION, and :TS."
  (query-rows store
              "SELECT id, name, body, session, ts
                 FROM episodes
                WHERE role = 'memory'
                ORDER BY ts DESC, id DESC
                LIMIT ?"
              (list limit)))

(defun search-memories (store query &key (limit 20))
  "Return the memories whose name or body matches QUERY, best match first.
Each entry is a plist with :ID, :NAME, :BODY, :SESSION, and :TS."
  (let ((match (fts-query query))
        (like (format nil "%~A%" query)))
    (query-rows store
                "SELECT e.id, e.name, e.body, e.session, e.ts
                   FROM episodes e
                  WHERE e.role = 'memory'
                    AND (e.id IN (SELECT rowid FROM episodes_fts
                                   WHERE episodes_fts MATCH ?)
                         OR lower(e.name) LIKE lower(?))
                  ORDER BY e.ts DESC, e.id DESC
                  LIMIT ?"
                (list match like limit))))

;;;; The two harness blocks.

(defun stored-block (store name)
  "Return the block called NAME, or an empty string when it was never written."
  (let ((row (first (query-rows store "SELECT body FROM blocks WHERE name = ?"
                                (list name)))))
    (if row (field row "body") "")))

(defun store-block (store name text)
  "Write the block called NAME as TEXT and return the text that was stored."
  (check-type text string)
  (let ((text (scrubbed text)))
    (with-store-lock (store)
      (exec store
            "INSERT OR REPLACE INTO blocks (name, body, ts) VALUES (?, ?, ?)"
            (list name text (get-universal-time)))
      text)))

(declaim (ftype (function (store keyword string) string) store-checked-block))

(defun store-checked-block (store label text)
  "Scan TEXT for prompt injection, enforce DEFAULT-BLOCK-LIMIT (signalling BLOCK-OVERFLOW),
and write harness block LABEL."
  (check-type text string)
  (enchiridion.memory:scan-block-text label text)
  (let ((limit (enchiridion.memory:default-block-limit label)))
    (when (> (length text) limit)
      (error 'enchiridion.errors:block-overflow
             :label label :current limit :wanted (length text))))
  (store-block store (string-downcase (string label)) text))

(declaim (ftype (function (store) string) session-block))

(defun session-block (store)
  "Return the session block: what the agent was doing, as SQLite holds it."
  (stored-block store "session"))

(declaim (ftype (function (store string) string) set-session-block))

(defun set-session-block (store text)
  "Replace the session block with TEXT and return it.
Scanned and limited, because the harness writes this one."
  (store-checked-block store :session text))

(declaim (ftype (function (store) string) ledger-block))

(defun ledger-block (store)
  "Return the ledger block: the token spend of this session."
  (stored-block store "ledger"))

(declaim (ftype (function (store string) string) set-ledger-block))

(defun set-ledger-block (store text)
  "Replace the ledger block with TEXT and return it.
Scanned and limited, because the harness writes this one."
  (store-checked-block store :ledger text))

;;;; The usage ledger.

(defun record-usage (store &key session model input output cache-read cache-write
                             (channel :cli) (ts (get-universal-time)))
  "Scrub metadata and insert one provider token-usage row, returning its row id."
  (let ((session (scrubbed (or session "")))
        (model (scrubbed (or model "")))
        (input (or input 0))
        (output (or output 0))
        (cache-read (or cache-read 0))
        (cache-write (or cache-write 0))
        (channel (normalise-channel (scrubbed (string channel)))))
    (check-type session string)
    (check-type model string)
    (check-type input integer)
    (check-type output integer)
    (check-type cache-read integer)
    (check-type cache-write integer)
    (check-type ts integer)
    (with-store-lock (store)
      (exec store
            "INSERT INTO usage
               (session, model, input, output, cache_read, cache_write, channel, ts)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
            (list session model input output cache-read cache-write
                  (string-downcase (string channel)) ts))
      (last-row-id store))))

(defparameter +usage-columns+
  "id, session, model, input, output, cache_read, cache_write, channel, ts"
  "Column list shared by USAGE-ROWS and USAGE-SINCE.")

(defun usage-select (store where parameters limit)
  "Return ledger rows matching WHERE, oldest first."
  (query-rows store
              (format nil "SELECT ~A FROM usage ~A ORDER BY ts ASC, id ASC LIMIT ?"
                      +usage-columns+ where)
              (append parameters (list limit))))

(defun usage-rows (store &key (limit 1000))
  "Return ledger rows oldest first, each a plist keyed by column name."
  (usage-select store "" nil limit))

(defun usage-since (store since &key (limit 1000))
  "Return ledger rows at or after SINCE, a universal time, oldest first."
  (check-type since integer)
  (usage-select store "WHERE ts >= ?" (list since) limit))

;;;; The ledger, summed.

(declaim (ftype (function (t) list) usage-totals))

(defun usage-totals (row)
  "Return grouped usage totals plist from ROW, coercing non-integers (e.g. SQLite
SUM float overflow or NULL) to 0."
  (flet ((number (name)
           (let ((value (and row (field row name))))
             (if (integerp value) value 0))))
    (list :input (number "input")
          :output (number "output")
          :cache-read (number "cache_read")
          :cache-write (number "cache_write")
          :calls (number "calls")
          :total (+ (number "input") (number "output")))))

(declaim (ftype (function (store &key (:group-by keyword) (:since t) (:limit integer))
                          list)
                usage-summary))

(defun usage-summary (store &key (group-by :model) since (limit 100))
  "Return usage summed by GROUP-BY (:MODEL, :CHANNEL, or :DAY in local calendar time).
GROUP-BY is dispatched via ECASE against fixed SQL expressions."
  (check-type limit (integer 1 *))
  (let* ((column (ecase group-by
                   (:model "model")
                   (:channel "channel")
                   (:day "date(ts - 2208988800, 'unixepoch', 'localtime')")))
         (key (ecase group-by (:model :model) (:channel :channel) (:day :day)))
         (where (if since "WHERE ts >= ?" ""))
         (order (if (eq group-by :day) "grouped DESC" "SUM(input + output) DESC"))
         (rows (query-rows
                store
                (format nil "SELECT ~A AS grouped,
                                    SUM(input) AS input,
                                    SUM(output) AS output,
                                    SUM(cache_read) AS cache_read,
                                    SUM(cache_write) AS cache_write,
                                    COUNT(*) AS calls
                               FROM usage ~A
                              GROUP BY grouped
                              ORDER BY ~A
                              LIMIT ?"
                        column where order)
                (if since (list since limit) (list limit)))))
    (mapcar (lambda (row)
              (append (list key (or (field row "grouped") ""))
                      (usage-totals row)))
            rows)))

(declaim (ftype (function (store integer &key (:channel t) (:channels t)) list)
                usage-total-since))

(defun usage-total-since (store since &key channel channels)
  "Return summed usage totals from universal time SINCE (zeroes when empty),
optionally filtered to CHANNEL or CHANNELS."
  (check-type since integer)
  (let ((channels (if channels (copy-list channels) (and channel (list channel)))))
    (usage-totals
     (first (query-rows store
                        (format nil "SELECT SUM(input) AS input,
                                            SUM(output) AS output,
                                            SUM(cache_read) AS cache_read,
                                            SUM(cache_write) AS cache_write,
                                            COUNT(*) AS calls
                                       FROM usage WHERE ts >= ?~A"
                                (if channels
                                    (format nil " AND channel IN (~{~A~^,~})"
                                            (make-list (length channels)
                                                       :initial-element "?"))
                                    ""))
                        (append (list since)
                                (mapcar (lambda (name)
                                          (string-downcase (string name)))
                                        channels)))))))

(declaim (ftype (function (store t) list) usage-session-total))

(defun usage-session-total (store session)
  "Return every column of the ledger summed for SESSION, a session id."
  (usage-totals
   (first (query-rows store
                      "SELECT SUM(input) AS input, SUM(output) AS output,
                              SUM(cache_read) AS cache_read,
                              SUM(cache_write) AS cache_write,
                              COUNT(*) AS calls
                         FROM usage WHERE session = ?"
                      (list (scrubbed (or session "")))))))

;;;; Turns, newest first.

(declaim (ftype (function (store &key (:limit integer) (:not-channel t)
                                    (:body-chars t))
                          list)
                recent-turns))

(defun recent-turns (store &key (limit 4) not-channel body-chars)
  "Return up to LIMIT transcript turns newest first, optionally excluding NOT-CHANNEL
and truncating bodies in SQL to BODY-CHARS."
  (check-type limit (integer 1 *))
  (let ((rows (if not-channel
                  (query-rows store
                              (format nil "SELECT id, session, role, ~A AS body,
                                                  model, channel, ts
                                             FROM episodes
                                            WHERE role <> 'memory' AND channel <> ?
                                            ORDER BY id DESC LIMIT ?"
                                      (if body-chars
                                          (format nil "substr(body, 1, ~D)" body-chars)
                                          "body"))
                              (list (string-downcase (string not-channel)) limit))
                  (query-rows store
                              (format nil "SELECT id, session, role, ~A AS body,
                                                  model, channel, ts
                                             FROM episodes
                                            WHERE role <> 'memory'
                                            ORDER BY id DESC LIMIT ?"
                                      (if body-chars
                                          (format nil "substr(body, 1, ~D)" body-chars)
                                          "body"))
                              (list limit)))))
    (mapcar #'turn-row-from rows)))

;;;; Disk and log statistics (read-only; tolerates missing tables).

(declaim (ftype (function (t &key (:now t)) list) store-usage))

(defun store-usage (store &key (now (get-universal-time)))
  "Return a plist of on-disk size, reclaimable VACUUM bytes, row counts, and episode
timestamps for STORE, or NIL."
  (when store
    (flet ((first-value (sql)
             ;; A missing table or unreadable pragma is NIL, not an error.
             (ignore-errors
               (let ((row (first (query-rows store sql))))
                 (and row (second row))))))
      (let* ((page-size (or (first-value "PRAGMA page_size") 0))
             (page-count (or (first-value "PRAGMA page_count") 0))
             (free-pages (or (first-value "PRAGMA freelist_count") 0))
             (oldest (first-value "SELECT MIN(ts) FROM episodes"))
             (newest (first-value "SELECT MAX(ts) FROM episodes"))
             (path (store-path store))
             (bytes (ignore-errors
                      (with-open-file (stream path :direction :input
                                                   :element-type '(unsigned-byte 8)
                                                   :if-does-not-exist nil)
                        (and stream (file-length stream))))))
        (list :path (and (pathnamep path) (namestring path))
              :bytes bytes
              :page-size page-size
              :page-count page-count
              :reclaimable-bytes (* page-size free-pages)
              :episodes (or (first-value "SELECT COUNT(*) FROM episodes") 0)
              :usage-rows (or (first-value "SELECT COUNT(*) FROM usage") 0)
              :retrievals (or (first-value "SELECT COUNT(*) FROM retrievals") 0)
              :oldest-ts oldest
              :newest-ts newest
              :oldest-age (and oldest (- now oldest)))))))

;;;; Dropping everything.

(declaim (ftype (function (store) boolean) drop-store))

(defun drop-store (store)
  "Drop all views and tables created by this store and reset user_version to 0.
Leaves the connection open; return T."
  (dolist (view +store-views+)
    (exec store (format nil "DROP VIEW IF EXISTS ~A" view)))
  (dolist (table +store-tables+)
    (exec store (format nil "DROP TABLE IF EXISTS ~A" table)))
  (set-schema-version store 0)
  t)

;;;; Task queue (pending -> running -> done | failed; REMOVE-TASK deletes).

(defstruct (task-row (:constructor %make-task-row))
  (id 0 :type integer)
  (body "" :type string)
  (status :pending :type keyword)
  (ts 0 :type integer))

(declaim (ftype (function (t) keyword) normalise-task-status))

(defun normalise-task-status (status)
  "Return STATUS as an upcased keyword."
  (check-type status (or string symbol))
  (intern (string-upcase (string status)) :keyword))

(declaim (ftype function task-row-from enqueue-task list-tasks dequeue-task
                  remove-task))

(defun task-row-from (row)
  "Return ROW, one tasks row as a plist, as a TASK-ROW."
  (%make-task-row :id (field row "id")
                  :body (field row "body")
                  :status (normalise-task-status (field row "status"))
                  :ts (field row "ts")))

(defun enqueue-task (store body &key (ts (get-universal-time)))
  "Scrub BODY, reject blank text with USAGE-ERROR, insert a :PENDING task, and return TASK-ROW."
  (check-type body string)
  (check-type ts integer)
  (let ((body (scrubbed body)))
    (when (zerop (length (string-trim '(#\Space #\Tab #\Newline #\Return) body)))
      (error 'enchiridion.errors:usage-error :argument body))
    (with-store-lock (store)
      (exec store
            "INSERT INTO tasks (body, status, ts) VALUES (?, 'pending', ?)"
            (list body ts))
      (%make-task-row :id (last-row-id store) :body body :status :pending :ts ts))))

(defun list-tasks (store &key status (limit 100))
  "Return STORE's tasks oldest first, or only the ones with STATUS."
  (check-type limit (integer 1 *))
  (let ((rows (if status
                  (query-rows store
                              "SELECT id, body, status, ts FROM tasks
                                 WHERE status = ? ORDER BY id ASC LIMIT ?"
                              (list (string-downcase (string status)) limit))
                  (query-rows store
                              "SELECT id, body, status, ts FROM tasks
                                 ORDER BY id ASC LIMIT ?"
                              (list limit)))))
    (mapcar #'task-row-from rows)))

(defun dequeue-task (store)
  "Atomically claim the oldest :PENDING task as :RUNNING (via conditional UPDATE,
retrying up to 5 times on contention) and return TASK-ROW, or NIL if none."
  (loop repeat 5
        do (let ((row (first (query-rows store
                                        "SELECT id, body, status, ts FROM tasks
                                           WHERE status = 'pending'
                                           ORDER BY id ASC LIMIT 1"))))
             (when (null row)
               (return nil))
             (let ((task (task-row-from row)))
               (when (plusp (exec store
                                  "UPDATE tasks SET status = 'running'
                                     WHERE id = ? AND status = 'pending'"
                                  (list (task-row-id task))))
                 (setf (task-row-status task) :running)
                 (return task))))
        finally (return nil)))

(declaim (ftype (function (store integer) boolean) complete-task))

(defun complete-task (store id)
  "Mark task ID done and return T when a running task was finished."
  (check-type id integer)
  (plusp (exec store "UPDATE tasks SET status = 'done'
                        WHERE id = ? AND status = 'running'"
               (list id))))

(declaim (ftype (function (store integer) boolean) fail-task))

(defun fail-task (store id)
  "Mark running task ID as :FAILED (at-most-once; never requeued) and return T if updated."
  (check-type id integer)
  (plusp (exec store "UPDATE tasks SET status = 'failed'
                        WHERE id = ? AND status = 'running'"
               (list id))))

(declaim (ftype (function (store) integer) recover-tasks))

(defun recover-tasks (store)
  "Mark all :RUNNING tasks as :FAILED (called at heartbeat start to clear crashed runs)
and return the count updated."
  (exec store "UPDATE tasks SET status = 'failed' WHERE status = 'running'"))

(declaim (ftype (function (store &key (:status t)) integer) count-tasks))

(defun count-tasks (store &key status)
  "Return how many tasks STORE holds, or how many have STATUS."
  (let ((row (if status
                 (first (query-rows store
                                    "SELECT COUNT(*) AS n FROM tasks WHERE status = ?"
                                    (list (string-downcase (string status)))))
                 (first (query-rows store "SELECT COUNT(*) AS n FROM tasks")))))
    (or (field row "n") 0)))

(defun remove-task (store id)
  "Delete task ID and return T when a row was removed."
  (check-type id integer)
  (plusp (exec store "DELETE FROM tasks WHERE id = ?" (list id))))
