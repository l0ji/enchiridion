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

(defun start-candidate (store &key (parser-version *memory-parser-version*)
                                   (config-hash *memory-config-hash*))
  "Create a building generation and return its id.
The parent is the live generation, or NIL when none has been promoted. The
phase 2 builder fills the candidate from the log; it does not copy the parent's
rows, so a candidate is a clean rebuild and P7 is direct."
  (ensure-generation-state store)
  (let* ((parent (live-generation-id store))
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
        VALUES (?, ?, 'building', ?, 0, 0, ?, ?)"
     (list number (and (plusp parent) parent) now parser-version config-hash))
    (enchiridion.memory.store:last-row-id store)))

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

(defun derive-episode (store episode generation-id parser-version now)
  "Derive one episode into GENERATION-ID and return a report plist.
The deriver returns assertions and change events. Invalid spans are rejected
before insertion. Conflict detection runs after the new assertions exist."
  (multiple-value-bind (assertions events)
      (assertions-for-episode store episode)
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
            :conflicts conflicts :closed closed))))

(defun build-candidate (store &key (limit *memory-t2-episodes-per-tick*)
                                  (parser-version *memory-parser-version*)
                                  (config-hash *memory-config-hash*))
  "Build or resume a candidate generation and return a report plist.
With no deriver installed the function reports :no-deriver and writes nothing.
The build is resumable: a limited batch leaves the generation in :building and
the next call continues the same generation."
  (cond
    ((null store) (list :built nil :reason :no-store))
    ((not (enabled-p)) (list :built nil :reason :disabled))
    ((null *assertion-deriver*) (list :built nil :reason :no-deriver))
    (t
     (ensure-generation-state store)
     (let* ((generation-id (or (current-building-generation store)
                               (start-candidate store
                                                :parser-version parser-version
                                                :config-hash config-hash)))
            (episodes (candidate-episodes store generation-id limit))
            (now (get-universal-time))
            (accepted 0) (rejected 0) (conflicts 0) (closed 0))
       (dolist (episode episodes)
         (let ((report (derive-episode store episode generation-id
                                       parser-version now)))
           (incf accepted (getf report :assertions))
           (incf rejected (getf report :rejected))
           (incf conflicts (getf report :conflicts))
           (incf closed (getf report :closed))))
       (let ((remaining (unprocessed-episode-count store generation-id)))
         (when (zerop remaining)
           (set-generation-status store generation-id "candidate"))
         (let ((last-episode (and episodes (episode-id (car (last episodes))))))
           (when last-episode
             (enchiridion.memory.store:exec
              store
              "UPDATE generations
                  SET to_episode = MAX(to_episode, ?),
                      writes = writes + ?
                WHERE id = ?"
              (list last-episode (+ accepted conflicts closed) generation-id))))
         (list :built t
               :generation-id generation-id
               :processed (length episodes)
               :remaining remaining
               :assertions accepted
               :rejected rejected
               :conflicts conflicts
               :closed closed
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
