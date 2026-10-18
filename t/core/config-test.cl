;;;; config-test.cl --- Reading the operator configuration.
;;;;
;;;; config.example.cl writes sections, not a property list. The two shapes
;;;; are both accepted, and the reader has to tell them apart without a flag.

(defpackage #:enchiridion-config-test
  (:use #:cl)
  (:import-from #:rove #:deftest #:ok #:testing)
  (:export #:run))

(in-package #:enchiridion-config-test)

(deftest a-sectioned-config-is-read ()
  (let ((config '(:llm
                  (:backend :openai)
                  (:base-url "https://example.test/v1")
                  (:model-primary "section-model"))))
    (ok (eq :openai (enchiridion:config-value config :backend)))
    (ok (string= "https://example.test/v1"
                 (enchiridion:config-value config :base-url)))
    (ok (string= "section-model"
                 (enchiridion:config-value config :model-primary)))
    (testing "a key that is absent is the default"
      (ok (null (enchiridion:config-value config :missing)))
      (ok (eq :fallback (enchiridion:config-value config :missing :fallback))))))

(deftest a-flat-config-is-read ()
  ;; The first adapter only understood this shape, and a one-line test config
  ;; is still easier to write this way.
  (let ((config '(:backend :openai
                  :base-url "https://flat.test/v1"
                  :model-primary "flat-model")))
    (ok (eq :openai (enchiridion:config-value config :backend)))
    (ok (string= "flat-model" (enchiridion:config-value config :model-primary)))))

(deftest a-section-stops-at-the-next-section ()
  (let* ((config '(:llm (:backend :openai) (:model-primary "m")
                   :channels (:cli (:enabled t))))
         (llm (enchiridion:config-section config :llm)))
    (ok (= 2 (length llm)))
    (ok (eq :backend (first (first llm))))
    (testing "and the next section is not part of it"
      (ok (null (assoc :channels llm))))))

(deftest the-memory-store-path-is-read-from-its-own-section ()
  (let ((config '(:llm (:backend :openai)
                  :memory (:db "/var/lib/enchiridion/memory.db"))))
    (ok (string= "/var/lib/enchiridion/memory.db"
                 (enchiridion:config-memory-db config))))
  (testing "a config with no memory section is not an error"
    (ok (null (enchiridion:config-memory-db '(:backend :openai)))))
  (testing "and a memory section that names no db keeps the default file"
    (ok (null (enchiridion:config-memory-db
               '(:llm (:backend :openai)
                 :memory (:block-limits (:persona 10))))))))

(deftest a-section-outside-llm-is-read-by-name ()
  (let ((config '(:llm (:backend :openai)
                  :budget (:max-tokens-per-tick 4000) (:max-tokens-per-day 100)
                  :sleep (:enabled nil) (:interval-seconds 60))))
    (testing "the budget section answers"
      (ok (eql 4000 (enchiridion:config-section-value config :budget :max-tokens-per-tick)))
      (ok (eql 100 (enchiridion:config-section-value config :budget :max-tokens-per-day))))
    (testing "the sleep section answers"
      (ok (eql 60 (enchiridion:config-section-value config :sleep :interval-seconds)))
      (testing "and an explicit NIL is a value, not a missing key"
        (ok (null (enchiridion:config-section-value config :sleep :enabled :on)))))
    (testing "an absent key is the caller's default"
      (ok (null (enchiridion:config-section-value config :sleep :missing)))
      (ok (eq :fallback (enchiridion:config-section-value config :sleep :missing :fallback))))
    (testing "another section's key is not invented from the :LLM section"
      (ok (eq :fallback
              (enchiridion:config-section-value config :sleep :backend :fallback))))))

(deftest a-flat-config-has-no-section-to-read ()
  (let ((config '(:backend :openai :max-tokens-per-tick 4000)))
    (testing "the flat shape answers with the default rather than guessing"
      (ok (eq :fallback
              (enchiridion:config-section-value config :budget :max-tokens-per-tick
                                                :fallback))))))

(deftest a-channel-entry-inherits-what-it-does-not-name ()
  (let ((config '(:llm (:backend :openai)
                  :channels (:http (:enabled t) (:port 9999)))))
    (let ((enchiridion:*config* config))
      (testing "the operator's key wins"
        (ok (eql 9999 (enchiridion:channel-value :http :port)))
        (ok (eq t (enchiridion:channel-value :http :enabled))))
      (testing "a key the entry does not mention comes from the shipped entry"
        (ok (string= "127.0.0.1" (enchiridion:channel-value :http :bind)))
        (ok (null (enchiridion:channel-value :http :token))))
      (testing "a channel the config does not mention is the shipped entry"
        (ok (null (enchiridion:channel-value :fluxer :enabled)))
        (ok (string= "FLUXER_BOT_TOKEN" (enchiridion:channel-value :fluxer :token-env))))
      (testing "an unknown key is the caller's default"
        (ok (eq :fallback (enchiridion:channel-value :http :missing :fallback))))
      (testing "a string names the same channel as a keyword"
        (ok (eql 9999 (enchiridion:channel-value "http" :port))))
      (testing "the shipped entry carries every option, not only the first"
        (let ((http (enchiridion:channel-config :http (enchiridion:default-config))))
          (ok (eql 8787 (getf http :port)))
          (ok (string= "127.0.0.1" (getf http :bind)))
          (ok (null (getf http :enabled))))))))
