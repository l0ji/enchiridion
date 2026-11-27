;;;; log-test.lsp --- Shared logger level filtering, stdout output, scrubbing, and configuration.

(defpackage #:enchiridion-log-test
  (:use #:cl)
  (:import-from #:rove #:deftest #:ok #:testing)
  (:export #:run))

(in-package #:enchiridion-log-test)

(deftest log-level-parsing-accepts-keywords-and-strings ()
  (ok (eq :debug (enchiridion.log:parse-log-level :debug)))
  (ok (eq :info (enchiridion.log:parse-log-level "INFO")))
  (ok (eq :warn (enchiridion.log:parse-log-level "warning")))
  (ok (eq :error (enchiridion.log:parse-log-level " error ")))
  (ok (eq :off (enchiridion.log:parse-log-level "quiet")))
  (ok (eq :info (enchiridion.log:parse-log-level "nonsense" :info)))
  (ok (eq :warn (enchiridion.log:parse-log-level nil))))

(deftest log-defaults-to-standard-output ()
  (let ((output (with-output-to-string (*standard-output*)
                  (let ((enchiridion.log:*log-level* :info)
                        (enchiridion.log:*log-stream* nil))
                    (enchiridion.log:log-info :test "hello docker")))))
    (ok (search "INFO  [test] hello docker" output))))

(deftest log-levels-filter-output ()
  (let ((stream (make-string-output-stream)))
    (let ((enchiridion.log:*log-level* :warn)
          (enchiridion.log:*log-stream* stream))
      (enchiridion.log:log-debug :test "hidden debug")
      (enchiridion.log:log-info :test "hidden info")
      (enchiridion.log:log-warn :test "visible warn ~D" 42)
      (enchiridion.log:log-error :test "visible error"))
    (let ((text (get-output-stream-string stream)))
      (ok (null (search "hidden debug" text)))
      (ok (null (search "hidden info" text)))
      (ok (search "WARN  [test] visible warn 42" text))
      (ok (search "ERROR [test] visible error" text)))))

(deftest log-off-suppresses-everything ()
  (let ((stream (make-string-output-stream)))
    (let ((enchiridion.log:*log-level* :off)
          (enchiridion.log:*log-stream* stream))
      (enchiridion.log:log-error :test "should not appear"))
    (ok (string= "" (get-output-stream-string stream)))))

(deftest log-flattens-newlines-and-scrubs-secrets ()
  (let ((stream (make-string-output-stream))
        (secret "sk-super-secret-log-token-1234567890"))
    (enchiridion.llm.secrets:register-secret "TEST_LOG_SECRET" secret :env)
    (unwind-protect
         (let ((enchiridion.log:*log-level* :info)
               (enchiridion.log:*log-stream* stream))
           (enchiridion.log:log-info :test "line1~%line2~Ctoken=~A" #\Tab secret))
      (enchiridion.llm.secrets:clear-secrets))
    (let ((text (get-output-stream-string stream)))
      (ok (search "line1 line2 " text))
      (ok (null (search secret text)))
      (ok (search enchiridion.llm.secrets:+redaction-marker+ text))
      ;; Exactly one trailing newline.
      (ok (= 1 (count #\Newline text))))))

(deftest configure-logging-reads-config-and-defaults ()
  (let ((enchiridion.log:*log-level* :warn)
        (saved-level (uiop:getenv "ENCHIRIDION_LOG_LEVEL")))
    (unwind-protect
         (progn
           (enchiridion.compat:unset-environment-variable "ENCHIRIDION_LOG_LEVEL")
           (testing "default level applies when config omits :logging"
             (ok (eq :info (enchiridion.log:configure-logging
                            :config (enchiridion:default-config) :default-level :info)))
             (ok (eq :info enchiridion.log:*log-level*)))
           (testing ":logging section overrides default level"
             (ok (eq :debug (enchiridion.log:configure-logging
                             :config '(:llm (:provider :openai)
                                       :logging (:level :debug))
                             :default-level :warn)))
             (ok (eq :debug enchiridion.log:*log-level*)))
           (testing "environment variable overrides config"
             (enchiridion.compat:set-environment-variable "ENCHIRIDION_LOG_LEVEL" "error")
             (ok (eq :error (enchiridion.log:configure-logging
                             :config '(:llm (:provider :openai)
                                       :logging (:level :debug))
                             :default-level :info)))))
      (if saved-level
          (enchiridion.compat:set-environment-variable "ENCHIRIDION_LOG_LEVEL" saved-level)
          (enchiridion.compat:unset-environment-variable "ENCHIRIDION_LOG_LEVEL")))))
