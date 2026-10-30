;;;; episodic-ddl.cl --- The episodic memory schema, in dependency order.
;;;;
;;;; This file holds data only: the CREATE statements, the drop order, and the
;;;; view list. It loads before STORE so that OPEN-STORE can create the whole
;;;; schema in one transaction without the store knowing what the memory tables are.
;;;;
;;;; The tables split into four scopes. The episodic log is immutable. Global
;;;; telemetry is append-only or recomputable and is updated by T0 and T1.
;;;; Semantic artifacts are generation-scoped, so a candidate can be built and
;;;; gated without changing the live layer. Control tables hold generations,
;;;; gates, and the operator proposals.
;;;;
;;;; Every table is CREATE TABLE IF NOT EXISTS. No existing store table is
;;;; altered, so an old memory.db gains the new tables on its next open.

(in-package #:enchiridion.memory)

(defparameter *episodic-views*
  '("live_assertions" "live_schemas" "live_summaries" "live_procedures"
    "live_conflicts" "live_change_events" "live_semantic_links")
  "Views that filter a generation-scoped table to the live generation.
DROP-STORE drops these before the tables they read.")

(defparameter *episodic-tables*
  '("generation_checks" "generation_derivations" "conflict_resolutions"
    "conflicts" "assertions" "change_events" "summaries" "procedures"
    "schemas" "episodes_fts" "episodes" "cue_index" "activation" "links"
    "retrievals" "calibration" "canary" "gate_log" "change_proposals"
    "projections" "log_runs" "memory_state" "generations")
  "What DROP-STORE removes, child table before parent table.

The order matters because foreign keys are on. A virtual table is dropped
before the content table it reads, and a child row is dropped before the row it
references.")

(defparameter +episodic-schema+
  (list
   ;; ---- 1. The immutable episodic log -------------------------------
   "CREATE TABLE IF NOT EXISTS episodes (
      id            INTEGER PRIMARY KEY AUTOINCREMENT,
      session       TEXT    NOT NULL,
      role          TEXT    NOT NULL,
      body          TEXT    NOT NULL,
      model         TEXT    NOT NULL DEFAULT '',
      name          TEXT    NOT NULL DEFAULT '',
      ts            INTEGER NOT NULL,
      event_ts      INTEGER,
      channel       TEXT    NOT NULL DEFAULT 'cli',
      provenance    TEXT    NOT NULL DEFAULT 'untrusted',
      origin        TEXT    NOT NULL DEFAULT '',
      authority     INTEGER NOT NULL DEFAULT 1,
      cue_type      TEXT    NOT NULL DEFAULT 'episodic',
      depth         INTEGER NOT NULL DEFAULT 0,
      span          TEXT    NOT NULL DEFAULT '',
      rarity_raw    REAL    NOT NULL DEFAULT 0.0,
      arousal_raw   INTEGER NOT NULL DEFAULT 0,
      context_key   TEXT    NOT NULL DEFAULT '',
      scene_trace   TEXT    NOT NULL DEFAULT '',
      horizon       INTEGER NOT NULL DEFAULT 2592000,
      source_turn_id INTEGER,
      source_memory_id INTEGER,
      derived_ts    INTEGER,
      run_id        INTEGER)"
   "CREATE INDEX IF NOT EXISTS episodes_session ON episodes(session, id)"
   "CREATE INDEX IF NOT EXISTS episodes_ts ON episodes(ts)"
   "CREATE INDEX IF NOT EXISTS episodes_context ON episodes(context_key)"
   "CREATE UNIQUE INDEX IF NOT EXISTS episodes_source_turn
      ON episodes(source_turn_id) WHERE source_turn_id IS NOT NULL"
   "CREATE UNIQUE INDEX IF NOT EXISTS episodes_source_memory
      ON episodes(source_memory_id) WHERE source_memory_id IS NOT NULL"
   "CREATE VIRTUAL TABLE IF NOT EXISTS episodes_fts
      USING fts5(body, content='episodes', content_rowid='id')"
   "CREATE TRIGGER IF NOT EXISTS episodes_ai AFTER INSERT ON episodes BEGIN
      INSERT INTO episodes_fts(rowid, body) VALUES (new.id, new.body);
    END"
   "CREATE TRIGGER IF NOT EXISTS episodes_ad AFTER DELETE ON episodes BEGIN
      INSERT INTO episodes_fts(episodes_fts, rowid, body)
        VALUES ('delete', old.id, old.body);
    END"
   "CREATE TRIGGER IF NOT EXISTS episodes_au AFTER UPDATE ON episodes BEGIN
      INSERT INTO episodes_fts(episodes_fts, rowid, body)
        VALUES ('delete', old.id, old.body);
      INSERT INTO episodes_fts(rowid, body) VALUES (new.id, new.body);
    END"

   ;; ---- 2. Global telemetry -----------------------------------------
   "CREATE TABLE IF NOT EXISTS activation (
      kind        TEXT    NOT NULL,
      id          INTEGER NOT NULL,
      n_enc       INTEGER NOT NULL DEFAULT 0,
      last_enc    INTEGER,
      n_ret       INTEGER NOT NULL DEFAULT 0,
      last_ret    INTEGER,
      created_ts  INTEGER NOT NULL,
      supp        REAL    NOT NULL DEFAULT 0.0,
      supp_ts     INTEGER,
      imp         INTEGER NOT NULL DEFAULT 5,
      distinctness REAL   NOT NULL DEFAULT 0.0,
      PRIMARY KEY (kind, id))"

   "CREATE TABLE IF NOT EXISTS cue_index (
      term      TEXT    NOT NULL,
      kind      TEXT    NOT NULL,
      ref       INTEGER NOT NULL,
      uses      INTEGER NOT NULL DEFAULT 0,
      last_used INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (term, kind, ref))"
   "CREATE INDEX IF NOT EXISTS cue_index_term ON cue_index(term)"
   "CREATE INDEX IF NOT EXISTS cue_index_last ON cue_index(last_used)"

   "CREATE TABLE IF NOT EXISTS links (
      src_kind   TEXT    NOT NULL,
      src        INTEGER NOT NULL,
      dst_kind   TEXT    NOT NULL,
      dst        INTEGER NOT NULL,
      type       TEXT    NOT NULL,
      weight     REAL    NOT NULL DEFAULT 1.0,
      obs        INTEGER NOT NULL DEFAULT 1,
      updated_ts INTEGER NOT NULL,
      run_id     INTEGER NOT NULL DEFAULT 0,
      generation_id INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (src_kind, src, dst_kind, dst, type, generation_id))"
   "CREATE INDEX IF NOT EXISTS links_src ON links(src_kind, src)"
   "CREATE INDEX IF NOT EXISTS links_dst ON links(dst_kind, dst)"
   "CREATE INDEX IF NOT EXISTS links_generation ON links(generation_id)"

   "CREATE TABLE IF NOT EXISTS retrievals (
      id          INTEGER PRIMARY KEY AUTOINCREMENT,
      kind        TEXT    NOT NULL,
      ref         INTEGER NOT NULL,
      ts          INTEGER NOT NULL,
      query_id    TEXT    NOT NULL DEFAULT '',
      cue_type    TEXT    NOT NULL DEFAULT '',
      predicted   REAL,
      observed    INTEGER,
      cue         TEXT    NOT NULL DEFAULT '',
      cue_terms   TEXT    NOT NULL DEFAULT '',
      pack_refs   TEXT    NOT NULL DEFAULT '',
      signal      TEXT    NOT NULL DEFAULT '',
      observed_ts INTEGER,
      generation_id INTEGER NOT NULL DEFAULT 0)"
   "CREATE INDEX IF NOT EXISTS retrievals_ref ON retrievals(kind, ref)"
   "CREATE INDEX IF NOT EXISTS retrievals_generation ON retrievals(generation_id)"

   "CREATE TABLE IF NOT EXISTS calibration (
      id            INTEGER PRIMARY KEY AUTOINCREMENT,
      family        TEXT    NOT NULL,
      ts            INTEGER NOT NULL,
      predicted     REAL    NOT NULL,
      observed      INTEGER NOT NULL,
      features_json TEXT    NOT NULL)"
   "CREATE INDEX IF NOT EXISTS calibration_family ON calibration(family, ts)"

   ;; ---- 3. Generation control ---------------------------------------
   "CREATE TABLE IF NOT EXISTS generations (
      id            INTEGER PRIMARY KEY AUTOINCREMENT,
      number        INTEGER NOT NULL UNIQUE,
      parent_id     INTEGER REFERENCES generations(id),
      status        TEXT    NOT NULL DEFAULT 'building',
      created_ts    INTEGER NOT NULL,
      promoted_ts   INTEGER,
      retired_ts    INTEGER,
      from_episode  INTEGER NOT NULL DEFAULT 0,
      to_episode    INTEGER NOT NULL DEFAULT 0,
      parser_version TEXT   NOT NULL DEFAULT '',
      config_hash   TEXT    NOT NULL DEFAULT '',
      tokens_used   INTEGER NOT NULL DEFAULT 0,
      writes        INTEGER NOT NULL DEFAULT 0,
      promotion_result TEXT NOT NULL DEFAULT '',
      promotion_checked_ts INTEGER,
      quarantine_reason TEXT NOT NULL DEFAULT '',
      detail        TEXT    NOT NULL DEFAULT '')"
   "CREATE INDEX IF NOT EXISTS generations_status ON generations(status, id)"

   "CREATE TABLE IF NOT EXISTS memory_state (
      id                  INTEGER PRIMARY KEY CHECK (id = 1),
      live_generation_id  INTEGER NOT NULL DEFAULT 0,
      last_t2_ts          INTEGER,
      last_t2_generation_id INTEGER,
      canary_hash         TEXT NOT NULL DEFAULT '',
      config_hash         TEXT NOT NULL DEFAULT '')"

   "CREATE TABLE IF NOT EXISTS generation_checks (
      id            INTEGER PRIMARY KEY AUTOINCREMENT,
      generation_id INTEGER NOT NULL REFERENCES generations(id) ON DELETE CASCADE,
      kind          TEXT    NOT NULL,
      result        TEXT    NOT NULL,
      value         REAL,
      detail        TEXT    NOT NULL DEFAULT '',
      ts            INTEGER NOT NULL)"
   "CREATE INDEX IF NOT EXISTS generation_checks_generation
      ON generation_checks(generation_id, kind, id)"

   "CREATE TABLE IF NOT EXISTS generation_derivations (
      generation_id INTEGER NOT NULL REFERENCES generations(id) ON DELETE CASCADE,
      episode_id    INTEGER NOT NULL REFERENCES episodes(id) ON DELETE CASCADE,
      parser_version TEXT   NOT NULL,
      derived_ts    INTEGER NOT NULL,
      PRIMARY KEY (generation_id, episode_id, parser_version))"
   "CREATE INDEX IF NOT EXISTS generation_derivations_episode
      ON generation_derivations(episode_id)"

   ;; ---- 4. Semantic artifacts, generation-scoped --------------------
   "CREATE TABLE IF NOT EXISTS assertions (
      id              INTEGER PRIMARY KEY AUTOINCREMENT,
      generation_id   INTEGER NOT NULL REFERENCES generations(id) ON DELETE CASCADE,
      subject         TEXT    NOT NULL,
      relation        TEXT    NOT NULL,
      object          TEXT    NOT NULL,
      polarity        INTEGER NOT NULL DEFAULT 1,
      episode_id      INTEGER NOT NULL REFERENCES episodes(id),
      span_start      INTEGER NOT NULL DEFAULT 0,
      span_end        INTEGER NOT NULL DEFAULT 0,
      valid_from      INTEGER,
      valid_to        INTEGER,
      tx_from         INTEGER NOT NULL,
      tx_to           INTEGER,
      authority       INTEGER NOT NULL DEFAULT 1,
      authority_basis TEXT    NOT NULL DEFAULT '',
      provenance      TEXT    NOT NULL DEFAULT 'untrusted',
      cue_type        TEXT    NOT NULL DEFAULT 'semantic',
      schema_id       INTEGER REFERENCES schemas(id) DEFERRABLE INITIALLY DEFERRED,
      run_id          INTEGER NOT NULL,
      retired_ts      INTEGER,
      UNIQUE (generation_id, episode_id, span_start, span_end,
              subject, relation, object, run_id))"
   "CREATE INDEX IF NOT EXISTS assertions_key
      ON assertions(generation_id, subject, relation)"
   "CREATE INDEX IF NOT EXISTS assertions_valid
      ON assertions(generation_id, valid_from, valid_to)"
   "CREATE INDEX IF NOT EXISTS assertions_run ON assertions(run_id)"

   "CREATE TABLE IF NOT EXISTS schemas (
      id              INTEGER PRIMARY KEY AUTOINCREMENT,
      generation_id   INTEGER NOT NULL REFERENCES generations(id) ON DELETE CASCADE,
      name            TEXT    NOT NULL,
      slots_json      TEXT    NOT NULL,
      links_json      TEXT    NOT NULL,
      episode_support INTEGER NOT NULL,
      source_spans    TEXT    NOT NULL DEFAULT '[]',
      version         INTEGER NOT NULL DEFAULT 1,
      parent_id       INTEGER REFERENCES schemas(id),
      created_ts      INTEGER NOT NULL,
      retired_ts      INTEGER,
      run_id          INTEGER NOT NULL)"

   "CREATE TABLE IF NOT EXISTS summaries (
      id              INTEGER PRIMARY KEY AUTOINCREMENT,
      generation_id   INTEGER NOT NULL REFERENCES generations(id) ON DELETE CASCADE,
      body            TEXT    NOT NULL,
      source_episode_ids TEXT NOT NULL DEFAULT '',
      source_spans    TEXT    NOT NULL DEFAULT '[]',
      created_ts      INTEGER NOT NULL,
      retired_ts      INTEGER,
      run_id          INTEGER NOT NULL)"

   "CREATE TABLE IF NOT EXISTS procedures (
      id              INTEGER PRIMARY KEY AUTOINCREMENT,
      generation_id   INTEGER NOT NULL REFERENCES generations(id) ON DELETE CASCADE,
      name            TEXT    NOT NULL,
      granularity     TEXT    NOT NULL DEFAULT 'subtask',
      applicable_when TEXT    NOT NULL,
      requires_json   TEXT    NOT NULL DEFAULT '[]',
      produces_json   TEXT    NOT NULL DEFAULT '[]',
      body            TEXT    NOT NULL,
      form            TEXT    NOT NULL DEFAULT 'text',
      trigger_l0      TEXT    NOT NULL DEFAULT '',
      evidence_count  INTEGER NOT NULL DEFAULT 0,
      distinct_tasks  INTEGER NOT NULL DEFAULT 0,
      failures        INTEGER NOT NULL DEFAULT 0,
      admitted_ts     INTEGER,
      retired_ts      INTEGER,
      source_episodes TEXT    NOT NULL DEFAULT '',
      source_spans    TEXT    NOT NULL DEFAULT '[]',
      run_id          INTEGER NOT NULL)"

   "CREATE TABLE IF NOT EXISTS change_events (
      id            INTEGER PRIMARY KEY AUTOINCREMENT,
      generation_id INTEGER NOT NULL REFERENCES generations(id) ON DELETE CASCADE,
      episode_id    INTEGER NOT NULL REFERENCES episodes(id),
      subject       TEXT    NOT NULL,
      relation      TEXT    NOT NULL,
      old_object    TEXT    NOT NULL DEFAULT '',
      new_object    TEXT    NOT NULL,
      event_ts      INTEGER NOT NULL,
      source        TEXT    NOT NULL,
      run_id        INTEGER NOT NULL,
      UNIQUE (generation_id, episode_id, subject, relation))"

   "CREATE TABLE IF NOT EXISTS conflicts (
      id               INTEGER PRIMARY KEY AUTOINCREMENT,
      generation_id    INTEGER NOT NULL REFERENCES generations(id) ON DELETE CASCADE,
      kind             TEXT    NOT NULL,
      left_id          INTEGER NOT NULL REFERENCES assertions(id) ON DELETE CASCADE,
      right_id         INTEGER NOT NULL REFERENCES assertions(id) ON DELETE CASCADE,
      detected_ts      INTEGER NOT NULL,
      basis            TEXT    NOT NULL,
      resolution_state TEXT    NOT NULL DEFAULT 'unresolved',
      resolution       TEXT,
      resolved_ts      INTEGER,
      resolver         TEXT,
      acting_query     TEXT    NOT NULL DEFAULT '',
      run_id           INTEGER NOT NULL,
      retired_ts       INTEGER,
      UNIQUE (generation_id, left_id, right_id, kind))"
   "CREATE INDEX IF NOT EXISTS conflicts_open
      ON conflicts(generation_id, resolution_state, right_id)"

   "CREATE TABLE IF NOT EXISTS conflict_resolutions (
      id            INTEGER PRIMARY KEY AUTOINCREMENT,
      conflict_id   INTEGER NOT NULL REFERENCES conflicts(id) ON DELETE CASCADE,
      generation_id INTEGER NOT NULL,
      query_text    TEXT    NOT NULL DEFAULT '',
      resolution    TEXT    NOT NULL,
      resolver      TEXT    NOT NULL DEFAULT 'action-time',
      reversible    INTEGER NOT NULL DEFAULT 1,
      ts            INTEGER NOT NULL)"

   ;; ---- 5. Operator and evidence -------------------------------------
   "CREATE TABLE IF NOT EXISTS canary (
      id           INTEGER PRIMARY KEY AUTOINCREMENT,
      name         TEXT    NOT NULL UNIQUE,
      expect       TEXT    NOT NULL,
      family       TEXT    NOT NULL DEFAULT '',
      last_pass    INTEGER,
      last_checked INTEGER,
      ts           INTEGER NOT NULL)"

   "CREATE TABLE IF NOT EXISTS gate_log (
      id            INTEGER PRIMARY KEY AUTOINCREMENT,
      arm           TEXT    NOT NULL,
      metric        TEXT    NOT NULL,
      value         REAL    NOT NULL,
      n             INTEGER NOT NULL DEFAULT 0,
      detail        TEXT    NOT NULL DEFAULT '',
      ts            INTEGER NOT NULL,
      generation_id INTEGER NOT NULL DEFAULT 0,
      task_hash     TEXT    NOT NULL DEFAULT '',
      config_hash   TEXT    NOT NULL DEFAULT '')"

   "CREATE TABLE IF NOT EXISTS log_runs (
      id             INTEGER PRIMARY KEY AUTOINCREMENT,
      started_ts     INTEGER NOT NULL,
      finished_ts    INTEGER,
      from_episode   INTEGER NOT NULL,
      to_episode     INTEGER NOT NULL,
      parser_version TEXT    NOT NULL,
      idempotent_key TEXT    NOT NULL UNIQUE,
      status         TEXT    NOT NULL DEFAULT 'running',
      kind           TEXT    NOT NULL DEFAULT 'consolidation',
      config_hash    TEXT    NOT NULL DEFAULT '',
      generation_id  INTEGER NOT NULL DEFAULT 0)"

   "CREATE TABLE IF NOT EXISTS projections (
      id         INTEGER PRIMARY KEY AUTOINCREMENT,
      block      TEXT    NOT NULL,
      from_turn  INTEGER NOT NULL,
      to_turn    INTEGER NOT NULL,
      rebased_p  INTEGER NOT NULL DEFAULT 0,
      model      TEXT    NOT NULL DEFAULT '',
      hash       TEXT    NOT NULL DEFAULT '',
      ts         INTEGER NOT NULL)"

   "CREATE TABLE IF NOT EXISTS change_proposals (
      id            INTEGER PRIMARY KEY AUTOINCREMENT,
      status        TEXT    NOT NULL DEFAULT 'proposed',
      trigger_text  TEXT    NOT NULL,
      evidence_json TEXT    NOT NULL DEFAULT '[]',
      change_text   TEXT    NOT NULL,
      risk          TEXT    NOT NULL DEFAULT '',
      rollback      TEXT    NOT NULL DEFAULT '',
      test_command  TEXT    NOT NULL DEFAULT '',
      created_ts    INTEGER NOT NULL,
      decided_ts    INTEGER,
      operator_note TEXT    NOT NULL DEFAULT '',
      task_id       INTEGER)"

   ;; ---- 6. Live views ------------------------------------------------
   "CREATE VIEW IF NOT EXISTS live_assertions AS
      SELECT a.* FROM assertions a
        JOIN memory_state s ON a.generation_id = s.live_generation_id"
   "CREATE VIEW IF NOT EXISTS live_schemas AS
      SELECT a.* FROM schemas a
        JOIN memory_state s ON a.generation_id = s.live_generation_id"
   "CREATE VIEW IF NOT EXISTS live_summaries AS
      SELECT a.* FROM summaries a
        JOIN memory_state s ON a.generation_id = s.live_generation_id"
   "CREATE VIEW IF NOT EXISTS live_procedures AS
      SELECT a.* FROM procedures a
        JOIN memory_state s ON a.generation_id = s.live_generation_id"
   "CREATE VIEW IF NOT EXISTS live_conflicts AS
      SELECT a.* FROM conflicts a
        JOIN memory_state s ON a.generation_id = s.live_generation_id"
   "CREATE VIEW IF NOT EXISTS live_change_events AS
      SELECT a.* FROM change_events a
        JOIN memory_state s ON a.generation_id = s.live_generation_id"
   "CREATE VIEW IF NOT EXISTS live_semantic_links AS
      SELECT l.* FROM links l
        WHERE l.generation_id = 0
           OR l.generation_id = (SELECT live_generation_id FROM memory_state)")
  "Every episodic table, index, trigger, and view, one statement per element.

The order is dependency order: a content table exists before the FTS table that
reads it, a parent exists before the child that references it, and a view is
created after the tables it reads. Every statement is IF NOT EXISTS, so opening
a store twice changes nothing.")

(defparameter +ext-schema+
  (list
   "CREATE TABLE IF NOT EXISTS cue_index (
      term      TEXT    NOT NULL,
      kind      TEXT    NOT NULL,
      ref       INTEGER NOT NULL,
      uses      INTEGER NOT NULL DEFAULT 0,
      last_used INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (term, kind, ref))"
   "CREATE INDEX IF NOT EXISTS cue_index_term ON cue_index(term)"
   "CREATE INDEX IF NOT EXISTS cue_index_last ON cue_index(last_used)"
   "CREATE TABLE IF NOT EXISTS canary (
      id           INTEGER PRIMARY KEY AUTOINCREMENT,
      name         TEXT    NOT NULL UNIQUE,
      expect       TEXT    NOT NULL,
      family       TEXT    NOT NULL DEFAULT '',
      last_pass    INTEGER,
      last_checked INTEGER,
      ts           INTEGER NOT NULL)"
   "CREATE TABLE IF NOT EXISTS gate_log (
      id            INTEGER PRIMARY KEY AUTOINCREMENT,
      arm           TEXT    NOT NULL,
      metric        TEXT    NOT NULL,
      value         REAL    NOT NULL,
      n             INTEGER NOT NULL DEFAULT 0,
      detail        TEXT    NOT NULL DEFAULT '',
      ts            INTEGER NOT NULL,
      generation_id INTEGER NOT NULL DEFAULT 0,
      task_hash     TEXT    NOT NULL DEFAULT '',
      config_hash   TEXT    NOT NULL DEFAULT '')")
  "The extension's original three tables. Kept as a named sublist so callers
that ask for the extension alone still get what they ask for. The full schema
above already contains them.")

(defparameter *ext-tables*
  '("cue_index" "canary" "gate_log")
  "The extension's three tables, in drop order.")
