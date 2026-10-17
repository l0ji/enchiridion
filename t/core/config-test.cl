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
