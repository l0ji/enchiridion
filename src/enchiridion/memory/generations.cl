;;;; generations.cl --- Candidate generations and promotion.
;;;;
;;;; A generation is a versioned set of semantic derived rows. A T2 pass writes
;;;; a candidate generation and leaves the live layer alone. Promotion swaps one
;;;; pointer in one transaction; rollback swaps it back. Phase 2 builds a
;;;; candidate from the whole log for simplicity; an incremental copy of the
;;;; live generation is a later optimisation, not a change to the read contract.
;;;;
;;;; This file does not run a model. It calls *ASSERTION-DERIVER*, which is the
;;;; model-dependent seam. With no deriver installed, BUILD-CANDIDATE reports
;;;; :no-deriver and writes nothing.

(in-package #:enchiridion.memory)

(defparameter *memory-parser-version* "episodic-1"
  "The parser version recorded on a generation and on every derivation.
Changing it makes a later build re-derive every episode instead of reusing the
old watermark.")

(defparameter *memory-config-hash* ""
  "The configuration hash recorded on a generation. A later phase fills it from
CONFIG-DIGEST; the empty string is the valid first value.")

(defstruct (change-event (:constructor make-change-event))
  (episode-id 0 :type integer)
  (subject "" :type string)
  (relation "" :type string)
  (old-object "" :type string)
  (new-object "" :type string)
  (event-ts 0 :type integer)
  (source "owner" :type string))

(defun ensure-generation-state (store)
  "Create the single memory state row when it is absent. Return T."
  (enchiridion.memory.store:exec
   store
   "INSERT OR IGNORE INTO memory_state
      (id, live_generation_id, last_t2_ts, last_t2_generation_id,
       canary_hash, config_hash)
      VALUES (1, 0, NULL, NULL, '', '')")
  t)

(defun current-building-generation (store)
  "Return the id of the newest generation still building, or NIL."
  (let ((row (first (enchiridion.memory.store:query-rows
                     store
                     "SELECT id FROM generations
                       WHERE status = 'building'
                       ORDER BY id DESC LIMIT 1"))))
    (and row (enchiridion.memory.store:field row "id"))))

(defun table-columns (store table)
  "Return the column names of TABLE, in declaration order."
  (mapcar (lambda (row) (enchiridion.memory.store:field row "name"))
          (enchiridion.memory.store:query-rows
           store (format nil "PRAGMA table_info(~A)" table))))

(defun copy-generation-rows (store table from to &key (remap (constantly nil)))
  "Copy TABLE's rows of generation FROM into generation TO and return a hash
table of old id to new id, empty for a table with no id column.

The columns come from the table itself, so a column added to the schema is
copied without a change here. REMAP is called with a column name, the row, the
value, and this copy's own map so far, and returns the replacement or NIL to
keep the value: it is how a reference to a row this copy renumbered follows the
row. Rows are copied in id order, so a row that names an earlier row of the same
table, a schema's parent, finds it in the map."
  (let* ((columns (table-columns store table))
         (id-p (member "id" columns :test #'string=))
         (copied (remove-if (lambda (c) (member c '("id" "generation_id")
                                                :test #'string=))
                            columns))
         (statement (format nil "INSERT INTO ~A (generation_id~{, ~A~}) VALUES (?~:*~{, ?~*~})"
                            table copied))
         (map (make-hash-table)))
    (dolist (row (enchiridion.memory.store:query-rows
                  store
                  (format nil "SELECT * FROM ~A WHERE generation_id = ? ORDER BY rowid"
                          table)
                  (list from)))
      (enchiridion.memory.store:exec
       store statement
       (cons to (mapcar (lambda (column)
                          (let ((value (enchiridion.memory.store:field row column)))
                            (or (funcall remap column row value map) value)))
                        copied)))
      (when id-p
        (setf (gethash (enchiridion.memory.store:field row "id") map)
              (enchiridion.memory.store:last-row-id store))))
    map))

(defun copy-live-generation (store from to)
  "Copy generation FROM's semantic layer into generation TO, renumbering every
reference so the copy points at its own rows and never at FROM's.

Schemas go first, because assertions and later schemas name them; assertions
next, because conflicts and semantic links name them. The derivation marks go
too, which is what makes the candidate derive only what FROM never saw."
  (let* ((schemas (copy-generation-rows
                   store "schemas" from to
                   :remap (lambda (column row value own)
                            (declare (ignore row))
                            (and (string= column "parent_id") value
                                 (gethash value own)))))
         (assertions (copy-generation-rows
                      store "assertions" from to
                      :remap (lambda (column row value own)
                               (declare (ignore row own))
                               (and (string= column "schema_id") value
                                    (gethash value schemas))))))
    (copy-generation-rows store "summaries" from to)
    (copy-generation-rows store "procedures" from to)
    (copy-generation-rows store "change_events" from to)
    (copy-generation-rows
     store "conflicts" from to
     :remap (lambda (column row value own)
              (declare (ignore row own))
              (and (member column '("left_id" "right_id") :test #'string=)
                   (gethash value assertions))))
    (copy-generation-rows
     store "links" from to
     :remap (lambda (column row value own)
              (declare (ignore own))
              (let ((kind (cond ((string= column "src")
                                 (enchiridion.memory.store:field row "src_kind"))
                                ((string= column "dst")
                                 (enchiridion.memory.store:field row "dst_kind")))))
                (cond ((equal kind "assertion") (gethash value assertions))
                      ((equal kind "schema") (gethash value schemas))))))
    (copy-generation-rows store "generation_derivations" from to)
    (hash-table-count assertions)))

(defun start-candidate (store &key (parser-version *memory-parser-version*)
                                   (config-hash *memory-config-hash*)
                                   (rebuild nil))
  "Create a building generation and return its id.

The parent is the live generation, or NIL when none has been promoted. A
candidate starts as a copy of the live semantic layer, derivation marks
included, so the builder derives only the episodes the live generation never
saw and a pass costs what the log grew by, not what the log holds. A first
generation starts empty. REBUILD starts empty even with a live parent, so the
whole log is derived again; it is the operator's choice, never the schedule's."
  (ensure-generation-state store)
  (enchiridion.memory.store:with-store-transaction (store)
    (let* ((parent (live-generation-id store))
           (copy-p (and (plusp parent) (not rebuild)))
           (from (if copy-p
                     (or (enchiridion.memory.store:field
                          (generation-row store parent) "to_episode")
                         0)
                     0))
           (number (or (enchiridion.memory.store:field
                        (first (enchiridion.memory.store:query-rows
                                store
                                "SELECT COALESCE(MAX(number), 0) + 1 AS n
                                   FROM generations"))
                        "n")
                       1))
           (now (get-universal-time)))
      (enchiridion.memory.store:exec
       store
       "INSERT INTO generations
          (number, parent_id, status, created_ts, from_episode, to_episode,
           parser_version, config_hash)
          VALUES (?, ?, 'building', ?, ?, ?, ?, ?)"
       (list number (and (plusp parent) parent) now from from
             parser-version config-hash))
      (let ((id (enchiridion.memory.store:last-row-id store)))
        (when copy-p
          (copy-live-generation store parent id))
        id))))

(defun generation-row (store generation-id)
  "Return one generation row as a plist, or NIL."
  (first (enchiridion.memory.store:query-rows
          store
          "SELECT * FROM generations WHERE id = ?"
          (list generation-id))))

(defun set-generation-status (store generation-id status &key detail)
  "Set one generation status and optional detail. Return T."
  (plusp (enchiridion.memory.store:exec
          store
          "UPDATE generations SET status = ?, detail = ? WHERE id = ?"
          (list status (or detail "") generation-id))))

(defun candidate-episodes (store generation-id limit)
  "Return episodes this generation has not derived yet, oldest first."
  (mapcar #'episode-from-row
          (enchiridion.memory.store:query-rows
           store
           "SELECT e.id, e.session, e.role, e.body, e.ts, e.event_ts,
                   e.channel, e.provenance, e.origin, e.authority,
                   e.cue_type, e.depth, e.span, e.rarity_raw, e.arousal_raw,
                   e.context_key, e.scene_trace, e.horizon
              FROM episodes e
             WHERE NOT EXISTS
                   (SELECT 1 FROM generation_derivations d
                     WHERE d.generation_id = ? AND d.episode_id = e.id)
             ORDER BY e.id ASC
             LIMIT ?"
           (list generation-id (max 1 limit)))))

(defun unprocessed-episode-count (store generation-id)
  "Return how many episodes generation GENERATION-ID has not derived."
  (or (enchiridion.memory.store:field
       (first (enchiridion.memory.store:query-rows
               store
               "SELECT COUNT(*) AS n FROM episodes e
                 WHERE NOT EXISTS
                       (SELECT 1 FROM generation_derivations d
                         WHERE d.generation_id = ? AND d.episode_id = e.id)"
               (list generation-id)))
       "n")
      0))

(defun mark-derived (store generation-id episode-id parser-version)
  "Record that GENERATION-ID derived EPISODE-ID. A rerun is a no-op."
  (enchiridion.memory.store:exec
   store
   "INSERT OR IGNORE INTO generation_derivations
      (generation_id, episode_id, parser_version, derived_ts)
      VALUES (?, ?, ?, ?)"
   (list generation-id episode-id parser-version (get-universal-time))))

(defun insert-assertion (store assertion generation-id run-id)
  "Insert ASSERTION under GENERATION-ID and return its new row id.
A span that is empty, reversed, or outside the episode body is refused by
SPAN-VALID-P before this function is called."
  (let ((tx-from (if (plusp (assertion-tx-from assertion))
                     (assertion-tx-from assertion)
                     (get-universal-time))))
    (enchiridion.memory.store:exec
     store
     "INSERT INTO assertions
        (generation_id, subject, relation, object, polarity, episode_id,
         span_start, span_end, valid_from, valid_to, tx_from, tx_to,
         authority, authority_basis, provenance, cue_type, schema_id, run_id,
         retired_ts)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
     (list generation-id
           (assertion-subject assertion)
           (assertion-relation assertion)
           (assertion-object assertion)
           (assertion-polarity assertion)
           (assertion-episode-id assertion)
           (assertion-span-start assertion)
           (assertion-span-end assertion)
           (assertion-valid-from assertion)
           (assertion-valid-to assertion)
           tx-from
           (assertion-tx-to assertion)
           (assertion-authority assertion)
           (assertion-authority-basis assertion)
           (assertion-provenance assertion)
           (assertion-cue-type assertion)
           (assertion-schema-id assertion)
           (if (plusp run-id) run-id generation-id)
           nil))
    (enchiridion.memory.store:last-row-id store)))

(defun span-valid-p (assertion episode)
  "Return T when ASSERTION's span is a non-empty span inside EPISODE's body."
  (let ((start (assertion-span-start assertion))
        (end (assertion-span-end assertion))
        (length (length (or (episode-body episode) ""))))
    (and (integerp start) (integerp end)
         (<= 0 start) (< start end) (<= end length))))

(defun insert-change-event (store event generation-id run-id)
  "Insert one CHANGE-EVENT under GENERATION-ID and return its row id."
  (enchiridion.memory.store:exec
   store
   "INSERT OR IGNORE INTO change_events
      (generation_id, episode_id, subject, relation, old_object, new_object,
       event_ts, source, run_id)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)"
   (list generation-id
         (change-event-episode-id event)
         (change-event-subject event)
         (change-event-relation event)
         (change-event-old-object event)
         (change-event-new-object event)
         (change-event-event-ts event)
         (change-event-source event)
         (if (plusp run-id) run-id generation-id)))
  (enchiridion.memory.store:last-row-id store))

(defun change-event-present-p (store generation-id assertion)
  "Return T when GENERATION-ID holds a change event for ASSERTION's episode."
  (not (null (enchiridion.memory.store:query-rows
              store
              "SELECT id FROM change_events
                WHERE generation_id = ? AND episode_id = ?
                  AND subject = ? AND relation = ?
                LIMIT 1"
              (list generation-id (assertion-episode-id assertion)
                    (assertion-subject assertion)
                    (assertion-relation assertion))))))

(defun insert-conflict (store conflict generation-id run-id)
  "Insert CONFLICT under GENERATION-ID and return the rows changed.
The table's unique pair key makes a duplicate detection a no-op."
  (enchiridion.memory.store:exec
   store
   "INSERT OR IGNORE INTO conflicts
      (generation_id, kind, left_id, right_id, detected_ts, basis,
       resolution_state, resolution, resolved_ts, resolver, acting_query,
       run_id, retired_ts)
      VALUES (?, ?, ?, ?, ?, ?, 'unresolved', NULL, NULL, NULL, '', ?, NULL)"
   (list generation-id
         (conflict-kind conflict)
         (conflict-left-id conflict)
         (conflict-right-id conflict)
         (conflict-detected-ts conflict)
         (conflict-basis conflict)
         (if (plusp run-id) run-id generation-id))))

(defun candidate-existing-assertions (store generation-id assertion)
  "Return the live assertions in GENERATION-ID with the same subject and relation."
  (mapcar #'assertion-from-row
          (enchiridion.memory.store:query-rows
           store
           "SELECT * FROM assertions
             WHERE generation_id = ? AND subject = ? AND relation = ?
               AND tx_to IS NULL AND retired_ts IS NULL AND id <> ?"
           (list generation-id
                 (assertion-subject assertion)
                 (assertion-relation assertion)
                 (assertion-id assertion)))))

(defun detect-candidate-conflicts (store generation-id assertion now)
  "Detect ASSERTION's conflicts in GENERATION-ID and return a plist of counts.
An update closes the old interval; every other pair becomes a conflict row.
The change-event test is a SQL query over the candidate, not a model call."
  (let ((existing (candidate-existing-assertions store generation-id assertion))
        (conflicts 0)
        (closed 0))
    (when existing
      (multiple-value-bind (new-conflicts superseded)
          (detect-conflicts assertion existing
                            :now now
                            :change-event-p (change-event-present-p
                                             store generation-id assertion)
                            :continuing-evidence-p nil)
        (dolist (conflict new-conflicts)
          (when (plusp (insert-conflict store conflict generation-id generation-id))
            (incf conflicts)))
        (dolist (old superseded)
          (enchiridion.memory.store:exec
           store
           "UPDATE assertions SET tx_to = ? WHERE id = ?"
           (list now (assertion-id old)))
          (incf closed))))
    (list :conflicts conflicts :closed closed)))

(defun derive-one (store deriver episode)
  "Call DERIVER on EPISODE and return a plist: :ASSERTIONS and :EVENTS, or
:ERROR with the report line, and :TOKENS either way. It binds the token count
itself, so it gives the same answer in a worker thread, where the caller's
dynamic bindings do not reach."
  (let ((*derivation-tokens* 0))
    (handler-case
        (multiple-value-bind (assertions events) (funcall deriver store episode)
          (list :assertions assertions :events events :tokens *derivation-tokens*))
      (error (condition)
        (list :error (enchiridion.errors:condition-report-line condition)
              :tokens *derivation-tokens*)))))

(defun derive-concurrently (store episodes &key (deriver *assertion-deriver*)
                                                (concurrency *t2-deriver-concurrency*)
                                                (attempts 2))
  "Return DERIVE-ONE's plist for each of EPISODES, in their order, with up to
CONCURRENCY model calls in flight at once. A failed call goes back on the
queue until it has had ATTEMPTS tries, and its result carries the tokens of
every try.

The retry is in the pool and not a second round after it: a round waits for
its slowest call, so a batch with a retry round idled through two tails, which
on the trial was three minutes in a row with no call in flight.

A deriver call is almost all waiting on the provider, and one episode's call
does not depend on another's result: the deriver reads the raw log, never the
candidate. So the calls overlap, and every store access inside them takes the
store's lock. Applying the results stays in the caller, one at a time and in
episode order, because conflict detection depends on that order. A worker
that dies without a result leaves NIL, which the caller reads as a failure."
  (let* ((items (coerce episodes 'vector))
         (n (length items))
         (results (make-array n :initial-element nil))
         (tries (make-array n :initial-element 0))
         (spent (make-array n :initial-element 0))
         (queue (loop for i below n collect i))
         (lock (bordeaux-threads:make-lock "t2-deriver-queue")))
    (flet ((work ()
             (loop
               (let ((i (bordeaux-threads:with-lock-held (lock) (pop queue))))
                 (unless i (return))
                 (let ((result (derive-one store deriver (aref items i))))
                   (bordeaux-threads:with-lock-held (lock)
                     (incf (aref tries i))
                     (incf (aref spent i) (or (getf result :tokens) 0))
                     (setf (aref results i) result)
                     ;; The worker that puts it back is still looping, so the
                     ;; retry is picked up even when every other worker is done.
                     (when (and (getf result :error) (< (aref tries i) attempts))
                       (setf queue (append queue (list i))))))))))
      (if (or (<= concurrency 1) (<= n 1))
          (work)
          (mapc #'bordeaux-threads:join-thread
                (loop repeat (min concurrency n)
                      collect (bordeaux-threads:make-thread #'work :name "t2-deriver")))))
    (loop for i below n
          for result = (aref results i)
          collect (and result (list* :tokens (aref spent i)
                                     (alexandria:remove-from-plist result :tokens))))))

(defun apply-derivation (store episode generation-id parser-version now assertions events)
  "Write one episode's derived ASSERTIONS and EVENTS into GENERATION-ID, mark
the episode derived, and return a report plist."
    (let ((accepted 0)
          (rejected 0)
          (conflicts 0)
          (closed 0))
      (let ((inserted '()))
        (dolist (assertion assertions)
          (if (span-valid-p assertion episode)
              (let ((id (insert-assertion store assertion generation-id
                                          generation-id)))
                (setf (assertion-id assertion) id)
                (push assertion inserted)
                (incf accepted))
              (incf rejected)))
        (dolist (event events)
          (insert-change-event store event generation-id generation-id))
        (dolist (assertion (nreverse inserted))
          (let ((report (detect-candidate-conflicts store generation-id
                                                    assertion now)))
            (incf conflicts (getf report :conflicts))
            (incf closed (getf report :closed)))))
      (mark-derived store generation-id (episode-id episode) parser-version)
      (list :assertions accepted :rejected rejected
            :conflicts conflicts :closed closed)))

(defun build-candidate (store &key (limit *memory-t2-episodes-per-tick*)
                                  (parser-version *memory-parser-version*)
                                  (config-hash *memory-config-hash*)
                                  (rebuild nil))
  "Build or resume a candidate generation and return a report plist.
With no deriver installed the function reports :no-deriver and writes nothing.
The build is resumable: a limited batch leaves the generation in :building and
the next call continues the same generation. A new candidate copies the live
layer and derives what is new; REBUILD starts it empty instead, and has no
effect on a build already under way."
  (cond
    ((null store) (list :built nil :reason :no-store))
    ((not (enabled-p)) (list :built nil :reason :disabled))
    ((null *assertion-deriver*) (list :built nil :reason :no-deriver))
    (t
     (ensure-generation-state store)
     (let* ((generation-id (or (current-building-generation store)
                               (start-candidate store
                                                :parser-version parser-version
                                                :config-hash config-hash
                                                :rebuild rebuild)))
            (episodes (candidate-episodes store generation-id limit))
            (now (get-universal-time))
            (accepted 0) (rejected 0) (conflicts 0) (closed 0)
            (tokens 0) (derived '()) (failure nil) (failure-note nil) (skipped 0))
       ;; A failed deriver call ends the batch, and the counters below still
       ;; record the episodes derived before it: they have their rows and their
       ;; marks, and a gate that read counters without them would undercount.
       ;; The failed episode is not marked, so the next tick tries it again.
       ;; The model calls run concurrently; the results are applied here, in
       ;; episode order, and every call's tokens count. A failed call is tried
       ;; once more. An episode that fails twice is marked derived with nothing
       ;; written, so it stays an episode and the batch goes on: stopping at
       ;; the first failure threw away every paid result after it, which on a
       ;; trial batch of 96 was 98 of 105 calls, and an episode that always
       ;; fails would stop every batch at the same place. When most of a batch
       ;; fails the provider is the problem and not the episodes, so nothing
       ;; past the first failure is applied or marked, and the next tick tries.
       (let ((results (derive-concurrently store episodes)))
         (dolist (result results) (incf tokens (or (getf result :tokens) 0)))
         (let ((outage (> (* 2 (count-if (lambda (r) (or (null r) (getf r :error))) results))
                          (length results))))
           (loop for episode in episodes
                 for result in results
                 for error = (or (null result) (getf result :error))
                 do (cond
                      (failure)
                      ((and error outage)
                       (setf failure (or (getf result :error) "the deriver returned nothing")))
                      (error
                       (unless failure-note
                         (setf failure-note (or (getf result :error) "the deriver returned nothing")))
                       (incf skipped)
                       (push episode derived)
                       (apply-derivation store episode generation-id parser-version now nil nil))
                      (t
                       (let ((report (apply-derivation store episode generation-id
                                                       parser-version now
                                                       (getf result :assertions)
                                                       (getf result :events))))
                         (push episode derived)
                         (incf accepted (getf report :assertions))
                         (incf rejected (getf report :rejected))
                         (incf conflicts (getf report :conflicts))
                         (incf closed (getf report :closed))))))))
       (setf derived (nreverse derived))
       (let ((remaining (unprocessed-episode-count store generation-id)))
         (when (zerop remaining)
           (set-generation-status store generation-id "candidate"))
         (let ((last-episode (and derived (episode-id (car (last derived))))))
           ;; Also when nothing was derived: a batch whose first call failed
           ;; still spent what it spent.
           (when (or last-episode (plusp tokens))
             (enchiridion.memory.store:exec
              store
              "UPDATE generations
                  SET to_episode = MAX(to_episode, ?),
                      writes = writes + ?,
                      episodes_derived = episodes_derived + ?,
                      tokens_used = tokens_used + ?
                WHERE id = ?"
              (list (or last-episode 0) (+ accepted conflicts closed) (length derived) tokens
                    generation-id))))
         (list :built t
               :generation-id generation-id
               :processed (length derived)
               :failed (or failure failure-note)
               :skipped skipped
               :remaining remaining
               :assertions accepted
               :rejected rejected
               :conflicts conflicts
               :closed closed
               :tokens tokens
               :status (if (zerop remaining) :candidate :building)))))))

(defun promote-generation (store generation-id)
  "Promote GENERATION-ID to live in one transaction and return a report plist.
The old live generation becomes retired, not deleted. No gate is applied here;
the gate path is a later phase and calls this function only after it passes."
  (ensure-generation-state store)
  (let ((row (generation-row store generation-id)))
    (cond
      ((null row) (list :promoted nil :reason :no-such-generation))
      ((not (string= (enchiridion.memory.store:field row "status") "candidate"))
       (list :promoted nil :reason :not-a-candidate
             :status (enchiridion.memory.store:field row "status")))
      (t
       (let* ((old (live-generation-id store))
              (now (get-universal-time))
              (parent (enchiridion.memory.store:field row "parent_id")))
         (declare (ignore parent))
         (enchiridion.memory.store:with-store-transaction (store)
           (when (plusp old)
             (enchiridion.memory.store:exec
              store
              "UPDATE generations SET status = 'retired', retired_ts = ?
                WHERE id = ? AND status = 'live'"
              (list now old)))
           (enchiridion.memory.store:exec
            store
            "UPDATE generations
                SET status = 'live', promoted_ts = ?
              WHERE id = ?"
            (list now generation-id))
           (enchiridion.memory.store:exec
            store
            "UPDATE memory_state
                SET live_generation_id = ?, last_t2_ts = ?,
                    last_t2_generation_id = ?
              WHERE id = 1"
            (list generation-id now generation-id)))
         (list :promoted t :generation-id generation-id :previous old))))))

(defun rollback-generation (store generation-id)
  "Roll GENERATION-ID back and return a report plist.
If it is live, the pointer returns to its parent and the parent is live again.
If it is a candidate, its status becomes rolled-back and the live layer is
untouched."
  (ensure-generation-state store)
  (let ((row (generation-row store generation-id)))
    (cond
      ((null row) (list :rolled-back nil :reason :no-such-generation))
      (t
       (let ((status (enchiridion.memory.store:field row "status"))
             (parent (enchiridion.memory.store:field row "parent_id"))
             (now (get-universal-time)))
         (if (string= status "live")
             (enchiridion.memory.store:with-store-transaction (store)
               (enchiridion.memory.store:exec
                store
                "UPDATE generations SET status = 'rolled-back', retired_ts = ?
                  WHERE id = ?"
                (list now generation-id))
               (enchiridion.memory.store:exec
                store
                "UPDATE memory_state SET live_generation_id = ? WHERE id = 1"
                (list (or parent 0)))
               ;; The pointer swap and the parent's status are one fact: a
               ;; live pointer at a generation marked retired is a store that
               ;; contradicts itself.
               (when parent
                 (enchiridion.memory.store:exec
                  store
                  "UPDATE generations SET status = 'live', retired_ts = NULL
                    WHERE id = ?"
                  (list parent))))
             (set-generation-status store generation-id "rolled-back"
                                    :detail "operator rollback"))
         (list :rolled-back t :generation-id generation-id
               :status "rolled-back"))))))

(defun generation-status (store generation-id)
  "Return a plist describing one generation, or NIL."
  (let ((row (generation-row store generation-id)))
    (when row
      (list :id (enchiridion.memory.store:field row "id")
            :number (enchiridion.memory.store:field row "number")
            :parent (enchiridion.memory.store:field row "parent_id")
            :status (enchiridion.memory.store:field row "status")
            :parser-version (enchiridion.memory.store:field row "parser_version")
            :from-episode (enchiridion.memory.store:field row "from_episode")
            :to-episode (enchiridion.memory.store:field row "to_episode")
            :writes (enchiridion.memory.store:field row "writes")
            :promoted-ts (enchiridion.memory.store:field row "promoted_ts")
            :detail (enchiridion.memory.store:field row "detail")))))

(defun generation-assertion-count (store generation-id)
  "Return how many assertions GENERATION-ID holds."
  (or (enchiridion.memory.store:field
       (first (enchiridion.memory.store:query-rows
               store
               "SELECT COUNT(*) AS n FROM assertions WHERE generation_id = ?"
               (list generation-id)))
       "n")
      0))

(defun live-assertion-count (store)
  "Return how many assertions the live view holds."
  (or (enchiridion.memory.store:field
       (first (enchiridion.memory.store:query-rows
               store "SELECT COUNT(*) AS n FROM live_assertions"))
       "n")
      0))

(defun current-generation (store)
  "Return the live generation row as a plist, or NIL."
  (let ((id (live-generation-id store)))
    (and (plusp id) (generation-row store id))))
