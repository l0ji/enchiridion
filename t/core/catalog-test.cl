;;;; catalog-test.cl --- The runtime models.dev catalog and its cache.
;;;;
;;;; Every test here runs offline. The GET is a special, the cache paths are
;;;; bound to a scratch directory, and neither run/ nor a socket is touched.
;;;; The fixture is a small models.dev document written as the parsed Lisp
;;;; shape PARSE-JSON produces, because that is the shape a fetched document
;;;; really arrives in; one test writes the wrapper and reads it back so that
;;;; the JSON round trip is covered as well.

(defpackage #:enchiridion-catalog-test
  (:use #:cl)
  (:import-from #:rove #:deftest #:ok #:ng #:testing #:signals)
  (:export #:run))

(in-package #:enchiridion-catalog-test)

(defmacro with-scratch-directory ((name) &body body)
  "Bind NAME to a fresh temporary directory, run BODY, then remove it.
Scratch lives under *DEFAULT-PATHNAME-DEFAULTS* rather than under TMPDIR: the
build directory is writable and the nix sandbox has no writable /tmp."
  `(let ((,name (uiop:ensure-directory-pathname
                  (merge-pathnames
                   (format nil "enchiridion-catalog-test-~D/" (random most-positive-fixnum))
                   (uiop:ensure-directory-pathname *default-pathname-defaults*)))))
     (unwind-protect
          (progn ,@body)
       (uiop:delete-directory-tree ,name :validate t :if-does-not-exist :ignore))))

;;;; The fixture.

(defparameter +catalog+
  '(:alpha
    (:id "alpha" :name "Alpha" :env ("ALPHA_API_KEY")
     :npm "@ai-sdk/openai-compatible"
     :api "https://alpha.example/v1"
     :doc "https://alpha.example/docs"
     :models
     (:z-tool (:id "z-tool" :name "Z Tool" :tool_call t
               :release_date "2026-01-01"
               :limit (:context 1000 :output 100)
               :cost (:input 1 :output 2 :cache_read 0.1 :cache_write 0.2))
      :a-tool (:id "a-tool" :name "A Tool" :tool_call t
               :release_date "2026-01-01")
      :later-no-tool (:id "later-no-tool" :tool_call nil
                      :release_date "2026-09-01")))
    :beta
    (:id "beta" :name "Beta" :env ("BETA_API_KEY")
     :npm "@ai-sdk/anthropic"
     :models
     (:b-1 (:id "b-1" :tool_call nil :release_date "2026-05-01")
      :b-0 (:id "b-0" :tool_call nil :release_date "2026-06-01")))
    :gamma
    (:id "gamma" :name "Gamma" :env ("GAMMA_API_KEY")
     :npm "cohere-ai"
     :api "https://gamma.example/v1"
     :models (:g-b (:id "g-b") :g-a (:id "g-a")))
    :delta
    (:id "delta" :name "Delta" :env ("DELTA_API_KEY")
     :npm "@ai-sdk/google"))
  "A small models.dev document, already parsed. ALPHA's two tool callers are
released the same month so the tie-break is exercised, and a newer model that
cannot call tools must not win. BETA has no tool caller at all; GAMMA has no
release dates; DELTA has no models.")

(defparameter +flat-json+
  "{\"alpha\":{\"id\":\"alpha\",\"name\":\"Alpha\",\"env\":[\"ALPHA_API_KEY\"],\
\"npm\":\"@ai-sdk/openai-compatible\",\"api\":\"https://alpha.example/v1\",\
\"doc\":\"https://alpha.example/docs\",\"models\":{\
\"z-tool\":{\"id\":\"z-tool\",\"name\":\"Z Tool\",\"tool_call\":true,\
\"release_date\":\"2026-01-01\",\"limit\":{\"context\":1000,\"output\":100},\
\"cost\":{\"input\":1,\"output\":2,\"cache_read\":0.1,\"cache_write\":0.2}},\
\"a-tool\":{\"id\":\"a-tool\",\"tool_call\":true,\"release_date\":\"2026-01-01\"},\
\"later-no-tool\":{\"id\":\"later-no-tool\",\"tool_call\":false,\
\"release_date\":\"2026-09-01\"}}}}"
  "models.dev's own shape: a flat map of provider id to provider.")

(defparameter +wrapped-json+
  "{\"meta\":{\"generated_at\":\"2026-01-01T00:00:00Z\",\"count\":1},\
\"providers\":{\"alpha\":{\"id\":\"alpha\",\"name\":\"Alpha\",\
\"env\":[\"ALPHA_API_KEY\"],\"npm\":\"@ai-sdk/openai-compatible\",\
\"api\":\"https://alpha.example/v1\",\"doc\":\"https://alpha.example/docs\",\
\"default\":\"a-tool\",\"protocol\":\"openai\"}}}"
  "This module's own cache shape: a two key wrapper.")

(defparameter +endpoint-json+
  "{\"azureish\":{\"id\":\"azureish\",\"name\":\"Azureish\",\
\"env\":[\"AZUREISH_API_KEY\"],\"npm\":\"@ai-sdk/openai-compatible\",\
\"api\":\"https://${AZUREISH_HOST}.example/v1\"}}"
  "One provider whose endpoint depends on an environment variable.")

;;;; Small readers so an assertion is about a value and not about JSON.

(defun write-text (path text)
  "Write TEXT to PATH, creating the directory."
  (ensure-directories-exist path)
  (with-open-file (stream path :direction :output
                               :if-exists :supersede
                               :if-does-not-exist :create
                               :external-format :utf-8)
    (write-string text stream))
  path)

(defun stub-get (text &optional counter)
  "Return a *HTTP-GET-FUNCTION* that answers TEXT and counts its calls in
COUNTER, a cons whose car is incremented. The signature matches HTTP-GET's, so
a caller that passes :timeout or :headers is answered rather than refused."
  (lambda (url &key headers timeout)
    (declare (ignore url headers timeout))
    (when counter (incf (car counter)))
    text))

(defun trimmed-provider (trimmed id)
  "Return the trimmed row for ID from a TRIM-CATALOG result."
  (enchiridion.llm::catalog-field (enchiridion.llm::catalog-field trimmed "providers") id))

(defun index-ids (index)
  "Return the ids of a provider index, in order."
  (mapcar #'enchiridion.llm:provider-id index))

(defun index-provider (index id)
  "Return the PROVIDER called ID from INDEX, or NIL."
  (find id index :key #'enchiridion.llm:provider-id :test #'eq))

;;;; The trim.

(deftest the-trim-keeps-exactly-the-fields-a-cache-needs ()
  (multiple-value-bind (trimmed metadata) (enchiridion.llm::trim-catalog +catalog+)
    (let ((row (trimmed-provider trimmed "alpha")))
      (ok (string= "alpha" (enchiridion.llm::catalog-field row "id")))
      (ok (string= "Alpha" (enchiridion.llm::catalog-field row "name")))
      (ok (string= "@ai-sdk/openai-compatible"
                   (enchiridion.llm::catalog-field row "npm")))
      (ok (string= "https://alpha.example/v1"
                   (enchiridion.llm::catalog-field row "api")))
      (ok (equal '("ALPHA_API_KEY") (enchiridion.llm::catalog-field row "env")))
      (testing "nothing else models.dev carries survives the trim"
        (ok (= 8 (hash-table-count row)))))
    (testing "the model metadata is kept for the model list join"
      (let* ((models (enchiridion.llm::catalog-field metadata "providers"))
             (alpha (enchiridion.llm::catalog-field models "alpha"))
             (z (find "z-tool" alpha
                      :key (lambda (model)
                             (enchiridion.llm::catalog-field model "id"))
                      :test #'string=)))
        (ok (= 3 (length alpha)))
        (ok (= 1000 (enchiridion.llm::catalog-field z "context")))
        (ok (eql 2 (enchiridion.llm::catalog-field z "cost_output")))))))

(deftest the-default-model-prefers-a-model-that-calls-tools ()
  (multiple-value-bind (trimmed metadata) (enchiridion.llm::trim-catalog +catalog+)
    (declare (ignore metadata))
    (testing "a newer model that cannot call tools loses"
      (ok (string= "a-tool"
                   (enchiridion.llm::catalog-field
                    (trimmed-provider trimmed "alpha") "default"))))
    (testing "the smallest id breaks a release-date tie"
      (ok (string= "b-0"
                   (enchiridion.llm::catalog-field
                    (trimmed-provider trimmed "beta") "default"))))
    (testing "with no release dates at all the smallest id wins"
      (ok (string= "g-a"
                   (enchiridion.llm::catalog-field
                    (trimmed-provider trimmed "gamma") "default"))))
    (testing "a provider with no models has no default"
      (ok (null (enchiridion.llm::catalog-field
                 (trimmed-provider trimmed "delta") "default"))))))

(deftest npm-decides-the-protocol ()
  (multiple-value-bind (trimmed metadata) (enchiridion.llm::trim-catalog +catalog+)
    (declare (ignore metadata))
    (flet ((protocol (id)
             (enchiridion.llm::catalog-field (trimmed-provider trimmed id) "protocol")))
      (ok (string= "openai" (protocol "alpha")))
      (ok (string= "anthropic" (protocol "beta")))
      (testing "a package this build does not know implies no protocol"
        (ok (null (protocol "gamma")))))))

;;;; Reading a cache file.

(deftest the-index-reads-the-wrapper-and-the-flat-map ()
  (with-scratch-directory (scratch)
    (let* ((wrapped (write-text (merge-pathnames "wrapped.json" scratch) +wrapped-json+))
           (flat (write-text (merge-pathnames "flat.json" scratch) +flat-json+))
           (from-wrapper (enchiridion.llm:read-catalog-file wrapped))
           (from-flat (enchiridion.llm:read-catalog-file flat)))
      (ok (equal '(:alpha) (index-ids from-wrapper)))
      (ok (equal '(:alpha) (index-ids from-flat)))
      (testing "both shapes carry the same facts"
        (dolist (index (list from-wrapper from-flat))
          (let ((provider (index-provider index :alpha)))
            (ok (string= "https://alpha.example/v1"
                         (enchiridion.llm:provider-base-url provider)))
            (ok (string= "a-tool"
                         (enchiridion.llm:provider-default-model provider)))
            (ok (equal '("ALPHA_API_KEY") (enchiridion.llm:provider-env provider)))
            (ok (eq :openai (enchiridion.llm:provider-option provider :protocol)))))))))

(deftest a-broken-cache-is-not-an-error ()
  (with-scratch-directory (scratch)
    (testing "a file that is not there"
      (ok (null (enchiridion.llm:read-catalog-file
                 (merge-pathnames "absent.json" scratch)))))
    (testing "a file that is not JSON"
      (let ((path (write-text (merge-pathnames "corrupt.json" scratch)
                              "{\"providers\": [")))
        (ok (null (enchiridion.llm:read-catalog-file path)))))
    (testing "JSON that is the wrong shape"
      (let ((path (write-text (merge-pathnames "wrong.json" scratch) "[1,2,3]")))
        (ok (null (enchiridion.llm:read-catalog-file path)))))))

(deftest an-endpoint-placeholder-is-expanded-or-unknown ()
  (with-scratch-directory (scratch)
    (let ((path (write-text (merge-pathnames "endpoint.json" scratch) +endpoint-json+)))
      (unwind-protect
           (progn
             (enchiridion.compat:set-environment-variable "AZUREISH_HOST" "acme")
             (ok (string= "https://acme.example/v1"
                          (enchiridion.llm:provider-base-url
                           (index-provider (enchiridion.llm:read-catalog-file path)
                                           :azureish))))
             (testing "a variable the environment does not hold makes the endpoint unknown"
               (enchiridion.compat:unset-environment-variable "AZUREISH_HOST")
               (ok (string= ""
                            (enchiridion.llm:provider-base-url
                             (index-provider (enchiridion.llm:read-catalog-file path)
                                             :azureish))))))
        (enchiridion.compat:unset-environment-variable "AZUREISH_HOST")))))

;;;; Expiry.

(deftest a-cache-expires-when-it-is-older-than-the-ttl ()
  (with-scratch-directory (scratch)
    (let ((path (write-text (merge-pathnames "cache.json" scratch) +wrapped-json+)))
      (testing "a file that is not there is expired"
        (ok (enchiridion.llm::catalog-expired-p (merge-pathnames "absent.json" scratch)
                                                86400)))
      (testing "a fresh file is not expired"
        (ng (enchiridion.llm::catalog-expired-p path 86400)))
      (testing "a zero or absent lifetime always refreshes"
        (ok (enchiridion.llm::catalog-expired-p path 0))
        (ok (enchiridion.llm::catalog-expired-p path nil))))))

;;;; Fetching and writing.

(deftest refresh-writes-the-cache-and-returns-the-index ()
  (with-scratch-directory (scratch)
    (let* ((path (merge-pathnames "providers.json" scratch))
           (models-path (merge-pathnames "provider-models.json" scratch))
           (calls (list 0))
           (enchiridion.llm::*http-get-function* (stub-get +flat-json+ calls)))
      (let ((index (enchiridion.llm:refresh-catalog
                    :url "https://fixture.test/api.json" :path path)))
        (ok (= 1 (car calls)))
        (ok (equal '(:alpha) (index-ids index)))
        (ok (string= "a-tool"
                     (enchiridion.llm:provider-default-model
                      (index-provider index :alpha))))
        (testing "the index is on disk, wrappered, and readable"
          (ok (probe-file path))
          (ok (string= "a-tool"
                       (enchiridion.llm:provider-default-model
                        (index-provider (enchiridion.llm:read-catalog-file path)
                                        :alpha)))))
        (testing "the model metadata is written beside it"
          (ok (probe-file models-path)))
        (testing "the memo is cleared, so the next reader sees the new file"
          (let ((enchiridion.llm::*catalog-path* path))
            (ok (equal '(:alpha)
                       (index-ids (enchiridion.llm:catalog-providers))))))))))

(deftest a-failed-refresh-leaves-the-old-cache-alone ()
  (with-scratch-directory (scratch)
    (let* ((path (write-text (merge-pathnames "providers.json" scratch) +wrapped-json+))
           (before (uiop:read-file-string path))
           (enchiridion.llm::*http-get-function*
             (lambda (url &key headers timeout)
               (declare (ignore url headers timeout))
               (error "the network is not there"))))
      (ok (signals (enchiridion.llm:refresh-catalog
                    :url "https://fixture.test/api.json" :path path)
                   'enchiridion.errors:configuration-error))
      (ok (string= before (uiop:read-file-string path)))
      (testing "and the old cache still reads"
        (ok (equal '(:alpha)
                   (index-ids (enchiridion.llm:read-catalog-file path))))))))

(deftest a-reply-that-is-not-the-catalog-is-a-configuration-error ()
  (with-scratch-directory (scratch)
    (let* ((path (merge-pathnames "providers.json" scratch))
           (enchiridion.llm::*http-get-function* (stub-get "<html>nope</html>")))
      (ok (signals (enchiridion.llm:refresh-catalog
                    :url "https://fixture.test/api.json" :path path)
                   'enchiridion.errors:configuration-error))
      (ng (probe-file path)))))

(deftest the-catalog-is-read-once-and-kept ()
  (with-scratch-directory (scratch)
    (let* ((path (write-text (merge-pathnames "providers.json" scratch) +wrapped-json+))
           (enchiridion.llm::*catalog-path* path)
           (enchiridion.llm::*catalog* nil))
      (let ((first-read (enchiridion.llm:catalog-providers)))
        (ok (equal '(:alpha) (index-ids first-read)))
        (testing "the second call answers from the memo"
          (ok (eq first-read (enchiridion.llm:catalog-providers)))))
      (testing "a bound catalog is the answer, file or no file"
        (let ((enchiridion.llm::*catalog* (enchiridion.llm::catalog-index +catalog+)))
          (ok (equal '(:alpha :beta :delta :gamma)
                     (index-ids (enchiridion.llm:catalog-providers)))))))))
