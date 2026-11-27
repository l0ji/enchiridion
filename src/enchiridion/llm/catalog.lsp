;;;; catalog.lsp --- Runtime models.dev catalog cached under run/.
;;;;
;;;; Fetches models.dev at run time and writes two files under run/:
;;;; providers.json (provider index, loaded as an ordered list of PROVIDER
;;;; structs) and provider-models.json (per-provider model metadata for pricing
;;;; and limits). Missing or corrupt cache files return NIL rather than signaling.

(in-package #:enchiridion.llm)

;;;; The cache.

(defparameter *catalog* nil
  "Memoized provider index (list of PROVIDER structs), or NIL if not loaded.")

(defparameter *catalog-models* nil
  "Memoized hash table mapping provider cache name to list of MODEL-INFO, or NIL.")

(defparameter *catalog-path*
  (merge-pathnames "providers.json" (enchiridion:run-directory))
  "Default provider index cache path, resolved from run-directory at load time.")

(defparameter *catalog-models-path* nil
  "Where the model metadata is cached, or NIL for provider-models.json beside
*CATALOG-PATH*.")

(defparameter *catalog-url* nil
  "Override URL for models.dev fetch, or NIL to use :providers-url / default.")

(declaim (ftype (function () pathname) catalog-path))

(defun catalog-path ()
  "Return the provider index path: ENCHIRIDION_PROVIDERS_PATH if set, else *CATALOG-PATH*."
  (let ((override (enchiridion.compat:environment-value "ENCHIRIDION_PROVIDERS_PATH")))
    (if (nonempty-string-p override) (pathname override) *catalog-path*)))

(declaim (ftype (function () pathname) catalog-models-path))

(defun catalog-models-path ()
  "Return the model metadata file: the override, or provider-models.json beside
the provider index."
  (or *catalog-models-path*
      (merge-pathnames "provider-models.json" (catalog-path))))

;;;; JSON object readers (supporting both keyword-keyed plists and string-keyed hash tables).

(declaim (ftype (function (t) boolean) nonempty-string-p))

(defun nonempty-string-p (value)
  "Return T when VALUE is a string with at least one character in it."
  (and (stringp value) (plusp (length value))))

(declaim (ftype (function (t) string) catalog-key-name))

(defun catalog-key-name (key)
  "Return JSON object KEY as a lowercase string (coercing characters/symbols via STRING)."
  (string-downcase (string key)))

(declaim (ftype (function (t t &optional t) t) catalog-field))

(defun catalog-field (entry key &optional default)
  "Return KEY from parsed JSON object ENTRY (plist or hash table), case-insensitively, or DEFAULT."
  (cond
    ((hash-table-p entry) (json-value entry key default))
    ((consp entry)
     (loop for (name value) on entry by #'cddr
           when (and name (string-equal (string name) key))
             return value
           finally (return default)))
    (t default)))

(declaim (ftype (function (t t) (or null string)) catalog-string))

(defun catalog-string (entry key)
  "Return KEY of ENTRY as a string, or NIL when it is absent or not a string."
  (let ((value (catalog-field entry key)))
    (if (stringp value) value nil)))

(declaim (ftype (function (t t) (or null integer)) catalog-integer))

(defun catalog-integer (entry key)
  "Return KEY of ENTRY as an integer, or NIL."
  (let ((value (catalog-field entry key)))
    (if (integerp value) value nil)))

(declaim (ftype (function (t t) (or null number)) catalog-number))

(defun catalog-number (entry key)
  "Return KEY of ENTRY as a number, or NIL when absent (distinct from 0)."
  (let ((value (catalog-field entry key)))
    (if (numberp value) value nil)))

;;;; The environment placeholders models.dev writes into an endpoint.

(declaim (ftype (function (string) (or null string)) expand-environment))

(defun expand-environment (text)
  "Expand ${NAME} placeholders in TEXT via secrets or environment; return NIL if any variable is missing."
  (let ((out (make-string-output-stream))
        (start 0))
    (loop
      (let ((open (search "${" text :start2 start)))
        (unless open
          (write-string (subseq text start) out)
          (return))
        (write-string (subseq text start open) out)
        (let* ((close (position #\} text :start (+ open 2)))
               (name (and close (subseq text (+ open 2) close)))
               (value (and name
                            (or (enchiridion.llm.secrets:secret-value name)
                                (enchiridion.compat:environment-value name)))))
          (unless (nonempty-string-p value)
            (return-from expand-environment nil))
          (write-string value out)
          (setf start (1+ close)))))
    (get-output-stream-string out)))

(declaim (ftype (function (t) (or null string)) catalog-api-url))

(defun catalog-api-url (entry)
  "Return ENTRY's endpoint with its ${NAME} placeholders expanded, or NIL."
  (let ((api (catalog-string entry "api")))
    (if api (expand-environment api) nil)))

;;;; The maps in a models.dev document.

(declaim (ftype (function (t) list) map-pairs))

(defun map-pairs (data)
  "Return JSON object DATA (hash table or plist) as a list of (lowercase-key . value) pairs."
  (cond
    ((hash-table-p data)
     (loop for key being the hash-keys of data
           collect (cons (catalog-key-name key) (gethash key data))))
    ((consp data)
     (loop for (key value) on data by #'cddr
           when (and key (or (symbolp key) (stringp key) (characterp key)))
             collect (cons (catalog-key-name key) value)))
    (t '())))

(declaim (ftype (function (t) list) sorted-pairs))

(defun sorted-pairs (data)
  "Return DATA as (key . value) pairs sorted by key for deterministic caching and lookup."
  (sort (map-pairs data) #'string< :key #'car))

(declaim (ftype (function (t) boolean) wrapper-shape-p))

(defun wrapper-shape-p (data)
  "Return T when DATA is our {\"meta\" ..., \"providers\" ...} wrapper rather than a flat provider map."
  (let ((providers (catalog-field data "providers")))
    (and (or (hash-table-p providers) (consp providers))
         (or (null (catalog-field providers "npm"))
             (null (catalog-field providers "id")))
         (if (hash-table-p data)
             (<= (hash-table-count data) 2)
             (<= (length data) 4))
         t)))

(declaim (ftype (function (t) list) catalog-provider-entries))

(defun catalog-provider-entries (data)
  "Return DATA as a list of (id . provider entry), the wrapper or the flat map."
  (if (wrapper-shape-p data)
      (sorted-pairs (catalog-field data "providers"))
      (sorted-pairs data)))

;;;; The default-model rule.

(declaim (ftype (function (t) string) model-release-date))

(defun model-release-date (entry)
  "Return ENTRY's ISO 8601 release_date or last_updated string, or \"\"."
  (or (catalog-string entry "release_date") (catalog-string entry "last_updated") ""))

(declaim (ftype (function (list) cons) best-catalog-model))

(defun best-catalog-model (models)
  "Return the newest (id . entry) in MODELS, breaking release-date ties by smallest id."
  (reduce (lambda (left right)
            (let ((left-date (model-release-date (cdr left)))
                  (right-date (model-release-date (cdr right))))
              (cond
                ((string> left-date right-date) left)
                ((string< left-date right-date) right)
                ((string< (car left) (car right)) left)
                (t right))))
          models))

(declaim (ftype (function (list) (or null string)) catalog-default-model))

(defun catalog-default-model (models)
  "Return the default model id from MODELS, preferring the newest tool-calling model, or NIL."
  (when models
    (let ((tool-models (remove-if-not (lambda (model)
                                        (catalog-field (cdr model) "tool_call"))
                                      models)))
      (car (best-catalog-model (or tool-models models))))))

;;;; Mapping models.dev npm packages to wire protocols.

(declaim (ftype (function (t) t) catalog-protocol))

(defun catalog-protocol (npm)
  "Return :OPENAI, :ANTHROPIC or NIL for NPM, the package models.dev names."
  (when (stringp npm)
    (cond
      ((member npm '("@ai-sdk/openai-compatible" "@ai-sdk/openai") :test #'string=)
       :openai)
      ((string= npm "@ai-sdk/anthropic") :anthropic)
      (t nil))))

(declaim (ftype (function (t) (or null string)) protocol-name))

(defun protocol-name (protocol)
  "Return PROTOCOL as the lower case string the cache file carries."
  (when protocol (string-downcase (symbol-name protocol))))

(declaim (ftype (function (t) list) catalog-env-names))

(defun catalog-env-names (entry)
  "Return ENTRY's env field as a list of nonempty strings, or NIL."
  (let ((value (catalog-field entry "env")))
    (cond
      ((nonempty-string-p value) (list value))
      ((consp value) (remove-if-not #'nonempty-string-p value))
      (t '()))))

(declaim (ftype (function (&optional t) string) iso-timestamp))

(defun iso-timestamp (&optional (universal (get-universal-time)))
  "Return UNIVERSAL as the UTC timestamp the cache files carry."
  (multiple-value-bind (second minute hour day month year)
      (decode-universal-time universal 0)
    (format nil "~4,'0D-~2,'0D-~2,'0DT~2,'0D:~2,'0D:~2,'0DZ"
            year month day hour minute second)))

;;;; The trim.

(declaim (ftype (function (t t) hash-table) trim-model))

(defun trim-model (id entry)
  "Trim a models.dev model ENTRY into a flat JSON object with limits and costs."
  (let ((limit (catalog-field entry "limit"))
        (cost (catalog-field entry "cost")))
    (json-object "id" id
                 "name" (or (catalog-string entry "name") id)
                 "tool_call" (not (null (catalog-field entry "tool_call")))
                 "reasoning" (not (null (catalog-field entry "reasoning")))
                 "context" (catalog-integer limit "context")
                 "output" (catalog-integer limit "output")
                 "cost_input" (catalog-number cost "input")
                 "cost_output" (catalog-number cost "output")
                 "cost_cache_read" (catalog-number cost "cache_read")
                 "cost_cache_write" (catalog-number cost "cache_write")
                 "release_date" (model-release-date entry))))

(declaim (ftype (function (t) t) trim-catalog))

(defun trim-catalog (data)
  "Trim parsed models.dev DATA into two JSON objects: (values provider-index model-metadata)."
  (let ((providers (make-hash-table :test #'equal))
        (metadata (make-hash-table :test #'equal)))
    (dolist (pair (catalog-provider-entries data))
      (let* ((id (car pair))
             (entry (cdr pair))
             (models (sorted-pairs (catalog-field entry "models")))
             (npm (catalog-string entry "npm")))
        (when models
          (setf (gethash id metadata)
                (mapcar (lambda (model) (trim-model (car model) (cdr model)))
                        models)))
        (setf (gethash id providers)
              (json-object "id" id
                           "name" (or (catalog-string entry "name") id)
                           "npm" npm
                           "env" (catalog-env-names entry)
                           "api" (catalog-string entry "api")
                           "doc" (catalog-string entry "doc")
                           "default" (catalog-default-model models)
                           "protocol" (protocol-name (catalog-protocol npm))))))
    (values (json-object "meta" (json-object "generated_at" (iso-timestamp)
                                             "count" (hash-table-count providers))
                         "providers" providers)
            (json-object "generated_at" (iso-timestamp)
                         "providers" metadata))))

;;;; Reading the cache back.

(declaim (ftype (function (t) t) provider-id-keyword))

(defun provider-id-keyword (id)
  "Normalize ID (keyword, string, or symbol) to a keyword, or NIL.
NIL is handled before SYMBOLP so NIL never interns as :NIL."
  (cond
    ((null id) nil)
    ((keywordp id) id)
    ((stringp id) (and (plusp (length id)) (intern (string-upcase id) :keyword)))
    ((symbolp id) (intern (string-upcase (symbol-name id)) :keyword))
    (t nil)))

(declaim (ftype (function (t) string) provider-cache-name))

(defun provider-cache-name (id)
  "Return ID as a lowercase filename-safe string (non-alphanumeric chars replaced with hyphens)."
  (if (null id)
      "provider"
      (map 'string
           (lambda (character)
             (if (or (alphanumericp character)
                     (member character '(#\- #\_ #\.)))
                 character
                 #\-))
           (string-downcase (string id)))))

(declaim (ftype (function (t t &optional t) t) model-info-from-data))

(defun model-info-from-data (id entry &optional (source :catalog))
  "Return ENTRY, one model of a cache file, as a MODEL-INFO record."
  (%make-model-info
   :id id
   :name (or (catalog-string entry "name") id)
   :tool-call-p (not (null (catalog-field entry "tool_call")))
   :reasoning-p (not (null (catalog-field entry "reasoning")))
   :context (catalog-integer entry "context")
   :output (catalog-integer entry "output")
   :cost-input (catalog-number entry "cost_input")
   :cost-output (catalog-number entry "cost_output")
   :cost-cache-read (catalog-number entry "cost_cache_read")
   :cost-cache-write (catalog-number entry "cost_cache_write")
   :source source))

(declaim (ftype (function (t &optional t) list) model-info-array))

(defun model-info-array (entries &optional (source :catalog))
  "Convert a JSON list of model objects carrying \"id\" fields into a list of MODEL-INFO."
  (if (consp entries)
      (loop for entry in entries
            for id = (catalog-field entry "id")
            when (nonempty-string-p id)
              collect (model-info-from-data id entry source))
      '()))

(declaim (ftype (function (t t) provider) catalog-index-row))

(defun catalog-index-row (id entry)
  "Build a PROVIDER struct from a catalog index row, storing :npm and :protocol in OPTIONS."
  (let* ((npm (catalog-string entry "npm"))
         (written (catalog-field entry "protocol"))
         (protocol (cond ((keywordp written) written)
                         ((stringp written) (intern (string-upcase written) :keyword))
                         (t (catalog-protocol npm))))
         (default (catalog-string entry "default")))
    (%make-provider
     :id (or (provider-id-keyword id) id)
     :name (or (catalog-string entry "name") id)
     :base-url (or (catalog-api-url entry) "")
     :env (catalog-env-names entry)
     :default-model (or default
                        (catalog-default-model
                         (sorted-pairs (catalog-field entry "models"))))
     :doc (or (catalog-string entry "doc") "")
     :options (list :npm npm :protocol protocol)
     :source :catalog)))

(declaim (ftype (function (t) list) catalog-index))

(defun catalog-index (data)
  "Return DATA, a parsed provider index, as a list of PROVIDER structs."
  (loop for (id . entry) in (catalog-provider-entries data)
        collect (catalog-index-row id entry)))

(declaim (ftype (function (t) (or null list)) read-catalog-file))

(defun read-catalog-file (path)
  "Read provider index from PATH (wrapper or flat map), returning NIL if missing or corrupt."
  (when (probe-file path)
    (handler-case
        (let ((data (parse-json (uiop:read-file-string path))))
          (when data (catalog-index data)))
      (error (condition)
        (enchiridion.log:log-warn :llm "ignoring unreadable catalog file ~A: ~A" path condition)
        nil))))

(declaim (ftype (function (t) (or null hash-table)) read-catalog-models-file))

(defun read-catalog-models-file (path)
  "Return the model metadata cached at PATH as a hash table of provider name to
a list of MODEL-INFO, or NIL when there is no usable file."
  (when (probe-file path)
    (handler-case
        (let ((data (parse-json (uiop:read-file-string path))))
          (when data
            (let ((table (make-hash-table :test #'equal)))
              (dolist (pair (map-pairs (catalog-field data "providers")))
                (setf (gethash (car pair) table)
                      (model-info-array (cdr pair))))
              table)))
      (error (condition)
        (enchiridion.log:log-warn :llm "ignoring unreadable catalog models file ~A: ~A"
                                  path condition)
        nil))))

(declaim (ftype (function () (or null list)) catalog-providers))

(defun catalog-providers ()
  "Return the memoized provider index, reading it once. Missing/corrupt NIL is not memoized."
  (or *catalog*
      (setf *catalog* (read-catalog-file (catalog-path)))))

(declaim (ftype (function () hash-table) catalog-model-metadata))

(defun catalog-model-metadata ()
  "Return the cached model metadata, reading it once. An empty table rather
than NIL when there is no file, so the missing file is probed once."
  (or *catalog-models*
      (setf *catalog-models*
            (or (read-catalog-models-file (catalog-models-path))
                (make-hash-table :test #'equal)))))

(declaim (ftype (function (provider) (or null list)) catalog-models-for))

(defun catalog-models-for (provider)
  "Return cached models.dev MODEL-INFO list for PROVIDER, or NIL."
  (gethash (provider-cache-name (provider-id provider)) (catalog-model-metadata)))

;;;; Expiry.

(declaim (ftype (function (t t) boolean) catalog-expired-p))

(defun catalog-expired-p (path ttl)
  "Return T if PATH is missing, older than TTL seconds, or TTL is NIL/non-positive."
  (let ((written (ignore-errors (file-write-date path))))
    (or (null written)
        (not (and (numberp ttl) (plusp ttl)))
        (> (- (get-universal-time) written) ttl))))

;;;; Fetching and writing.

(declaim (ftype (function (string) t) fetch-catalog-text))

(defun fetch-catalog-text (url)
  "GET URL via the retry transport with +HTTP-GET-TIMEOUT+ and return the response body."
  (get-with-retries (make-http-request :url url :timeout +http-get-timeout+)))

(declaim (ftype (function (t t) t) write-json-file))

(defun write-json-file (path object)
  "Atomically write OBJECT as UTF-8 JSON to PATH via a sibling temp file and rename."
  (let* ((path (pathname path))
         (name (or (pathname-name path) "catalog"))
         (temp (make-pathname :name (concatenate 'string name ".tmp") :defaults path))
         (text (stringify object)))
    (ensure-directories-exist path)
    (unwind-protect
         (progn
           (with-open-file (stream temp :direction :output
                                        :if-exists :supersede
                                        :if-does-not-exist :create
                                        :external-format :utf-8)
             (write-string text stream))
           (uiop:rename-file-overwriting-target temp path))
      (when (probe-file temp)
        (ignore-errors (delete-file temp))))
    path))

(declaim (ftype (function (string) t) catalog-fetch))

(defun catalog-fetch (url)
  "Fetch and parse JSON from URL; signals TRANSPORT-ERROR on HTTP failure or CONFIGURATION-ERROR otherwise."
  (handler-case (parse-json (fetch-catalog-text url))
    (enchiridion.errors:transport-error (condition)
      (error condition))
    (dexador.error:http-request-failed (failure)
      (error 'enchiridion.errors:transport-error
             :status (dexador.error:response-status failure)
             :detail (format nil "Could not fetch the provider catalog from ~A." url)))
    (error (condition)
      (error 'enchiridion.errors:configuration-error
             :key :providers-url
             :detail (format nil "The provider catalog at ~A could not be read: ~A"
                             url condition)))))

(declaim (ftype (function () string) catalog-url))

(defun catalog-url ()
  "Return the models.dev document to fetch: *CATALOG-URL*, then :PROVIDERS-URL
from the active configuration, then models.dev itself."
  (or *catalog-url*
      (enchiridion:config-value (enchiridion:config) :providers-url)
      "https://models.dev/api.json"))

;; No FTYPE: SBCL requires pre-declared keyword types in &KEY FTYPEs.
(defun refresh-catalog (&key url path)
  "Fetch, trim, and atomically write the catalog index and model metadata, clearing memoized caches.
Signals on fetch/parse failure without modifying existing cache files; returns the new provider list."
  (let* ((url (or url (catalog-url)))
         (index-path (or path (catalog-path)))
         (models-path (if path
                          (merge-pathnames "provider-models.json" index-path)
                          (catalog-models-path))))
    (multiple-value-bind (index metadata) (trim-catalog (catalog-fetch url))
      (write-json-file index-path index)
      (write-json-file models-path metadata)
      (setf *catalog* nil
            *catalog-models* nil)
      (or (read-catalog-file index-path) '()))))
