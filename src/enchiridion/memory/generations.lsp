;;;; generations.lsp --- Candidate generations and promotion.
;;;; Builds versioned semantic generations via *ASSERTION-DERIVER*, with atomic
;;;; pointer-swap promotion and rollback.

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
  "Copy TABLE rows from generation FROM to TO in rowid order, returning an
old-id -> new-id hash table. REMAP is called as (column row value id-map)
to rewrite foreign/self references (rowid order ensures parents precede children)."
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
  "Copy generation FROM's semantic layer and derivation marks into TO, remapping
all internal IDs. Copies schemas before assertions, then conflicts and links
so foreign keys resolve to the new generation."
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

(defparameter *generation-claim-seconds* 1800
  "Lease duration in seconds for a builder's claim on a generation before
another process may take over.")

(defun generation-claim-token ()
  "Return a value that names one builder for one build."
  (format nil "~D-~36R-~36R"
          (enchiridion.compat:process-id)
          (get-universal-time)
          (random most-positive-fixnum)))

(defun claim-generation (store generation-id owner
                         &key (now (get-universal-time))
                           (lease *generation-claim-seconds*))
  "Claim GENERATION-ID for OWNER and return T when the claim was taken.
A free generation and one whose lease has expired are claimable; one another
builder holds is not. The conditional update lets only one caller win."
  (plusp (enchiridion.memory.store:exec
          store
          "UPDATE generations SET claim_owner = ?, claim_ts = ?
             WHERE id = ? AND (claim_ts IS NULL OR claim_ts <= ?)"
          (list owner now generation-id (- now lease)))))

(defun release-generation (store generation-id owner)
  "Release OWNER's claim on GENERATION-ID and return T when a row changed.
A build whose lease expired and was taken over must not clear the new claim."
  (plusp (enchiridion.memory.store:exec
          store
          "UPDATE generations SET claim_owner = '', claim_ts = NULL
             WHERE id = ? AND claim_owner = ?"
          (list generation-id owner))))

(defun %start-candidate (store &key (parser-version *memory-parser-version*)
                                   (config-hash *memory-config-hash*)
                                   (rebuild nil))
  "Create a building generation in the caller's transaction and return its id."
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
      id)))

(defun start-candidate (store &key (parser-version *memory-parser-version*)
                                   (config-hash *memory-config-hash*)
                                   (rebuild nil))
  "Create a building generation in a transaction and return its id.
Copies the live generation (and its derivation marks) for incremental builds;
REBUILD starts empty even when a live parent exists."
  (ensure-generation-state store)
  (enchiridion.memory.store:with-store-transaction (store)
    (%start-candidate store :parser-version parser-version
                             :config-hash config-hash
                             :rebuild rebuild)))

(defun ensure-building-generation (store &key (parser-version *memory-parser-version*)
                                          (config-hash *memory-config-hash*)
                                          (rebuild nil))
  "Return the newest building generation, starting one when none exists.
The lookup and the insert are one transaction, so two callers cannot both see
no candidate and both insert one."
  (ensure-generation-state store)
  (enchiridion.memory.store:with-store-transaction (store)
    (or (current-building-generation store)
        (%start-candidate store :parser-version parser-version
                                 :config-hash config-hash
                                 :rebuild rebuild))))

(defun complete-candidate-generation (store)
  "Return the oldest candidate generation with NULL promotion_checked_ts, or NIL
(recovers candidates built before a crash without re-gating judged ones)."
  (enchiridion.memory.store:field
   (first (enchiridion.memory.store:query-rows
           store "SELECT id FROM generations
                   WHERE status = 'candidate'
                     AND promotion_checked_ts IS NULL
                   ORDER BY id ASC
                   LIMIT 1"))
   "id"))

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
  "Detect conflicts for ASSERTION in GENERATION-ID and return (:CONFLICTS :CLOSED).
Skips same-episode assertions and suppresses new conflict rows once 2+ live
objects exist for (subject, relation); updates still close superseded rows."
  (let* ((existing (candidate-existing-assertions store generation-id assertion))
         (set-p (>= (length existing) 2))
         (others (remove (assertion-episode-id assertion) existing
                         :key #'assertion-episode-id))
         (conflicts 0)
         (closed 0))
    (when others
      (multiple-value-bind (new-conflicts superseded)
          (detect-conflicts assertion others
                            :now now
                            :change-event-p (change-event-present-p
                                             store generation-id assertion)
                            :continuing-evidence-p nil)
        (unless set-p
          (dolist (conflict new-conflicts)
            (when (plusp (insert-conflict store conflict generation-id generation-id))
              (incf conflicts))))
        (dolist (old superseded)
          (enchiridion.memory.store:exec
           store
           "UPDATE assertions SET tx_to = ? WHERE id = ?"
           (list now (assertion-id old)))
          (incf closed))))
    (list :conflicts conflicts :closed closed)))

(defun derive-one (store deriver episode)
  "Call DERIVER on EPISODE, returning (:ASSERTIONS :EVENTS :TOKENS) or
(:ERROR :TOKENS). Binds *DERIVATION-TOKENS* locally for thread safety."
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
  "Run DERIVE-ONE across EPISODES with up to CONCURRENCY threads, returning
results in input order with cumulative :TOKENS. Failed calls requeue up to
ATTEMPTS times; 2*CONCURRENCY consecutive errors trip the breaker, leaving untried items NIL."
  (let* ((items (coerce episodes 'vector))
         (n (length items))
         (results (make-array n :initial-element nil))
         (tries (make-array n :initial-element 0))
         (spent (make-array n :initial-element 0))
         (queue (loop for i below n collect i))
         (streak 0)
         (breaker (* 2 (max 1 concurrency)))
         (lock (bordeaux-threads:make-lock "t2-deriver-queue")))
    (flet ((work ()
             (loop
               (let ((i (bordeaux-threads:with-lock-held (lock)
                          (unless (>= streak breaker) (pop queue)))))
                 (unless i (return))
                 (let ((result (derive-one store deriver (aref items i))))
                   (bordeaux-threads:with-lock-held (lock)
                     (incf (aref tries i))
                     (incf (aref spent i) (or (getf result :tokens) 0))
                     (setf (aref results i) result)
                     (if (getf result :error) (incf streak) (setf streak 0))
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

(defun apply-derivation (store episode generation-id parser-version now
                         assertions events)
  "Apply one episode and its counters atomically. Return zero counts on replay."
  (enchiridion.memory.store:with-store-transaction (store)
    (if (enchiridion.memory.store:query-rows
         store
         "SELECT 1 FROM generation_derivations
           WHERE generation_id = ? AND episode_id = ?"
         (list generation-id (episode-id episode)))
        (list :assertions 0 :rejected 0 :conflicts 0 :closed 0 :applied nil)
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
          (enchiridion.memory.store:exec
           store
           "UPDATE generations
               SET to_episode = MAX(to_episode, ?),
                   writes = writes + ?, episodes_derived = episodes_derived + 1
             WHERE id = ?"
           (list (episode-id episode) (+ accepted conflicts closed) generation-id))
          (list :assertions accepted :rejected rejected
                :conflicts conflicts :closed closed :applied t)))))

(defun build-candidate (store &key (limit *memory-t2-episodes-per-tick*)
                                  (parser-version *memory-parser-version*)
                                  (config-hash *memory-config-hash*)
                                  (rebuild nil))
  "Build or resume a candidate generation under a lease and return a report plist.
Copies the live layer unless REBUILD is set; returns :REASON :CLAIMED if
another builder holds the lease, or :NO-DERIVER if *ASSERTION-DERIVER* is NIL."
  (cond
    ((null store) (list :built nil :reason :no-store))
    ((not (enabled-p)) (list :built nil :reason :disabled))
    ((null *assertion-deriver*) (list :built nil :reason :no-deriver))
    (t
     (let* ((generation-id (ensure-building-generation
                            store
                            :parser-version parser-version
                            :config-hash config-hash
                            :rebuild rebuild))
            (owner (generation-claim-token))
            (claim-now (get-universal-time)))
       (if (not (claim-generation store generation-id owner :now claim-now))
           ;; Another builder holds the lease; retry on the next tick.
           (progn
             (enchiridion.log:log-info :memory "T2 generation ~D lease held by another builder"
                                       generation-id)
             (list :built nil
                   :reason :claimed
                   :generation-id generation-id
                   :remaining (unprocessed-episode-count store generation-id)))
           (unwind-protect
                (let ((episodes (candidate-episodes store generation-id limit))
                      (now (get-universal-time))
                      (accepted 0) (rejected 0) (conflicts 0) (closed 0)
                      (tokens 0) (derived '()) (failure nil) (failure-note nil)
                      (skipped 0))
                  ;; Derive concurrently, bill tokens upfront, then apply in episode order.
                  ;; If >50% fail (outage), stop at the first failure so untried episodes retry next tick;
                  ;; otherwise mark individual failed episodes derived with no writes so the batch progresses.
                  (let ((results (derive-concurrently store episodes)))
                    (dolist (result results)
                      (incf tokens (or (getf result :tokens) 0)))
                    ;; Billing survives an apply failure: these calls happened
                    (when (plusp tokens)
                      (enchiridion.memory.store:exec
                       store
                       "UPDATE generations SET tokens_used = tokens_used + ? WHERE id = ?"
                       (list tokens generation-id)))
                    (let ((outage (> (* 2 (count-if (lambda (r)
                                                      (or (null r) (getf r :error)))
                                                    results))
                                     (length results))))
                      (when outage
                        (enchiridion.log:log-warn :memory "T2 generation ~D deriver outage detected (>50%% failures in batch of ~D)"
                                                  generation-id (length results)))
                      (loop for episode in episodes
                            for result in results
                            for error = (or (null result) (getf result :error))
                            do (cond
                                 (failure)
                                 ((and error outage)
                                  (setf failure
                                        (or (getf result :error)
                                            "the deriver returned nothing")))
                                 (error
                                  (unless failure-note
                                    (setf failure-note
                                          (or (getf result :error)
                                              "the deriver returned nothing")))
                                  (incf skipped)
                                  (when (getf (apply-derivation store episode
                                                                generation-id
                                                                parser-version now
                                                                nil nil)
                                              :applied)
                                    (push episode derived)))
                                 (t
                                  (let ((report (apply-derivation
                                                 store episode generation-id
                                                 parser-version now
                                                 (getf result :assertions)
                                                 (getf result :events))))
                                    (when (getf report :applied)
                                      (push episode derived))
                                    (incf accepted (getf report :assertions))
                                    (incf rejected (getf report :rejected))
                                    (incf conflicts (getf report :conflicts))
                                    (incf closed (getf report :closed))))))))
                  (setf derived (nreverse derived))
                  (let ((remaining (unprocessed-episode-count store generation-id)))
                    (when (zerop remaining)
                      (set-generation-status store generation-id "candidate"))
                    (enchiridion.log:log-info
                     :memory "T2 generation ~D batch: processed=~D skipped=~D remaining=~D assertions=~D rejected=~D conflicts=~D tokens=~D status=~(~A~)"
                     generation-id (length derived) skipped remaining
                     accepted rejected conflicts tokens
                     (if (zerop remaining) :candidate :building))
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
                          :status (if (zerop remaining) :candidate :building))))
             (release-generation store generation-id owner)))))))

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
  "Roll GENERATION-ID back and return a report plist. If live, atomically
retires it and restores its parent as live; if a candidate, marks it rolled-back."
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
               ;; Restore parent status in the same transaction as the pointer swap.
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

(defun requeue-generation (store generation-id)
  "Reset a quarantined GENERATION-ID back to candidate status, clearing
promotion_result/checked_ts while preserving historical generation_checks rows."
  (let ((row (generation-row store generation-id)))
    (cond
      ((null row) (list :requeued nil :reason :no-such-generation))
      ((not (string= (enchiridion.memory.store:field row "status") "quarantined"))
       (list :requeued nil :reason :not-quarantined
             :status (enchiridion.memory.store:field row "status")))
      (t
       (enchiridion.memory.store:exec
        store
        "UPDATE generations
            SET status = 'candidate', promotion_result = '',
                promotion_checked_ts = NULL, quarantine_reason = ''
          WHERE id = ?"
        (list generation-id))
       (list :requeued t :generation-id generation-id :status "candidate")))))

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
