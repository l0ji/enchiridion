;;;; store.cl --- SQLite with FTS5: sessions, memories, blocks, and the ledger.
;;;;
;;;; The store is one file. SQLite owns it, FTS5 indexes the raw text, and a
;;;; search returns what was stored rather than a summary of it: no model call
;;;; runs, so recall costs nothing and cannot invent a memory.
;;;;
;;;; Two decisions are worth stating. First, the FTS tables are external
;;;; content tables over the row tables, so each body exists once and three
;;;; triggers per table are what keep the index honest through an insert, an
;;;; update, and a delete. A dropped session that still matches a search is a
;;;; memory the operator cannot get rid of.
;;;;
;;;; Second, every string is scrubbed on the way in. The transcript is readable
;;;; by the agent through the search tool, so this is the last place a secret
;;;; could sit after the scrubber on the way out.
;;;;
;;;; DBI is the binding. Each statement is executed on its own: SQLite prepares
;;;; one statement at a time, so the schema below is a list and not a script.

(in-package #:enchiridion.memory.store)

;;;; The store object.

;; path is the database file and connection is the DBI connection. The accessor
;; is STORE-PATH, the name a caller asks a question with.
(defstruct (store (:constructor %make-store))
  (path #p"" :type pathname)
  (connection nil :type t))

(defparameter *store-path* nil
  "The store a caller gets when OPEN-STORE is not given a path. Main binds this
from the operator configuration, so one process opens one store and the tool
that searches it opens the same file.")

(declaim (ftype (function (&optional t) pathname) default-store-path))

(defun default-store-path (&optional directory)
  "Return the store file for DIRECTORY, or for the agent directory.

Without DIRECTORY the agent directory is ENCHIRIDION_HOME followed by
agents/default/, or the current directory followed by the same when the
variable is unset. The supervisor and the broker run with the same
ENCHIRIDION_HOME, so both resolve one path and a search in the child reads what
the supervisor wrote."
  (let ((home (uiop:getenv "ENCHIRIDION_HOME")))
    (merge-pathnames
     "memory.db"
     (if directory
         (uiop:ensure-directory-pathname directory)
         (merge-pathnames
          "agents/default/"
          (uiop:ensure-directory-pathname
           (if (and home (plusp (length home))) home (uiop:getcwd))))))))

;;;; The schema.
;;;;
;;;; One statement per element, in dependency order: a content table exists
;;;; before the FTS table that reads it, and each trigger is a statement of its
;;;; own even though its body holds semicolons.

(defparameter +schema+
  (list
   "CREATE TABLE IF NOT EXISTS turns (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session TEXT NOT NULL,
      role TEXT NOT NULL,
      body TEXT NOT NULL,
      model TEXT NOT NULL DEFAULT '',
      channel TEXT NOT NULL DEFAULT 'cli',
      ts INTEGER NOT NULL)"
   "CREATE INDEX IF NOT EXISTS turns_session ON turns(session)"
   "CREATE VIRTUAL TABLE IF NOT EXISTS turns_fts
      USING fts5(body, content='turns', content_rowid='id')"
   "CREATE TRIGGER IF NOT EXISTS turns_ai AFTER INSERT ON turns BEGIN
      INSERT INTO turns_fts(rowid, body) VALUES (new.id, new.body);
    END"
   "CREATE TRIGGER IF NOT EXISTS turns_ad AFTER DELETE ON turns BEGIN
      INSERT INTO turns_fts(turns_fts, rowid, body)
        VALUES ('delete', old.id, old.body);
    END"
   "CREATE TRIGGER IF NOT EXISTS turns_au AFTER UPDATE ON turns BEGIN
      INSERT INTO turns_fts(turns_fts, rowid, body)
        VALUES ('delete', old.id, old.body);
      INSERT INTO turns_fts(rowid, body) VALUES (new.id, new.body);
    END"

   "CREATE TABLE IF NOT EXISTS memories (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      body TEXT NOT NULL,
      session TEXT NOT NULL DEFAULT '',
      ts INTEGER NOT NULL)"
   "CREATE INDEX IF NOT EXISTS memories_name ON memories(name)"
   "CREATE VIRTUAL TABLE IF NOT EXISTS memories_fts
      USING fts5(name, body, content='memories', content_rowid='id')"
   "CREATE TRIGGER IF NOT EXISTS memories_ai AFTER INSERT ON memories BEGIN
      INSERT INTO memories_fts(rowid, name, body)
        VALUES (new.id, new.name, new.body);
    END"
   "CREATE TRIGGER IF NOT EXISTS memories_ad AFTER DELETE ON memories BEGIN
      INSERT INTO memories_fts(memories_fts, rowid, name, body)
        VALUES ('delete', old.id, old.name, old.body);
    END"
   "CREATE TRIGGER IF NOT EXISTS memories_au AFTER UPDATE ON memories BEGIN
      INSERT INTO memories_fts(memories_fts, rowid, name, body)
        VALUES ('delete', old.id, old.name, old.body);
      INSERT INTO memories_fts(rowid, name, body)
        VALUES (new.id, new.name, new.body);
    END"

   ;; The session and ledger blocks. They are rows and not Markdown files
   ;; because the harness writes them, not the agent, so they have no diff to
   ;; review and no author to credit.
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
   "CREATE INDEX IF NOT EXISTS usage_ts ON usage(ts)")
  "Every table this store creates, one statement per element. Each is IF NOT
EXISTS, so opening a store is safe on every start and needs no migration for
the shape this milestone defines.")

(defparameter +store-tables+
  '("turns_fts" "turns" "memories_fts" "memories" "blocks" "usage")
  "What DROP-STORE removes, index table before row table. Dropping a table
drops its triggers with it, so this list is also the whole trigger list.")

;;;; Talking to the database.

(declaim (ftype (function (string) string) scrubbed))

(defun scrubbed (text)
  "Return TEXT with every loaded secret and every known secret shape removed.

Every string that reaches a column passes through here, including the ones
that are not prose. A session id, a memory name, a model name, and a block body
are all text, and text is where a secret hides. The store is readable by the
agent through the search tool, so this is the last gate before the disk, and a
column that skips it is a column that leaks."
  (enchiridion.llm.secrets:scrub text))

(declaim (ftype (function (store string &optional list) integer) exec))

(defun exec (store statement &optional parameters)
  "Run one statement on STORE and return the number of rows it changed."
  (dbi:do-sql (store-connection store) statement parameters))

(declaim (ftype (function (list) list) normalise-row))

(defun normalise-row (row)
  "Return ROW with every key upcased.

The driver interns a column name exactly as SQLite spells it, so a row arrives
keyed by :|id| rather than :ID. A key that reads only between bars is a key
nobody types, and the caller that reports a ledger column should be able to
write it the way it appears in this file. One door, one shape."
  (loop for (key value) on row by #'cddr
        collect (intern (string-upcase (symbol-name key)) :keyword)
        collect value))

(declaim (ftype (function (store string &optional list) list) query-rows))

(defun query-rows (store statement &optional parameters)
  "Run one query on STORE and return every row as a plist keyed by column."
  (let ((query (dbi:prepare (store-connection store) statement)))
    (dbi:execute query parameters)
    (mapcar #'normalise-row (dbi:fetch-all query))))

(declaim (ftype (function (t string) t) field))

(defun field (row name)
  "Return column NAME of ROW, a plist the driver keyed by the column name."
  (getf row (intern (string-upcase name) :keyword)))

(declaim (ftype (function (store) integer) last-row-id))

(defun last-row-id (store)
  "Return the row id the most recent insert on STORE's connection created."
  (field (first (query-rows store "SELECT last_insert_rowid() AS id")) "id"))

;;;; The search string.

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
  "Return TEXT as an FTS5 MATCH string, or signal a schema error.

Every whitespace separated term becomes a quoted prefix query, so an operator
character in the operator's text is a literal and never a syntax error: the
model asks for C++ and gets a search rather than a backtrace. A term with no
alphanumeric character carries nothing to match and is dropped, and a query
that is left with no terms at all is a schema error rather than a query that
silently matches everything."
  (let ((terms (remove-if (lambda (term)
                            (notany #'alphanumericp term))
                          (uiop:split-string text
                                             :separator '(#\Space #\Tab #\Newline #\Return)))))
    (when (null terms)
      (error 'enchiridion.errors:schema-error
             :detail "The query has no searchable terms."))
    (format nil "~{~A~^ ~}" (mapcar #'quote-term terms))))

;;;; Opening and closing.

(defun open-store (&key path (mode nil) (busy-timeout 5000))
  "Open, and create when absent, the store at PATH. Return the store.

PATH defaults to *STORE-PATH* and then to DEFAULT-STORE-PATH. The schema is
created only when it is missing, so every start may call this.

MODE, when it is an integer such as #o666, is applied to a file this call
created. The supervisor runs as root and the broker as uid 1000, and SQLite
cannot lock a file its user cannot write; the mode is how the file the
supervisor creates stays usable by the child that has to search it. Nothing
in the store is a secret, because every string is scrubbed before it is
written, so widening the mode on a file only that pair of users can reach is
not an exposure."
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
    (let ((store (%make-store :path path :connection connection)))
      (handler-case
          (dolist (statement +schema+)
            (exec store statement))
        (error (condition)
          (ignore-errors (dbi:disconnect connection))
          (error 'enchiridion.errors:configuration-error
                 :key :memory
                 :detail (format nil "Cannot create the memory store schema in ~A: ~A"
                                 path condition))))
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

;; id is the row id, session groups one conversation, role is user, assistant,
;; or tool, body is the raw text, model is what answered, and ts is a universal
;; time. channel is a keyword in Lisp and a lower case string in the table.
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

(defun record-turn (store &key session (role "user") (body "") model
                              (channel :cli) (ts (get-universal-time)))
  "Store one raw message and return it as a TURN-ROW.

SESSION groups the turns of one conversation and defaults to the single name
DEFAULT. Every string in the row is scrubbed, the session id and the role
included: the store is readable by the agent through the search tool, so a
secret that reached a turn must not reach the disk, whatever field it sits in."
  (check-type body string)
  (check-type session (or null string))
  (check-type ts integer)
  (let ((session (scrubbed (or session "default")))
        (role (scrubbed (normalise-role role)))
        (body (scrubbed body))
        (model (scrubbed (or model "")))
        (channel (normalise-channel (scrubbed (string channel)))))
    (check-type model string)
    (exec store
          "INSERT INTO turns (session, role, body, model, channel, ts)
             VALUES (?, ?, ?, ?, ?, ?)"
          (list session role body model (string-downcase (string channel)) ts))
    (%make-turn-row :id (last-row-id store)
                    :session session
                    :role role
                    :body body
                    :model model
                    :channel channel
                    :ts ts)))

(declaim (ftype (function (store) integer) session-count))

(defun session-count (store)
  "Return how many distinct sessions the store holds."
  (or (field (first (query-rows store
                                "SELECT COUNT(DISTINCT session) AS n FROM turns"))
             "n")
      0))

(defun recent-sessions (store &key (limit 20))
  "Return the most recently active sessions, newest first.

Each entry is a plist with :ID, :STARTED, :ENDED, and :TURNS. A session exists
once it has one turn, so there is no session row to fall out of step with the
turns it counts."
  (query-rows store
              "SELECT session AS id,
                      MIN(ts) AS started,
                      MAX(ts) AS ended,
                      COUNT(*) AS turns
                 FROM turns
                GROUP BY session
                ORDER BY ended DESC
                LIMIT ?"
              (list limit)))

(declaim (ftype (function (store t) integer) delete-session))

(defun delete-session (store id)
  "Delete session ID and every turn in it. Return the turns removed."
  (exec store "DELETE FROM turns WHERE session = ?" (list id)))

(defun search-sessions (store query &key (limit 20))
  "Return the turns whose body matches QUERY, best match first, newest ties last.

The row is returned whole: the text, the role, and the session. Nothing is
summarised, because a summary of a transcript is a model call that costs
tokens and can be wrong."
  (let ((match (fts-query query)))
    (loop for row in (query-rows store
                                 "SELECT t.id, t.session, t.role, t.body, t.model, t.channel, t.ts
                                    FROM turns_fts
                                    JOIN turns t ON t.id = turns_fts.rowid
                                   WHERE turns_fts MATCH ?
                                   ORDER BY rank
                                   LIMIT ?"
                                 (list match limit))
          collect (turn-row-from row))))

;;;; Memories.

(defun save-memory (store name body &key session (ts (get-universal-time)))
  "Store one memory called NAME and return its row id.

An exact duplicate is refused, the way a block write is: a write that changes
nothing is a turn spent for no memory. An empty body after the scrub is
refused too, because a memory that holds nothing is a match the operator
cannot read. The name is scrubbed as well as the body: a name is text, and a
name is searchable."
  (check-type name string)
  (check-type body string)
  (check-type ts integer)
  (let ((name (scrubbed name))
        (body (scrubbed body)))
    (cond
      ((zerop (length body))
       (error 'enchiridion.errors:configuration-error
              :key :memory
              :detail "A memory needs text."))
      ((query-rows store "SELECT id FROM memories WHERE name = ? AND body = ?"
                   (list name body))
       (error 'enchiridion.errors:configuration-error
              :key :memory
              :detail (format nil "Memory ~A already holds that text." name)))
      (t
       (exec store
             "INSERT INTO memories (name, body, session, ts) VALUES (?, ?, ?, ?)"
             (list name body (or session "") ts))
       (last-row-id store)))))

(defun list-memories (store &key (limit 100))
  "Return stored memories newest first, each a plist with :ID, :NAME, :BODY,
:SESSION, and :TS."
  (query-rows store
              "SELECT id, name, body, session, ts
                 FROM memories
                ORDER BY ts DESC, id DESC
                LIMIT ?"
              (list limit)))

(defun search-memories (store query &key (limit 20))
  "Return the memories whose name or body matches QUERY, best match first.
Each entry is a plist with :ID, :NAME, :BODY, :SESSION, and :TS."
  (let ((match (fts-query query)))
    (query-rows store
                "SELECT m.id, m.name, m.body, m.session, m.ts
                   FROM memories_fts
                   JOIN memories m ON m.id = memories_fts.rowid
                  WHERE memories_fts MATCH ?
                  ORDER BY rank
                  LIMIT ?"
                (list match limit))))

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
    (exec store
          "INSERT OR REPLACE INTO blocks (name, body, ts) VALUES (?, ?, ?)"
          (list name text (get-universal-time)))
    text))

(declaim (ftype (function (store) string) session-block))

(defun session-block (store)
  "Return the session block: what the agent was doing, as SQLite holds it."
  (stored-block store "session"))

(declaim (ftype (function (store string) string) set-session-block))

(defun set-session-block (store text)
  "Replace the session block with TEXT and return it.

The character limit and the injection scan live in the block layer, which
knows the label and the limit; this layer stores what it is given."
  (store-block store "session" text))

(declaim (ftype (function (store) string) ledger-block))

(defun ledger-block (store)
  "Return the ledger block: the token spend of this session."
  (stored-block store "ledger"))

(declaim (ftype (function (store string) string) set-ledger-block))

(defun set-ledger-block (store text)
  "Replace the ledger block with TEXT and return it."
  (store-block store "ledger" text))

;;;; The usage ledger.

(defun record-usage (store &key session model input output cache-read cache-write
                             (channel :cli) (ts (get-universal-time)))
  "Add one token ledger row and return its row id.

The four numbers are what a provider reported, and nothing here is derived.
The usage report sums these rows, so a row that lost a column is a report that
lies. SESSION, MODEL, and CHANNEL are scrubbed like every other string this
file writes, because a model name is text and text can hold a key."
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
    (exec store
          "INSERT INTO usage
             (session, model, input, output, cache_read, cache_write, channel, ts)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
          (list session model input output cache-read cache-write
                (string-downcase (string channel)) ts))
    (last-row-id store)))

(defparameter +usage-columns+
  "id, session, model, input, output, cache_read, cache_write, channel, ts"
  "The ledger columns in one place, so the two readers below cannot disagree
about the shape of a row the report sums.")

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

;;;; Dropping everything.

(declaim (ftype (function (store) boolean) drop-store))

(defun drop-store (store)
  "Drop every table this store created and return T.

The connection stays open, so a caller that wants the schema back calls
OPEN-STORE again. Tests use this; the sessions command will use it to forget."
  (dolist (table +store-tables+)
    (exec store (format nil "DROP TABLE IF EXISTS ~A" table)))
  t)
