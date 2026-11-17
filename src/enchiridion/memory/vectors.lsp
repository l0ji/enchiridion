;;;; vectors.lsp --- Dense candidates for the episodic log.
;;;;
;;;; Off unless an embedder is installed. With one, every episode gets a
;;;; unit-length embedding through EMBED-PENDING, which the heartbeat runs, and
;;;; a turn embeds its cue once. Candidates are then the union of the BM25 top
;;;; and the dense top, and the lexical term L becomes their reciprocal-rank
;;;; fusion, so the score, the pack and everything after them are unchanged.
;;;; Without an embedder, HYBRID-CANDIDATES is CANDIDATES-FOR.
;;;;
;;;; The search is exact: one dot product per stored vector, read from an
;;;; in-memory copy that is extended with new rows on each call rather than
;;;; reread. At 512 dimensions a 100,000 episode log is about 200 MB and well
;;;; under a tenth of a second to scan.

(in-package #:enchiridion.memory)

(defvar *memory-embedder* nil
  "NIL, or a function of a list of strings that returns one vector of
SINGLE-FLOAT per string. MAKE-BACKEND-EMBEDDER builds one.")

(defvar *memory-embed-model* ""
  "The model name stored with each vector. A vector written under another
name is not compared with the cue, since its space is different.")

(defparameter *embed-body-chars* 6000
  "The characters of a body that are embedded. Long tool output is cut; the
start of a record is the part a later cue most often names.")

;;;; Encoding.

(defun normalise-vector (vector)
  "Return VECTOR scaled to unit length, as a simple SINGLE-FLOAT vector."
  (let* ((v (map '(simple-array single-float (*))
                 (lambda (x) (coerce x 'single-float)) vector))
         (norm (sqrt (loop for x across v sum (* x x)))))
    (when (plusp norm)
      (dotimes (i (length v)) (setf (aref v i) (/ (aref v i) norm))))
    v))

(defun encode-vector (vector)
  "Return VECTOR as packed little-endian float32 octets."
  (let ((out (make-array (* 4 (length vector)) :element-type '(unsigned-byte 8))))
    (loop for x across vector
          for i from 0 by 4
          for bits = (enchiridion.compat:single-float-bits x)
          do (dotimes (b 4) (setf (aref out (+ i b)) (ldb (byte 8 (* 8 b)) bits))))
    out))

(defun decode-vector (octets)
  "Return the SINGLE-FLOAT vector packed in OCTETS."
  (let* ((n (floor (length octets) 4))
         (out (make-array n :element-type 'single-float)))
    (dotimes (i n out)
      (let ((bits 0))
        (dotimes (b 4) (setf bits (logior bits (ash (aref octets (+ (* 4 i) b)) (* 8 b)))))
        (setf (aref out i) (enchiridion.compat:bits-single-float bits))))))

;;;; Writing.

(defparameter *embed-batch* 64
  "Texts one embedding request carries. EMBED-PENDING asks for this many at a
time so a budget can stop the work between two requests.")

(defparameter *embedding-chars-per-token* 4
  "Characters an embedding input token is estimated to hold for the ledger.
The embeddings seam returns vectors and no usage, so an embedding row is an
estimate and says so by its :EMBED channel.")

(defun configured-embed-dimensions ()
  "Return the vector size the configured embedder asks for, or NIL."
  (let ((dimensions (getf *memory-embed-settings* :dimensions)))
    (and (integerp dimensions) (plusp dimensions) dimensions)))

(defun embedding-token-estimate (texts)
  "Return the input tokens TEXTS are estimated to cost, rounded up."
  (ceiling (loop for text in texts sum (length text))
           *embedding-chars-per-token*))

(defun make-backend-embedder (backend &key model dimensions (batch *embed-batch*))
  "Return an embedder that sends TEXTS to BACKEND's EMBED in batches of BATCH."
  (lambda (texts)
    (loop for start from 0 below (length texts) by batch
          append (enchiridion.llm:embed
                  backend
                  (subseq texts start (min (length texts) (+ start batch)))
                  :model model :dimensions dimensions))))

(defun embed-pending (store &key (embedder *memory-embedder*) (limit 256)
                                 (model *memory-embed-model*)
                                 (dimensions (configured-embed-dimensions))
                                 max-tokens (session "") (channel :embed))
  "Embed up to LIMIT episodes that have no vector under MODEL and DIMENSIONS.
An episode is pending when no row holds a vector for that model and size, so a
changed model or size is filled again and the rows written under the old one are
kept. MAX-TOKENS bounds the estimated input of the whole call: the loop checks
it before every request and stops when the next one no longer fits. Return how
many vectors were written."
  (if (null embedder)
      0
      (let* ((rows (enchiridion.memory.store:query-rows
                    store
                    "SELECT e.id, e.body FROM episodes e
                      WHERE length(e.body) > 0
                        AND NOT EXISTS (SELECT 1 FROM episode_vectors v
                                         WHERE v.id = e.id AND v.model = ?
                                           AND (? IS NULL OR v.dims = ?))
                      ORDER BY e.id LIMIT ?"
                    (list model dimensions dimensions (max 1 limit))))
             (remaining max-tokens)
             (written 0))
        (loop for start from 0 below (length rows) by *embed-batch*
              do (let* ((chunk (subseq rows start
                                       (min (length rows) (+ start *embed-batch*))))
                        (texts (mapcar (lambda (row)
                                         (let ((body (enchiridion.memory.store:field
                                                      row "body")))
                                           (subseq body 0
                                                   (min (length body) *embed-body-chars*))))
                                       chunk))
                        (estimate (embedding-token-estimate texts)))
                   (when (and remaining (< remaining estimate))
                     (return))
                   (let ((vectors (funcall embedder texts)))
                     (enchiridion.memory.store:with-store-transaction (store)
                       (loop for row in chunk
                             for vector in vectors
                             for unit = (normalise-vector vector)
                             do (enchiridion.memory.store:exec
                                 store
                                 "INSERT OR REPLACE INTO episode_vectors
                                    (id, model, dims, vec) VALUES (?, ?, ?, ?)"
                                 (list (enchiridion.memory.store:field row "id") model
                                       (or dimensions (length unit))
                                       (encode-vector unit)))
                                (incf written)))
                     (record-memory-usage :store store :session session :model model
                                          :input estimate :channel channel)
                     (when remaining (decf remaining estimate)))))
        written)))

;;;; Reading.

(defparameter *dense-index-max-vectors* 20000
  "The most vectors one store's in-memory dense index keeps.
A 512 dimension vector is two kilobytes, so this is a memory bound of about
forty megabytes and the oldest vectors are the ones dropped.")

(defparameter *vector-index-max-stores* 4
  "How many stores' dense indexes stay in memory.
The least recently used one is dropped when another store is read. It is a
cache, so the next read builds it again from the vectors on disk.")

(defstruct (vector-index (:constructor make-vector-index))
  (model "" :type string)
  (dims nil)
  (max-rowid 0 :type integer)
  (ids (make-array 0 :adjustable t :fill-pointer t) :type vector)
  (vectors (make-array 0 :adjustable t :fill-pointer t) :type vector)
  (positions (make-hash-table) :type hash-table)
  (used 0 :type integer))

(defvar *vector-indexes* (make-hash-table :test #'equal)
  "One in-memory index per store path, extended on each read.")

(defvar *vector-indexes-lock* (bordeaux-threads:make-lock "vector indexes"))

(defvar *vector-index-clock* 0
  "The counter that orders the cached indexes by their last use.")

(defun evict-vector-indexes (keep)
  "Drop the least recently used indexes until only KEEP entries remain."
  (loop while (> (hash-table-count *vector-indexes*) *vector-index-max-stores*)
        do (let ((oldest nil)
                 (oldest-used most-positive-fixnum))
             (maphash (lambda (key index)
                        (unless (equal key keep)
                          (when (< (vector-index-used index) oldest-used)
                            (setf oldest-used (vector-index-used index)
                                  oldest key))))
                      *vector-indexes*)
             (if oldest
                 (remhash oldest *vector-indexes*)
                 (return)))))

(defun trim-vector-index (index)
  "Drop the oldest vectors so INDEX stays near *DENSE-INDEX-MAX-VECTORS*.
Eviction happens in a block, so the position table is rebuilt once per block
rather than once per vector."
  (let* ((ids (vector-index-ids index))
         (vectors (vector-index-vectors index))
         (excess (- (length ids) *dense-index-max-vectors*)))
    (when (plusp excess)
      (let ((drop (min (length ids)
                       (max excess (floor *dense-index-max-vectors* 16)))))
        (dotimes (position drop)
          (remhash (aref ids position) (vector-index-positions index)))
        (replace ids ids :start2 drop)
        (replace vectors vectors :start2 drop)
        (decf (fill-pointer ids) drop)
        (decf (fill-pointer vectors) drop)
        (loop for position from 0 below (length ids)
              do (setf (gethash (aref ids position)
                                (vector-index-positions index))
                       position))))))

(defun index-vector (index id vector)
  "Put ID's VECTOR into INDEX, replacing the vector an earlier row gave ID."
  (let ((position (gethash id (vector-index-positions index))))
    (if position
        (setf (aref (vector-index-vectors index) position) vector)
        (progn
          (vector-push-extend id (vector-index-ids index))
          (vector-push-extend vector (vector-index-vectors index))
          (setf (gethash id (vector-index-positions index))
                (1- (length (vector-index-ids index))))
          (trim-vector-index index)))))

(defun %vector-index (store model dims)
  "Return STORE's index under MODEL and DIMS, appending every vector written
since the last call. Called with *VECTOR-INDEXES-LOCK* held. A changed model or
size starts the index again, and the read follows ROWID so a replaced vector is
picked up."
  (let* ((key (namestring (enchiridion.memory.store:store-path store)))
         (index (gethash key *vector-indexes*)))
    (unless (and index
                 (string= (vector-index-model index) model)
                 (equal (vector-index-dims index) dims))
      (setf index (make-vector-index :model model :dims dims)
            (gethash key *vector-indexes*) index))
    (setf (vector-index-used index) (incf *vector-index-clock*))
    (evict-vector-indexes key)
    (dolist (row (enchiridion.memory.store:query-rows
                  store
                  "SELECT rowid AS rid, id, vec FROM episode_vectors
                    WHERE rowid > ? AND model = ? AND (? IS NULL OR dims = ?)
                    ORDER BY rowid"
                  (list (vector-index-max-rowid index) model dims dims)))
      (index-vector index
                    (enchiridion.memory.store:field row "id")
                    (decode-vector (enchiridion.memory.store:field row "vec")))
      (setf (vector-index-max-rowid index)
            (max (enchiridion.memory.store:field row "rid")
                 (vector-index-max-rowid index))))
    index))

(defun vector-index-for (store &optional (model *memory-embed-model*)
                                  (dims (configured-embed-dimensions)))
  "Return STORE's index under MODEL and DIMS. A changed model or size starts it again."
  (bordeaux-threads:with-lock-held (*vector-indexes-lock*)
    (%vector-index store model dims)))

(defun dot (a b)
  (declare (type (simple-array single-float (*)) a b)
           (optimize (speed 3) (safety 1)))
  (let ((sum 0.0f0))
    (declare (type single-float sum))
    (dotimes (i (min (length a) (length b)) sum)
      (incf sum (* (aref a i) (aref b i))))))

(defun dense-ranking (store cue-vector &key (limit 200))
  "Return up to LIMIT episode ids nearest CUE-VECTOR, best first.
The scan is exact and keeps only the best LIMIT scores, so neither its time nor
its memory grows the way sorting every stored vector did."
  (let ((q (normalise-vector cue-vector)))
    (bordeaux-threads:with-lock-held (*vector-indexes-lock*)
      (let* ((index (%vector-index store *memory-embed-model*
                                   (configured-embed-dimensions)))
             (ids (vector-index-ids index))
             (vectors (vector-index-vectors index))
             (size (min limit (length ids)))
             (best (make-array (max 1 size) :initial-element nil))
             (filled 0))
        (when (plusp size)
          (flet ((offer (score id)
                   (let ((position (cond ((< filled size) filled)
                                         ((> score (car (aref best (1- filled))))
                                          (1- filled))
                                         (t nil))))
                     (when position
                       (loop while (and (plusp position)
                                        (> score (car (aref best (1- position)))))
                             do (setf (aref best position) (aref best (1- position)))
                                (decf position))
                       (setf (aref best position) (cons score id))
                       (when (< filled size) (incf filled))))))
            (loop for position from 0 below (length ids)
                  do (offer (dot q (aref vectors position)) (aref ids position)))))
        (loop for position from 0 below filled
              collect (cdr (aref best position)))))))

(defun candidates-by-id (store ids &key (now (get-universal-time)))
  "Return the candidate plists for the episode IDS that still exist.
The body comes back as its first *RETRIEVAL-BODY-CHARS* characters, because
ranking a candidate reads no further and the pack reads its own window."
  (when ids
    (loop for row in (enchiridion.memory.store:query-rows
                      store
                      (format nil
                              "SELECT e.id, substr(e.body, 1, ~D) AS body,
                                      e.session, e.channel, e.cue_type,
                                      e.role, e.ts, NULL AS lexical,
                                      e.context_key, e.horizon, e.scene_trace,
                                      a.n_enc, a.last_enc, a.n_ret, a.last_ret,
                                      a.created_ts, a.supp, a.supp_ts, a.imp,
                                      a.distinctness
                                 FROM episodes e
                                 LEFT JOIN activation a
                                        ON a.kind = 'episode' AND a.id = e.id
                                WHERE e.id IN (~{~D~^,~})"
                              *retrieval-body-chars* ids))
          collect (episode-candidate row now))))

(defun rrf (ranks k)
  "Return the reciprocal-rank-fusion score of RANKS, zero-based, with constant K."
  (loop for rank in ranks sum (/ 1.0 (+ k rank 1))))

(defun hybrid-candidates (store cue &key (limit 200) (now (get-universal-time))
                                         (embedder *memory-embedder*)
                                         (session ""))
  "Return CANDIDATES-FOR's BM25 candidates, and with an embedder the dense
nearest too, with :LEXICAL set to the RRF score of the two rankings. The cue
embedding is billed to STORE's ledger on the :EMBED channel. A failed cue
embedding falls back to BM25 alone, with one line on the error stream."
  (let ((lexical (handler-case (candidates-for store cue :limit limit :now now)
                   (enchiridion.errors:schema-error () '()))))
    (if (null embedder)
        lexical
        (let ((dense (handler-case
                         (let ((vector (first (funcall embedder (list cue)))))
                           (record-memory-usage
                            :store store :session session
                            :model *memory-embed-model*
                            :input (embedding-token-estimate (list cue))
                            :channel :embed)
                           (dense-ranking store vector
                                          :limit (parameter :dense-candidates
                                                            *memory-parameters*)))
                       (error (c)
                         (format *error-output*
                                 "~&enchiridion: cue embedding failed, BM25 only: ~A~%" c)
                         (finish-output *error-output*)
                         :failed))))
          (if (eq dense :failed)
              lexical
              (let* ((k (parameter :rrf-k *memory-parameters*))
                     (lexical-rank (make-hash-table))
                     (dense-rank (make-hash-table)))
                ;; CANDIDATES-FOR returns rows in BM25 order.
                (loop for item in lexical for r from 0
                      do (setf (gethash (getf item :id) lexical-rank) r))
                (loop for id in dense for r from 0
                      do (setf (gethash id dense-rank) r))
                (let ((all (append lexical
                                   (candidates-by-id
                                    store
                                    (remove-if (lambda (id) (gethash id lexical-rank))
                                               dense)
                                    :now now))))
                  (dolist (item all all)
                    (let ((id (getf item :id)))
                      (setf (getf item :lexical)
                            (rrf (remove nil (list (gethash id lexical-rank)
                                                   (gethash id dense-rank)))
                                 k)))))))))))
