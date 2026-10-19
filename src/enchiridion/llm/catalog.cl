;;;; catalog.cl --- The runtime models.dev catalog, cached under run/.
;;;;
;;;; No provider and no model is committed to this tree. Which providers exist,
;;;; what their endpoints are, which models they serve, what a model costs and
;;;; how large its context window is are all facts the vendors own and change on
;;;; their own schedule. This file fetches them from models.dev at run time,
;;;; trims them to what a request needs, and writes them under run/ so the next
;;;; process starts without a network.
;;;;
;;;; Two files are written and the split is deliberate. providers.json holds one
;;;; small row per provider: the id, the name, the npm package models.dev knows
;;;; it by, its key variable names, its endpoint, and the model the catalog
;;;; considers its default. provider-models.json holds the metadata of every
;;;; model in that index: the context window, the output limit, tool calling,
;;;; the four USD per million costs, and the release date. A live model list
;;;; from a provider's own endpoint is joined against the second file by model
;;;; id, so a request can be priced without a second network call.
;;;;
;;;; The parsed provider index is a LIST OF PROVIDER structs. A hash table keyed
;;;; by id would be no slower to look up, but two callers walk the index in
;;;; order --- detection matches a host against it, and the model list is joined
;;;; provider by provider --- and a list keeps that order in the open.
;;;;
;;;; Nothing here signals on a missing, unreadable or corrupt cache. A cache is
;;;; an optimisation, and an agent that refuses to start because a file under
;;;; run/ was half written is a worse failure than one that starts slowly and
;;;; refreshes.

(in-package #:enchiridion.llm)

;;;; The cache.

;; The index is read once and kept here. NIL means "not loaded", so a test
;; binds this to a fixture instead of touching run/, and a refresh clears it.
(defparameter *catalog* nil
  "The parsed provider index (a list of PROVIDER structs), or NIL when it has
not been loaded. The cache file is read once and memoised here.")

;; The model metadata is a second cache and a second special, because it is
;; read on a different schedule from the index: a provider's model list is
;; joined against it on every `providers models' call.
(defparameter *catalog-models* nil
  "Provider name to a list of MODEL-INFO, or NIL when it has not been loaded.
The metadata file beside the provider index is read once and memoised here.")

;; A test binds this; the operator sets ENCHIRIDION_PROVIDERS_PATH to write a
;; cache somewhere else while regenerating one. Both are checked in that order,
;; because a binding is a caller's decision and the variable is a session's.
(defparameter *catalog-path*
  (merge-pathnames "providers.json" (enchiridion:run-directory))
  "Where the provider index is cached. Resolved from the run directory when this
file loads, so ENCHIRIDION_HOME must be set before it does.")

(defparameter *catalog-models-path* nil
  "Where the model metadata is cached, or NIL for provider-models.json beside
*CATALOG-PATH*.")

(defparameter *catalog-url* nil
  "The models.dev document to fetch, or NIL to take :providers-url from the
configuration and then fall back to models.dev. A special so a test can point
the fetch at a fixture.")

(declaim (ftype (function () pathname) catalog-path))

(defun catalog-path ()
  "Return the provider index file to read and write.
ENCHIRIDION_PROVIDERS_PATH wins, because regenerating a cache elsewhere is the
one reason to name a path at all; then *CATALOG-PATH*."
  (let ((override (enchiridion.compat:environment-value "ENCHIRIDION_PROVIDERS_PATH")))
    (if (nonempty-string-p override) (pathname override) *catalog-path*)))

(declaim (ftype (function () pathname) catalog-models-path))

(defun catalog-models-path ()
  "Return the model metadata file: the override, or provider-models.json beside
the provider index."
  (or *catalog-models-path*
      (merge-pathnames "provider-models.json" (catalog-path))))

;;;; Small readers over parsed JSON.
;;;;
;;;; The document arrives in two shapes and both are handled here. parse-json
;;;; turns an object into a plist keyed by keywords; the file this module
;;;; writes is built with JSON-OBJECT, so a test may hand over a hash table
;;;; keyed by strings instead. One reader for both means the trimming and the
;;;; reading of the cache cannot disagree about what a field is called.

(declaim (ftype (function (t) boolean) nonempty-string-p))

(defun nonempty-string-p (value)
  "Return T when VALUE is a string with at least one character in it."
  (and (stringp value) (plusp (length value))))

(declaim (ftype (function (t) string) catalog-key-name))

(defun catalog-key-name (key)
  "Return KEY, a JSON object key, as the lower case string this module uses.
jzon pools short object keys and can hand over a character, which is why STRING
is called rather than trusting KEY to be one already."
  (string-downcase (string key)))

(declaim (ftype (function (t t &optional t) t) catalog-field))

(defun catalog-field (entry key &optional default)
  "Return KEY from ENTRY, a parsed JSON object, or DEFAULT.

ENTRY is a plist keyed by keywords after PARSE-JSON, or a hash table keyed by
strings after JSON-OBJECT. The comparison is case-insensitive and the key may
be a keyword, a string or a character, because all three arrive from the two
parsers and their callers."
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
  "Return KEY of ENTRY as a number, or NIL. Zero and NIL are different facts:
NIL means the source did not say."
  (let ((value (catalog-field entry key)))
    (if (numberp value) value nil)))

;;;; The environment placeholders models.dev writes into an endpoint.

(declaim (ftype (function (string) (or null string)) expand-environment))

(defun expand-environment (text)
  "Return TEXT with every ${NAME} replaced by NAME's environment value.

models.dev names an account-dependent endpoint that way: Azure's is
https://${AZURE_RESOURCE_NAME}.openai.azure.com/. A name the environment does
not hold makes the endpoint unknowable, and an endpoint with a hole in it is
worse than none, so the whole string comes back NIL in that case rather than a
URL that fails later without saying why."
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
               (value (and name (enchiridion.compat:environment-value name))))
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
  "Return DATA, a JSON object, as a list of (key . value) with string keys.

A hash table is read directly; a plist is walked two at a time. A key that is
NIL ends the walk, which is what a malformed object looks like rather than a
crash in the middle of a cache refresh."
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
  "Return DATA as a list of (key . value) sorted by key.

models.dev is a map and a map has no order; sorting here is what makes the
written cache, the detection scan and the model metadata join reproducible from
one process to the next."
  (sort (map-pairs data) #'string< :key #'car))

(declaim (ftype (function (t) boolean) wrapper-shape-p))

(defun wrapper-shape-p (data)
  "Return T when DATA is this module's wrapper, {\"meta\" ..., \"providers\" ...},
rather than models.dev's own flat map of provider id to provider.

The test is the key set, not the presence of \"providers\": a flat map whose
keys are a hundred provider ids cannot be confused with a two key wrapper, and
the value of \"providers\" is required not to look like a provider row itself."
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
  "Return ENTRY's release date as a string, or the empty string.
The dates are ISO 8601, so they sort lexicographically, and a model that has
none sorts before every model that does."
  (or (catalog-string entry "release_date") (catalog-string entry "last_updated") ""))

(declaim (ftype (function (list) cons) best-catalog-model))

(defun best-catalog-model (models)
  "Return the latest model in MODELS, a list of (id . entry).
The greatest release date wins and the smallest id breaks a tie, so two
snapshots released the same month always resolve to the same model."
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
  "Return the model id the catalog considers the default, or NIL.

A model that cannot call tools cannot drive this harness, whatever its context
window says, so tool callers are preferred. A catalog with no such model still
has a newest model, and a catalog with no models has no answer at all."
  (when models
    (let ((tool-models (remove-if-not (lambda (model)
                                        (catalog-field (cdr model) "tool_call"))
                                      models)))
      (car (best-catalog-model (or tool-models models))))))

;;;; The npm package to the wire it speaks.
;;;;
;;;; models.dev says which AI SDK package a provider is built with. This tree
;;;; has no SDK, so the package is what says whether the endpoint speaks the
;;;; chat completions shape, the Messages shape, or something only a vendor
;;;; file above this one knows. Only the protocol is decided here; the adapter
;;;; id and the per-vendor base URL are the provider table's business.

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
  "Return ENTRY's env field as a list of names. A provider with none answers
the empty list, because the callers all append and NIL is not an appendable
list in every one of them."
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
  "Return ENTRY, one model of the models.dev document, as a small JSON object.
Cost and limit travel as four flat numbers and one context/output pair, because
the only reader is the model list join, which asks by name and not by shape."
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
  "Return DATA, a parsed models.dev document, trimmed to what a cache needs.

Two values come back, both JSON objects built with JSON-OBJECT so that
STRINGIFY writes them as objects rather than as arrays. The first is the
provider index {\"meta\" ... \"providers\" {id row}}; the second is the model
metadata {\"providers\" {id [model ...]}}. The provider row keeps only
id, name, npm, env, api, doc, the computed default model, and the protocol the
npm package implies; everything else models.dev carries is dropped, because a
cache that grows with the catalog is a cache that has to be re-read in full."
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
  "Return ID as a keyword, or NIL when it is not a name at all.

A provider id is written as a keyword in config.cl, as a string in a
configuration that was read from a file, and as a string in the catalog; all
three are one value here. The keyword is interned in KEYWORD, which is legal to
grow at run time because it is the one package a program may extend.

NIL is tested first and that test is load bearing. NIL is a symbol, so the
SYMBOLP clause below would intern it and answer :NIL, which is a true value:
every `missing :provider means use detection' path would then select a provider
called NIL instead."
  (cond
    ((null id) nil)
    ((keywordp id) id)
    ((stringp id) (and (plusp (length id)) (intern (string-upcase id) :keyword)))
    ((symbolp id) (intern (string-upcase (symbol-name id)) :keyword))
    (t nil)))

(declaim (ftype (function (t) string) provider-cache-name))

(defun provider-cache-name (id)
  "Return ID as the lower case name the model metadata is keyed by and the
per-provider model cache file is named after. A character that is not safe in
a file name becomes a hyphen, so a catalog id can never name a directory."
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
  "Return ENTRIES, an array of model objects that carry their own id, as a
list of MODEL-INFO.

This is the shape the per-provider model cache is written in, and it is not
the shape the catalog metadata is written in: a provider's list has no key to
hang a model on because the endpoint already said the id, while the catalog
map is keyed by provider. Reading one with the other's reader answers an empty
list rather than an error, which is why the two readers are separate."
  (if (consp entries)
      (loop for entry in entries
            for id = (catalog-field entry "id")
            when (nonempty-string-p id)
              collect (model-info-from-data id entry source))
      '()))

(declaim (ftype (function (t t) provider) catalog-index-row))

(defun catalog-index-row (id entry)
  "Return one row of the provider index as a PROVIDER struct.

The endpoint, the npm package and the protocol are kept in OPTIONS rather than
in slots, because none of them is a field the registry knows about; the
provider table above this file turns them into an adapter id and a base URL."
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
  "Return the provider index cached at PATH, or NIL.

The wrapper this module writes and models.dev's own flat map are both accepted,
unknown keys are ignored, and a missing, unreadable or corrupt file is NIL
rather than a condition: the caller falls back to the shipped rows and, when it
may, to a refresh."
  (let ((data (ignore-errors (parse-json (uiop:read-file-string path)))))
    (when data (ignore-errors (catalog-index data)))))

(declaim (ftype (function (t) (or null hash-table)) read-catalog-models-file))

(defun read-catalog-models-file (path)
  "Return the model metadata cached at PATH as a hash table of provider name to
a list of MODEL-INFO, or NIL when there is no usable file."
  (let ((data (ignore-errors (parse-json (uiop:read-file-string path)))))
    (when data
      (let ((table (make-hash-table :test #'equal)))
        (dolist (pair (map-pairs (catalog-field data "providers")))
          (setf (gethash (car pair) table)
                (model-info-array (cdr pair))))
        table))))

(declaim (ftype (function () (or null list)) catalog-providers))

(defun catalog-providers ()
  "Return the cached provider index, reading the cache file once.

NIL means there is no cache: no file, an unreadable one, or one that is not
this shape. The NIL is not memoised, so a later call after a refresh sees the
new file without a second entry point."
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
  "Return the models.dev metadata for PROVIDER, or NIL.

This is the fallback a provider's own model endpoint falls back to, and the
source of the cost and limit metadata joined onto a live list."
  (gethash (provider-cache-name (provider-id provider)) (catalog-model-metadata)))

;;;; Expiry.

(declaim (ftype (function (t t) boolean) catalog-expired-p))

(defun catalog-expired-p (path ttl)
  "Return T when the cache at PATH is missing or older than TTL seconds.

TTL is the configuration's :providers-ttl-seconds or :models-ttl-seconds. NIL
and a non-positive TTL both mean `always stale': an operator who configured no
lifetime asked for a fresh read, and the alternative, a cache that never
expires, hides a provider's new endpoint forever."
  (let ((written (ignore-errors (file-write-date path))))
    (or (null written)
        (not (and (numberp ttl) (plusp ttl)))
        (> (- (get-universal-time) written) ttl))))

;;;; Fetching and writing.

(declaim (ftype (function (string) t) fetch-catalog-text))

(defun fetch-catalog-text (url)
  "GET URL and return the reply text, with a bounded wait.

The transport is a special so that no test opens a socket, exactly like the
model listers' calls: *HTTP-GET-FUNCTION* is the one door to the network on
this path."
  (funcall *http-get-function* url :timeout +http-get-timeout+))

(declaim (ftype (function (t t) t) write-json-file))

(defun write-json-file (path object)
  "Write OBJECT as JSON to PATH and return PATH.

The write is a temp file beside the target and a rename over it, so a reader
never sees half a document and a failure leaves the previous file in place. The
rename is UIOP's, which is the one portable spelling of `replace this file'."
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
  "Return the catalog at URL parsed, or signal a condition the CLI can print.

A refusal from the transport becomes a TRANSPORT-ERROR carrying the status, so
`enchiridion providers refresh' reports one line and returns 1. Anything else,
including a body that is not JSON, becomes a CONFIGURATION-ERROR at
:PROVIDERS-URL, because that is the key whose value named the URL."
  (handler-case (parse-json (fetch-catalog-text url))
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

;; No F-TYPE: REFRESH-CATALOG and PROVIDER-MODELS take &KEY arguments, and SBCL
;; wants every keyword in an F-TYPE lambda list to have been declared in one
;; already, which for these two would be a dummy declaration per keyword. See
;; RESOLVE-BACKEND in providers.cl for the same choice.
(defun refresh-catalog (&key url path)
  "Fetch the catalog, trim it, write it, and return the new provider index.

URL defaults to the configuration's :providers-url; PATH defaults to
CATALOG-PATH, and when PATH is given the model metadata is written beside it.
The index is returned as a list of PROVIDER structs, so a caller can use it
without reading the file back. A fetch or parse failure signals, and the
previous cache is untouched because the write happens only after a successful
fetch."
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
