;;;; provider-test.cl --- The provider table: rows, detection, models.
;;;;
;;;; Every test runs offline. The catalog is a fixture bound to *CATALOG*, the
;;;; model endpoint is a stubbed *HTTP-GET-FUNCTION*, and the model cache is a
;;;; scratch directory, so neither run/ nor a socket is touched.
;;;;
;;;; The fixture catalog deliberately carries providers this build can serve
;;;; (the OpenAI-compatible and Anthropic packages) beside ones it cannot
;;;; (google, cohere), because the interesting behaviour is what the table does
;;;; with a row it has no adapter for: it lists it, refuses to build it, and
;;;; keeps its key variable out of the scrubber's list.

(defpackage #:enchiridion-provider-test
  (:use #:cl)
  (:import-from #:rove #:deftest #:ok #:ng #:testing #:signals)
  (:export #:run))

(in-package #:enchiridion-provider-test)

(defmacro with-shipped-providers (&body body)
  "Run BODY with no provider key in the environment and no cached catalog.

These tests are about which key selects which provider and which model a
shipped row names. The gate can run on a machine that has ANTHROPIC_API_KEY
exported, and a cached run/providers.json changes step five of detection, so
without this wrapper the suite reports on the shell that started it. The
previous values are always put back."
  (let ((names '("OPENAI_API_KEY" "OPENCODE_API_KEY" "ANTHROPIC_API_KEY")))
    `(let ((previous (loop for name in ',names
                           collect (cons name (enchiridion.compat:environment-value name))))
           (enchiridion.llm::*catalog* nil)
           (enchiridion.llm::*catalog-path* #p"/nonexistent/enchiridion-providers.json"))
       (unwind-protect
            (progn
              (dolist (name ',names)
                (enchiridion.compat:unset-environment-variable name))
              ,@body)
         (dolist (pair previous)
           (if (cdr pair)
               (enchiridion.compat:set-environment-variable (car pair) (cdr pair))
               (enchiridion.compat:unset-environment-variable (car pair))))))))


(defmacro with-scratch-directory ((name) &body body)
  "Bind NAME to a fresh temporary directory, run BODY, then remove it."
  `(let ((,name (uiop:ensure-directory-pathname
                  (merge-pathnames
                   (format nil "enchiridion-provider-test-~D/" (random most-positive-fixnum))
                   (uiop:ensure-directory-pathname *default-pathname-defaults*)))))
     (unwind-protect
          (progn ,@body)
       (uiop:delete-directory-tree ,name :validate t :if-does-not-exist :ignore))))

(defmacro with-empty-catalog (&body body)
  "Run BODY with no catalog at all: no file, no memo, no metadata."
  `(let ((enchiridion.llm::*catalog-path*
           (merge-pathnames "absent-catalog/providers.json"
                            (uiop:ensure-directory-pathname *default-pathname-defaults*)))
         (enchiridion.llm::*catalog* nil)
         (enchiridion.llm::*catalog-models* (make-hash-table :test #'equal)))
     ,@body))

(defmacro with-fixture-catalog (&body body)
  "Run BODY with the fixture catalog already parsed and memoised."
  `(let ((enchiridion.llm::*catalog* (enchiridion.llm::catalog-index +catalog+))
         (enchiridion.llm::*catalog-models* (make-hash-table :test #'equal)))
     ,@body))

;;;; The fixture.

(defparameter +catalog+
  '(:opencode
    (:id "opencode" :name "OpenCode Catalog" :env ("OPENCODE_CATALOG_KEY")
     :npm "@ai-sdk/openai-compatible"
     :api "https://catalog.opencode.example/v1")
    :groq
    (:id "groq" :name "Groq" :env ("GROQ_API_KEY")
     :npm "@ai-sdk/groq"
     :models (:gpt-oss-120b (:id "gpt-oss-120b" :name "GPT OSS 120B"
                             :tool_call t :release_date "2026-02-01"
                             :limit (:context 65536 :output 65536)
                             :cost (:input 0.23 :output 0.92))))
    :zhost
    (:id "zhost" :name "Z Host" :env ("ZHOST_API_KEY")
     :npm "@ai-sdk/openai-compatible"
     :api "https://zhost.example/v1")
    :host-two
    (:id "host-two" :name "Host Two" :env ("HOST_TWO_API_KEY")
     :npm "@ai-sdk/openai-compatible"
     :api "https://zhost.example/v1")
    :cohere
    (:id "cohere" :name "Cohere" :env ("COHERE_API_KEY")
     :npm "cohere-ai"
     :api "https://cohere.example/v1")
    :bedrockish
    (:id "bedrockish" :name "Bedrockish" :env ("AWS_ACCESS_KEY_ID")
     :npm "@ai-sdk/amazon-bedrock")
    :vertexish
    (:id "vertexish" :name "Vertexish" :env ("GOOGLE_VERTEX_PROJECT")
     :npm "@ai-sdk/google-vertex/anthropic")
    :azureish
    (:id "azureish" :name "Azureish" :env ("AZURE_OPENAI_API_KEY")
     :npm "@ai-sdk/azure"
     :api "https://acme.openai.azure.com/")
    :cloudflareish
    (:id "cloudflareish" :name "Cloudflareish" :env ("CLOUDFLARE_API_TOKEN")
     :npm "ai-gateway-provider")
    :fixture-openai
    (:id "fixture-openai" :name "Fixture OpenAI" :env ("FIXTURE_API_KEY")
     :npm "@ai-sdk/openai-compatible"
     :api "https://fixture.example/v1"
     :models (:fx-1 (:id "fx-1" :name "Fixture One" :tool_call t
                     :release_date "2026-01-01")))
    :fixture-google
    (:id "fixture-google" :name "Fixture Google" :env ("GOOGLE_API_KEY")
     :npm "@ai-sdk/google")
    :fixture-other
    (:id "fixture-other" :name "Fixture Other" :env ("FIXTURE_BASE_URL")
     :npm "@ai-sdk/openai-compatible"
     :api "https://fixture-other.example/v1"))
  "A small catalog: a package this build serves and one it does not, two
providers that share a host so the sorted-id rule is exercised, a vendor whose
endpoint models.dev does not carry, and Azure's placeholder-free endpoint.")

;;;; Helpers.

(defun stub-get (text &optional counter)
  "Return a *HTTP-GET-FUNCTION* that answers TEXT and counts its calls.
The signature is HTTP-GET's, so a caller that passes :timeout or :headers is
answered rather than refused."
  (lambda (url &key headers timeout)
    (declare (ignore url headers timeout))
    (when counter (incf (car counter)))
    text))

(defun failing-get ()
  "Return a *HTTP-GET-FUNCTION* that always signals."
  (lambda (url &key headers timeout)
    (declare (ignore url headers timeout))
    (error "the model endpoint is not there")))

(defun provider-of (id &optional (config '()))
  "Return the resolved PROVIDER for ID under CONFIG, or NIL when it refuses."
  (handler-case (enchiridion.llm:resolve-provider
                 (append (list :llm (list :provider id)) config)
                 :api-key "k")
    (error () nil)))

(defun model-ids (models)
  "Return the ids of a list of MODEL-INFO."
  (mapcar #'enchiridion.llm:model-info-id models))

(defun race-condition (form)
  "Call FORM and return the CONFIGURATION-ERROR it signalled, or NIL."
  (handler-case (progn (funcall form) nil)
    (enchiridion.errors:configuration-error (condition) condition)))

;;;; Rows.

(deftest the-shipped-rows-are-the-three-the-build-promises ()
  (with-empty-catalog
    (let ((rows (enchiridion.llm::provider-rows '())))
      (ok (equal '(:openai :opencode :anthropic)
                 (mapcar #'enchiridion.llm:provider-id rows)))
      (let ((openai (find :openai rows :key #'enchiridion.llm:provider-id)))
        (ok (search "api.openai.com" (enchiridion.llm:provider-base-url openai)))
        (ok (string= "gpt-5.6-luna" (enchiridion.llm:provider-model openai)))
        (ok (equal '("OPENAI_API_KEY") (enchiridion.llm:provider-env openai)))
        (ok (eq :shipped (enchiridion.llm:provider-source openai)))))))

(deftest an-operator-row-overrides-the-shipped-one-field-by-field ()
  (with-empty-catalog
    (let* ((config '(:llm (:providers ((:id :openai :api-key-env "MY_OPENAI_KEY")))))
           (rows (enchiridion.llm::provider-rows config))
           (openai (find :openai rows :key #'enchiridion.llm:provider-id)))
      (ok (equal '("MY_OPENAI_KEY") (enchiridion.llm:provider-env openai)))
      (testing "everything the row did not name is inherited"
        (ok (search "api.openai.com" (enchiridion.llm:provider-base-url openai)))
        (ok (string= "gpt-5.6-luna" (enchiridion.llm:provider-model openai)))
        (ok (string= "OpenAI" (enchiridion.llm:provider-name openai))))
      (ok (eq :config (enchiridion.llm:provider-source openai))))))

(deftest a-row-without-an-id-is-a-configuration-error ()
  (with-empty-catalog
    (let ((condition (race-condition
                      (lambda ()
                        (enchiridion.llm::provider-plists
                         '(:llm (:providers ((:name "No Id")))))))))
      (ok condition)
      (ok (eq :providers (enchiridion.errors::configuration-key condition))))))

(deftest a-catalog-row-is-inherited-by-an-operator-override ()
  (with-fixture-catalog
    (let* ((config '(:llm (:providers ((:id :opencode
                                       :api-key-env "MY_OPENCODE_KEY")))))
           (rows (enchiridion.llm::provider-rows config))
           (opencode (find :opencode rows :key #'enchiridion.llm:provider-id)))
      (testing "the shipped row wins over the catalog row of the same id"
        (ok (search "opencode.ai/zen/go/v1"
                    (enchiridion.llm:provider-base-url opencode))))
      (ok (equal '("MY_OPENCODE_KEY") (enchiridion.llm:provider-env opencode)))
      (ok (eq :openai-chat (enchiridion.llm:provider-api opencode))))))

;;;; The npm package adapters.

(deftest npm-packages-map-to-the-adapter-that-speaks-them ()
  (with-fixture-catalog
    (flet ((row (id) (provider-of id)))
      (let ((groq (row :groq)))
        (ok (eq :openai-chat (enchiridion.llm:provider-api groq)))
        (ok (eq :openai (enchiridion.llm:provider-profile groq)))
        (testing "a package whose catalog entry has no endpoint gets the vendor default"
          (ok (string= "https://api.groq.com/openai/v1"
                       (enchiridion.llm:provider-base-url groq))))
        (ok (enchiridion.llm:provider-supported-p groq)))
      (testing "azure, openrouter and cloudflare carry a profile"
        (ok (eq :azure (enchiridion.llm:provider-profile (row :azureish))))
        (ok (eq :openai-chat (enchiridion.llm:provider-api (row :cloudflareish))))
        (ok (eq :cloudflare-gateway
                (enchiridion.llm:provider-profile (row :cloudflareish))))
        (ok (string= "https://gateway.ai.cloudflare.com/v1"
                     (enchiridion.llm:provider-base-url (row :cloudflareish)))))
      (testing "the vendor-only wires have their own adapters"
        (ok (eq :bedrock-invoke (enchiridion.llm:provider-api (row :bedrockish))))
        (ok (eq :vertex-anthropic (enchiridion.llm:provider-api (row :vertexish))))
        (ok (eq :vertex (enchiridion.llm:provider-profile (row :vertexish)))))
      (testing "a package this build does not know is unsupported"
        (let ((cohere (row :cohere)))
          (ok (null (enchiridion.llm:provider-api cohere)))
          (ng (enchiridion.llm:provider-supported-p cohere)))))))

(deftest an-unsupported-provider-names-itself-and-the-fix ()
  (with-fixture-catalog
    (let ((condition (race-condition
                      (lambda ()
                        (enchiridion.llm:resolve-backend
                         :config '(:llm (:provider :cohere)) :api-key "k")))))
      (ok condition)
      (ok (search "cohere" (enchiridion.errors:error-detail condition)))
      (ok (search ":base-url" (enchiridion.errors:error-detail condition))))))

(deftest a-catalog-only-provider-resolves-and-builds ()
  (with-fixture-catalog
    (let* ((config '(:llm (:provider :groq) (:api-key-env "GROQ_API_KEY")))
           (provider (enchiridion.llm:resolve-provider config :api-key "k")))
      (ok (eq :groq (enchiridion.llm:provider-id provider)))
      (ok (eq :catalog (enchiridion.llm:provider-source provider)))
      (ok (string= "gpt-oss-120b" (enchiridion.llm:provider-model provider)))
      (let ((backend (enchiridion.llm:resolve-backend :config config :api-key "k")))
        (ok (enchiridion.llm:backendp backend))
        (ok (search "api.groq.com" (enchiridion.llm:backend-name backend)))
        (ok (string= "gpt-oss-120b"
                     (enchiridion.llm::openai-connection-model backend)))))))

;;;; :custom.

(deftest a-custom-provider-comes-from-the-llm-keys ()
  (with-empty-catalog
    (testing "without a base URL it is a configuration error at :base-url"
      (let ((condition (race-condition
                        (lambda ()
                          (enchiridion.llm:resolve-provider '(:llm (:provider :custom)))))))
        (ok condition)
        (ok (eq :base-url (enchiridion.errors::configuration-key condition)))))
    (let ((provider (enchiridion.llm:resolve-provider
                     '(:llm (:provider :custom)
                       (:base-url "https://proxy.test/v1/")
                       (:api-key-env "PROXY_KEY")
                       (:model-primary "custom-model"))
                     :api-key "k")))
      (ok (eq :custom (enchiridion.llm:provider-id provider)))
      (ok (eq :config (enchiridion.llm:provider-source provider)))
      (ok (string= "https://proxy.test/v1/" (enchiridion.llm:provider-base-url provider)))
      (ok (string= "custom-model" (enchiridion.llm:provider-model provider)))
      (ok (eq :openai-chat (enchiridion.llm:provider-api provider)))
      (ok (eq :openai (enchiridion.llm:provider-profile provider))))
    (testing "the wire follows :backend"
      (let ((provider (enchiridion.llm:resolve-provider
                       '(:llm (:provider :custom) (:backend :anthropic)
                         (:base-url "https://proxy.test/v1/")))))
        (ok (eq :anthropic-messages (enchiridion.llm:provider-api provider)))
        (ok (eq :anthropic (enchiridion.llm:provider-profile provider)))))))

;;;; Detection.

(deftest detection-order-is-the-documented-one ()
  (with-shipped-providers
   (with-empty-catalog
    (enchiridion.llm.secrets:clear-secrets)
    (unwind-protect
         (progn
           (testing "nothing at all is OpenAI"
             (ok (eq :openai (enchiridion.llm:detect-provider '()))))
           (testing "an explicit :provider wins over a key"
             (enchiridion.llm.secrets:register-secret "OPENAI_API_KEY" "fake-key-1234567890")
             (ok (eq :opencode (enchiridion.llm:detect-provider '(:llm (:provider :opencode)))))
             (enchiridion.llm.secrets:clear-secrets))
           (testing "a recognized host wins over the keys"
             (enchiridion.llm.secrets:register-secret "ANTHROPIC_API_KEY" "fake-key-1234567890")
             (ok (eq :anthropic
                     (enchiridion.llm:detect-provider
                      '(:llm (:base-url "https://api.anthropic.com/")))))
             (ok (eq :anthropic (enchiridion.llm:detect-provider '())))
             (enchiridion.llm.secrets:clear-secrets))
           (testing "OpenAI wins a tie"
             (enchiridion.llm.secrets:register-secret "OPENCODE_API_KEY" "fake-key-1234567890")
             (enchiridion.llm.secrets:register-secret "OPENAI_API_KEY" "fake-key-1234567890")
             (ok (eq :openai (enchiridion.llm:detect-provider '())))))
      (enchiridion.llm.secrets:clear-secrets)))))

(deftest a-catalog-host-and-a-lone-catalog-key-are-detected ()
  (with-shipped-providers
   (with-fixture-catalog
    (enchiridion.llm.secrets:clear-secrets)
    (unwind-protect
         (progn
           (testing "a catalog endpoint's host selects its provider"
             (testing "and the first id wins when two share a host"
               (ok (eq :host-two
                       (enchiridion.llm:detect-provider
                        '(:llm (:base-url "https://zhost.example/v1/")))))))
           (testing "the shipped hosts still win over the catalog's"
             (ok (eq :openai
                     (enchiridion.llm:detect-provider
                      '(:llm (:base-url "https://api.openai.com/v1/"))))))
           (testing "the one catalog provider whose key is present is selected"
             (enchiridion.llm.secrets:register-secret "GROQ_API_KEY" "fake-key-1234567890")
             (ok (eq :groq (enchiridion.llm:detect-provider '()))))
           (testing "two catalog keys are not a choice"
             (enchiridion.llm.secrets:register-secret "FIXTURE_API_KEY" "fake-key-1234567890")
             (ok (eq :openai (enchiridion.llm:detect-provider '())))))
      (enchiridion.llm.secrets:clear-secrets)))))

;;;; Key names.

(deftest with-no-catalog-the-key-names-are-exactly-the-three ()
  (with-shipped-providers
   (with-empty-catalog
    (let ((enchiridion:*config* nil))
      (ok (equal '("OPENAI_API_KEY" "OPENCODE_API_KEY" "ANTHROPIC_API_KEY")
                 (enchiridion.llm:provider-key-names '())))))))

(deftest a-cached-catalog-adds-only-credential-shaped-supported-names ()
  (with-fixture-catalog
    (let ((enchiridion:*config* nil))
      (let ((names (enchiridion.llm:provider-key-names '())))
        (ok (member "FIXTURE_API_KEY" names :test #'string=))
        (ok (member "GROQ_API_KEY" names :test #'string=))
        (testing "a provider this build cannot serve names no key variable"
          (ng (member "COHERE_API_KEY" names :test #'string=))
          (ng (member "GOOGLE_API_KEY" names :test #'string=)))
        (testing "a variable that is not credential-shaped is not a key"
          (ng (member "FIXTURE_BASE_URL" names :test #'string=)))
        (testing "and no name is repeated"
          (ok (= (length names) (length (remove-duplicates names :test #'string=)))))))))

(deftest the-selected-provider-names-its-own-key-variable ()
  (with-shipped-providers
   (with-empty-catalog
    (let ((enchiridion:*config* nil))
      (testing "the shipped rows still answer first"
        (ok (string= "OPENAI_API_KEY" (enchiridion.llm:default-api-key-env '()))))
      (testing "an explicit name wins"
        (ok (string= "MY_KEY"
                     (enchiridion.llm:default-api-key-env
                      '(:llm (:api-key-env "MY_KEY"))))))
      (testing "and :backend :anthropic names the Anthropic variable"
        (ok (string= "ANTHROPIC_API_KEY"
                     (enchiridion.llm:default-api-key-env
                      '(:llm (:backend :anthropic))))))))))

;;;; The model list.

(deftest provider-models-caches-the-live-list-and-joins-the-catalog ()
  (with-scratch-directory (scratch)
    (with-empty-catalog
      (let* ((calls (list 0))
             (metadata (make-hash-table :test #'equal))
             (enchiridion.llm::*model-cache-directory* scratch)
             (enchiridion.llm::*catalog-models* metadata)
             (enchiridion.llm::*http-get-function*
               (stub-get "{\"data\":[{\"id\":\"m-1\"},{\"id\":\"m-2\",\"name\":\"M Two\"}]}"
                         calls))
             (provider (enchiridion.llm:resolve-provider
                        '(:llm (:provider :openai) (:models-ttl-seconds 3600))
                        :api-key "k")))
        (setf (gethash "openai" metadata)
              (list (enchiridion.llm::%make-model-info
                     :id "m-1" :name "M One" :tool-call-p t
                     :context 128000 :output 8192 :cost-input 1.5 :cost-output 6.0
                     :source :catalog)))
        (let ((models (enchiridion.llm:provider-models provider)))
          (ok (equal '("m-1" "m-2") (model-ids models)))
          (ok (= 1 (car calls)))
          (testing "the cost and limit metadata is joined by model id"
            (let ((one (find "m-1" models :key #'enchiridion.llm:model-info-id
                                   :test #'string=)))
              (ok (eql 128000 (enchiridion.llm:model-info-context one)))
              (ok (= 1.5 (enchiridion.llm:model-info-cost-input one)))))
          (testing "the model the catalog does not know keeps what the endpoint said"
            (let ((two (find "m-2" models :key #'enchiridion.llm:model-info-id
                                   :test #'string=)))
              (ok (string= "M Two" (enchiridion.llm:model-info-name two)))
              (ok (null (enchiridion.llm:model-info-context two))))))
        (testing "the cache is on disk"
          (ok (probe-file (merge-pathnames "openai.json" scratch))))
        (testing "a second call inside the TTL answers from the cache"
          (let ((enchiridion.llm::*http-get-function* (failing-get)))
            (ok (equal '("m-1" "m-2")
                       (model-ids (enchiridion.llm:provider-models provider))))))
        (testing ":refresh asks again, and a failure is a warning and the old list"
          (let ((enchiridion.llm::*http-get-function* (failing-get)))
            (ok (equal '("m-1" "m-2")
                       (model-ids (enchiridion.llm:provider-models provider
                                                                   :refresh t))))))))))

(deftest an-empty-or-failing-model-list-is-not-fatal ()
  (with-scratch-directory (scratch)
    (with-empty-catalog
      (let* ((metadata (make-hash-table :test #'equal))
             (enchiridion.llm::*model-cache-directory* scratch)
             (enchiridion.llm::*catalog-models* metadata)
             (provider (enchiridion.llm:resolve-provider '(:llm (:provider :openai))
                                                         :api-key "k")))
        (setf (gethash "openai" metadata)
              (list (enchiridion.llm::%make-model-info :id "catalog-1"
                                                       :name "Catalog One"
                                                       :source :catalog)))
        (testing "an endpoint that offers nothing falls back to the catalog"
          (let ((enchiridion.llm::*http-get-function* (stub-get "{\"data\":[]}")))
            (ok (equal '("catalog-1")
                       (model-ids (enchiridion.llm:provider-models provider))))))
        (testing "an endpoint that fails answers the fallback rather than signalling"
          (let ((enchiridion.llm::*http-get-function* (failing-get)))
            (ok (equal '("catalog-1")
                       (model-ids (enchiridion.llm:provider-models provider
                                                                   :refresh t))))))
        (testing "and with no catalog either it answers nothing once the cache is gone"
          (clrhash metadata)
          (ignore-errors (delete-file (merge-pathnames "openai.json" scratch)))
          (let ((enchiridion.llm::*http-get-function* (failing-get)))
            (ok (null (enchiridion.llm:provider-models provider :refresh t)))))))))

;;;; The listing.

(deftest list-providers-has-the-shape-the-command-prints ()
  (with-fixture-catalog
    (let* ((config '(:llm (:providers ((:id :opencode
                                       :api-key-env "MY_OPENCODE_KEY")))))
           (rows (enchiridion.llm:list-providers :config config)))
      (ok (every (lambda (row) (getf row :id)) rows))
      (testing "sorted by the printed id"
        (ok (equal (mapcar (lambda (row) (string (getf row :id))) rows)
                   (sort (mapcar (lambda (row) (string (getf row :id))) rows)
                         #'string<))))
      (testing "a configured row appears once, as :config, and keeps its key name"
        (let ((matched (remove-if-not (lambda (row) (eq :opencode (getf row :id)))
                                      rows)))
          (ok (= 1 (length matched)))
          (ok (eq :config (getf (first matched) :source)))
          (ok (string= "MY_OPENCODE_KEY" (getf (first matched) :api-key-env)))))
      (testing "a catalog-only provider is listed with its adapter"
        (let ((groq (find :groq rows :key (lambda (row) (getf row :id)))))
          (ok groq)
          (ok (eq :openai-chat (getf groq :api)))
          (ok (eq :catalog (getf groq :source)))
          (ok (getf groq :supported-p))))
      (testing "an unsupported provider is listed and marked unsupported"
        (let ((cohere (find :cohere rows :key (lambda (row) (getf row :id)))))
          (ok cohere)
          (ng (getf cohere :supported-p)))))))

;;;; :offline, and the marker the listing prints.

(deftest provider-models-honours-offline ()
  ;; :OFFLINE stops the model list as well as the catalog. `providers models'
  ;; is the documented exception because the operator asked for one request by
  ;; hand, and it says so with FORCE; the start-up path does not force, so it
  ;; opens nothing on a machine that asked for no network.
  (with-scratch-directory (scratch)
    (with-empty-catalog
      (let* ((calls (list 0))
             (enchiridion.llm::*model-cache-directory* scratch)
             (enchiridion.llm::*http-get-function*
               (stub-get "{\"data\":[{\"id\":\"m-1\"}]}" calls))
             (provider (enchiridion.llm:resolve-provider
                        '(:llm (:provider :openai)) :api-key "k")))
        (let ((enchiridion:*config* '(:llm (:offline t))))
          (testing "an offline process asks the endpoint nothing"
            (enchiridion.llm:provider-models provider)
            (ok (= 0 (car calls))))
          (testing "and the explicit command is still allowed one request"
            (enchiridion.llm:provider-models provider :force t)
            (ok (= 1 (car calls)))))))))

(deftest an-unknown-handler-is-marked-unsupported-in-the-listing ()
  ;; The marker follows the handler this build actually has, not whether the
  ;; row named one. A typo in :api used to print as though it were served.
  (with-empty-catalog
    (let* ((enchiridion:*config*
             '(:llm (:providers ((:id :bogus :api :not-a-real-handler
                                 :base-url "https://bogus.example/v1")))))
           (rows (enchiridion.llm:list-providers :config enchiridion:*config*))
           (row (find "bogus" rows :key (lambda (r) (string-downcase (string (getf r :id))))
                            :test #'string=)))
      (ok (not (null row)))
      (ok (eq :not-a-real-handler (getf row :api)))
      (ng (getf row :supported-p)))))
