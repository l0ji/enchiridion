;;;; vectors.cl --- Dense candidates for the episodic log.
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

(defun make-backend-embedder (backend &key model dimensions (batch 64))
  "Return an embedder that sends TEXTS to BACKEND's EMBED in batches of BATCH."
  (lambda (texts)
    (loop for start from 0 below (length texts) by batch
          append (enchiridion.llm:embed
                  backend
                  (subseq texts start (min (length texts) (+ start batch)))
                  :model model :dimensions dimensions))))

(defun embed-pending (store &key (embedder *memory-embedder*) (limit 256)
                                 (model *memory-embed-model*))
  "Embed up to LIMIT episodes that have no vector yet and return how many were
written. Saved memories and turns are embedded alike; an empty body is not.
Return 0 without an embedder. A failed call signals, so the heartbeat reports
it and the next tick tries the same rows again."
  (if (null embedder)
      0
      (let* ((rows (enchiridion.memory.store:query-rows
                    store
                    "SELECT e.id, e.body FROM episodes e
                       LEFT JOIN episode_vectors v ON v.id = e.id
                      WHERE v.id IS NULL AND length(e.body) > 0
                      ORDER BY e.id LIMIT ?"
                    (list (max 1 limit))))
             (texts (mapcar (lambda (row)
                              (let ((body (enchiridion.memory.store:field row "body")))
                                (subseq body 0 (min (length body) *embed-body-chars*))))
                            rows))
             (vectors (when texts (funcall embedder texts))))
        (enchiridion.memory.store:with-store-transaction (store)
          (loop for row in rows
                for vector in vectors
                for unit = (normalise-vector vector)
                do (enchiridion.memory.store:exec
                    store
                    "INSERT OR REPLACE INTO episode_vectors (id, model, dims, vec)
                       VALUES (?, ?, ?, ?)"
                    (list (enchiridion.memory.store:field row "id") model
                          (length unit) (encode-vector unit)))))
        (length rows))))

;;;; Reading.

(defstruct (vector-index (:constructor make-vector-index))
  (model "" :type string)
  (max-id 0 :type integer)
  (ids (make-array 0 :adjustable t :fill-pointer t) :type vector)
  (vectors (make-array 0 :adjustable t :fill-pointer t) :type vector))

(defvar *vector-indexes* (make-hash-table :test #'equal)
  "One in-memory index per store path, extended on each read.")

(defvar *vector-indexes-lock* (bordeaux-threads:make-lock "vector indexes"))

(defun vector-index-for (store &optional (model *memory-embed-model*))
  "Return STORE's index under MODEL, with every vector written since the last
call appended. A changed model starts the index again."
  (let ((key (namestring (enchiridion.memory.store:store-path store))))
    (bordeaux-threads:with-lock-held (*vector-indexes-lock*)
      (let ((index (gethash key *vector-indexes*)))
        (unless (and index (string= (vector-index-model index) model))
          (setf index (make-vector-index :model model)
                (gethash key *vector-indexes*) index))
        (dolist (row (enchiridion.memory.store:query-rows
                      store
                      "SELECT id, vec FROM episode_vectors
                        WHERE id > ? AND model = ? ORDER BY id"
                      (list (vector-index-max-id index) model)))
          (let ((id (enchiridion.memory.store:field row "id")))
            (vector-push-extend id (vector-index-ids index))
            (vector-push-extend (decode-vector (enchiridion.memory.store:field row "vec"))
                                (vector-index-vectors index))
            (setf (vector-index-max-id index) (max id (vector-index-max-id index)))))
        index))))

(defun dot (a b)
  (declare (type (simple-array single-float (*)) a b)
           (optimize (speed 3) (safety 1)))
  (let ((sum 0.0f0))
    (declare (type single-float sum))
    (dotimes (i (min (length a) (length b)) sum)
      (incf sum (* (aref a i) (aref b i))))))

(defun dense-ranking (store cue-vector &key (limit 200))
  "Return up to LIMIT episode ids nearest CUE-VECTOR, best first."
  (let* ((index (vector-index-for store))
         (q (normalise-vector cue-vector))
         (scored (loop for id across (vector-index-ids index)
                       for v across (vector-index-vectors index)
                       collect (cons id (dot q v)))))
    (mapcar #'car (subseq (sort scored #'> :key #'cdr)
                          0 (min limit (length scored))))))

(defun candidates-by-id (store ids &key (now (get-universal-time)))
  "Return the candidate plists for the episode IDS that still exist."
  (when ids
    (loop for row in (enchiridion.memory.store:query-rows
                      store
                      (format nil
                              "SELECT e.id, e.body, e.session, e.channel, e.cue_type,
                                      e.role, e.ts, NULL AS lexical,
                                      e.context_key, e.horizon, e.scene_trace,
                                      a.n_enc, a.last_enc, a.n_ret, a.last_ret,
                                      a.created_ts, a.supp, a.supp_ts, a.imp,
                                      a.distinctness
                                 FROM episodes e
                                 LEFT JOIN activation a
                                        ON a.kind = 'episode' AND a.id = e.id
                                WHERE e.id IN (~{~D~^,~})" ids))
          collect (episode-candidate row now))))

(defun rrf (ranks k)
  "Return the reciprocal-rank-fusion score of RANKS, zero-based, with constant K."
  (loop for rank in ranks sum (/ 1.0 (+ k rank 1))))

(defun hybrid-candidates (store cue &key (limit 200) (now (get-universal-time))
                                         (embedder *memory-embedder*))
  "Return CANDIDATES-FOR's BM25 candidates, and with an embedder the dense
nearest too, with :LEXICAL set to the RRF score of the two rankings. A failed
cue embedding falls back to BM25 alone, with one line on the error stream."
  (let ((lexical (handler-case (candidates-for store cue :limit limit :now now)
                   (enchiridion.errors:schema-error () '()))))
    (if (null embedder)
        lexical
        (let ((dense (handler-case
                         (dense-ranking store (first (funcall embedder (list cue)))
                                        :limit (parameter :dense-candidates
                                                          *memory-parameters*))
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
