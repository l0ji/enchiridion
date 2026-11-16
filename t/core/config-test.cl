;;;; config-test.cl --- Reading the operator configuration.
;;;;
;;;; config.example.cl writes sections, not a property list. The two shapes
;;;; are both accepted, and the reader has to tell them apart without a flag.

(defpackage #:enchiridion-config-test
  (:use #:cl)
  (:import-from #:rove #:deftest #:ok #:testing #:signals)
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

(deftest every-credential-name-the-config-mentions-is-collected ()
  (testing "the shipped names, so an unconfigured harness still loads them"
    ;; The shipped config names no LLM key variable: the provider table in the
    ;; LLM module decides that name, and main.cl unions provider-key-names in
    ;; before it loads anything. The two channel tokens are still shipped here,
    ;; because no provider table can supply them, and so is the dense
    ;; retrieval key, which the embedder reads whenever :embed is turned on.
    (ok (equal '("FLUXER_BOT_TOKEN" "ENCHIRIDION_HTTP_TOKEN" "OPENAI_API_KEY")
               (enchiridion:configured-secret-names (enchiridion:default-config)))))
  (testing "a configured name wins and the channels are still read"
    (let ((config '(:llm (:api-key-env "MY_LLM_KEY")
                    :channels (:http (:enabled t) (:token-env "MY_WEBHOOK_TOKEN"))
                               (:fluxer (:enabled t) (:token-env "MY_FLUXER_TOKEN")))))
      (ok (equal '("MY_LLM_KEY" "MY_FLUXER_TOKEN" "MY_WEBHOOK_TOKEN" "OPENAI_API_KEY")
                 (enchiridion:configured-secret-names config)))))
  (testing "an empty name is skipped rather than turned back into a default"
    ;; The operator wrote the empty string, so it wins over the shipped name
    ;; the way every other explicit value does; there is simply nothing to
    ;; read. FLUXER_BOT_TOKEN is still collected because :fluxer was not
    ;; configured at all.
    (ok (equal '("FLUXER_BOT_TOKEN" "OPENAI_API_KEY")
               (enchiridion:configured-secret-names
                '(:llm (:api-key-env "")
                  :channels (:http (:enabled t) (:token-env "")))))))
  (testing "the dense retrieval key is a configured secret too"
    (ok (member "MY_EMBED_KEY"
                (enchiridion:configured-secret-names
                 '(:memory (:embed t) (:embed-key-env "MY_EMBED_KEY")))
                :test #'string=)))
  (testing "a name repeated in two places is collected once"
    (let ((config '(:llm (:api-key-env "SAME_NAME")
                    :channels (:http (:enabled t) (:token-env "SAME_NAME")))))
      (ok (equal '("SAME_NAME" "FLUXER_BOT_TOKEN" "OPENAI_API_KEY")
                 (enchiridion:configured-secret-names config))))))

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

(deftest a-setting-falls-back-to-the-shipped-default ()
  ;; A reader with its own fallback is how a setting comes to be hardcoded:
  ;; config.cl leaves the key out and the reader's copy wins.
  (let ((config '(:llm (:backend :openai)
                  :budget (:max-tokens-per-tick 10))))
    (testing "the operator's value wins"
      (ok (eql 10 (enchiridion:config-setting config :budget :max-tokens-per-tick))))
    (testing "a key the operator left out is the shipped one, not no value"
      (ok (eql (enchiridion:config-section-value (enchiridion:default-config)
                                                 :budget :max-tokens-per-day)
               (enchiridion:config-setting config :budget :max-tokens-per-day))))
    (testing "a flat config answers with the shipped default"
      (ok (eql (enchiridion:config-section-value (enchiridion:default-config)
                                                 :sleep :interval-seconds)
               (enchiridion:config-setting '(:backend :openai)
                                           :sleep :interval-seconds))))
    (testing "an explicit NIL is a value, not a missing key"
      (ok (null (enchiridion:config-setting '(:llm (:backend :openai)
                                              :sleep (:enabled nil))
                                            :sleep :enabled))))
    (testing "a key with no shipped default signals"
      (ok (signals (enchiridion:config-setting config :budget :not-a-setting))))))

(deftest one-llm-option-can-be-overridden-in-a-copy ()
  (let* ((config '(:llm (:max-tokens 4096) (:model-cheap "m") :memory (:enabled t)))
         (copy (enchiridion:config-with-llm-value config :max-tokens 16384)))
    (ok (= 16384 (enchiridion:config-value copy :max-tokens)))
    (ok (equal "m" (enchiridion:config-value copy :model-cheap)))
    (ok (enchiridion:config-section-value copy :memory :enabled))
    (testing "the original is untouched"
      (ok (= 4096 (enchiridion:config-value config :max-tokens)))))
  (testing "a config with no :llm section, and a flat one"
    (ok (= 9 (enchiridion:config-value
              (enchiridion:config-with-llm-value '(:memory (:enabled t)) :max-tokens 9)
              :max-tokens)))
    (ok (= 9 (enchiridion:config-value
              (enchiridion:config-with-llm-value '(:max-tokens 1) :max-tokens 9)
              :max-tokens)))))


(defmacro with-environment ((name value) &body body)
  "Run BODY with environment variable NAME set to VALUE, then restore it."
  (let ((previous (gensym "PREVIOUS")))
    `(let ((,previous (uiop:getenv ,name)))
       (unwind-protect
            (progn
              (if ,value
                  (enchiridion.compat:set-environment-variable ,name ,value)
                  (enchiridion.compat:unset-environment-variable ,name))
              ,@body)
         (if ,previous
             (enchiridion.compat:set-environment-variable ,name ,previous)
             (enchiridion.compat:unset-environment-variable ,name))))))

(defmacro with-process-uid ((uid) &body body)
  "Run BODY with PROCESS-UID returning UID, then restore the real function."
  (let ((original (gensym "ORIGINAL")))
    `(let ((,original (symbol-function 'enchiridion.compat:process-uid)))
       (unwind-protect
            (progn
              (setf (symbol-function 'enchiridion.compat:process-uid)
                    (lambda () ,uid))
              ,@body)
         (setf (symbol-function 'enchiridion.compat:process-uid) ,original)))))

(defmacro with-config-scratch ((directory) &body body)
  "Run BODY in a fresh DIRECTORY containing trusted and untrusted configs."
  `(let ((,directory (uiop:ensure-directory-pathname
                      (merge-pathnames
                       (format nil "enchiridion-config-test-~D/"
                               (random most-positive-fixnum))
                       *default-pathname-defaults*))))
     (unwind-protect
          (progn
            (dolist (name '("cwd/nested/" "source/"))
              (let ((parent (merge-pathnames name ,directory)))
                (ensure-directories-exist parent)
                (with-open-file (stream (merge-pathnames "config.cl" parent)
                                        :direction :output :if-exists :supersede)
                  (write-string "(list :backend :openai)" stream))))
            (with-open-file (stream (merge-pathnames "enchiridion.asd" ,directory)
                                    :direction :output :if-exists :supersede)
              (write-string "" stream))
             (with-environment ("ENCHIRIDION_CONFIG" nil)
               ,@body))
       (uiop:delete-directory-tree ,directory :validate t
                                              :if-does-not-exist :ignore))))

(defmacro with-root-config-metadata ((&rest overrides) &body body)
  "Run BODY with root-owned metadata, except for OVERRIDES."
  `(let ((original (symbol-function 'sb-posix:stat)))
     (unwind-protect
          (progn
            (setf (symbol-function 'sb-posix:stat)
                  (lambda (path &optional stat)
                    (let* ((info (if stat (funcall original path stat)
                                     (funcall original path)))
                           (override (assoc path (list ,@overrides) :test #'equal)))
                      (setf (slot-value info 'sb-posix::uid)
                            (if override (second override) 0)
                            (slot-value info 'sb-posix::mode)
                            (if override (third override) #o755))
                      info)))
            ,@body)
       (setf (symbol-function 'sb-posix:stat) original))))

(deftest a-nonroot-installed-run-keeps-working-directory-config-resolution ()
  (with-config-scratch (scratch)
    (let ((cwd (merge-pathnames "cwd/nested/" scratch))
          (source (merge-pathnames "source/" scratch)))
      (uiop:with-current-directory (cwd)
        (with-environment ("ENCHIRIDION_SOURCE" (namestring source))
          (with-process-uid (1000)
            (ok (uiop:pathname-equal
                 (merge-pathnames "config.cl" cwd)
                 (enchiridion::config-path)))))
        (testing "root trusts only the installed source"
          (with-environment ("ENCHIRIDION_SOURCE" (namestring source))
            (with-process-uid (0)
              (with-root-config-metadata ()
                (ok (uiop:pathname-equal
                     (merge-pathnames "config.cl" source)
                     (enchiridion::config-path)))))))))))

(deftest root-without-an-installed-source-does-not-read-the-working-directory ()
  (with-config-scratch (scratch)
    (uiop:with-current-directory ((merge-pathnames "cwd/nested/" scratch))
      (with-environment ("ENCHIRIDION_SOURCE" nil)
        (with-process-uid (0)
          (ok (null (enchiridion::config-path))))))))

(deftest an-unprivileged-checkout-keeps-current-directory-config-resolution ()
  (with-config-scratch (scratch)
    (let ((cwd (merge-pathnames "cwd/nested/" scratch)))
      (uiop:with-current-directory (cwd)
        (with-environment ("ENCHIRIDION_SOURCE" nil)
          (with-process-uid (1000)
            (ok (uiop:pathname-equal
                 (merge-pathnames "config.cl" cwd)
                 (enchiridion::config-path)))))))))

(deftest recent-message-window-defaults-are-bounded ()
  (let ((config (enchiridion:default-config)))
    (ok (eql 6 (enchiridion:config-setting config :memory :recent-turns)))
    (ok (eql 4000 (enchiridion:config-setting config :memory :recent-window-chars)))))

(deftest an-explicit-config-path-wins-without-fallback ()
  (with-config-scratch (scratch)
    (let ((explicit (merge-pathnames "source/config.cl" scratch)))
      (uiop:with-current-directory ((merge-pathnames "cwd/nested/" scratch))
        (with-environment ("ENCHIRIDION_CONFIG" (namestring explicit))
          (dolist (uid '(0 1000))
            (with-process-uid (uid)
              (with-root-config-metadata ()
                (ok (equal explicit (enchiridion::config-path)))))))
        (with-environment ("ENCHIRIDION_CONFIG"
                           (namestring (merge-pathnames "absent.cl" scratch)))
          (ok (null (enchiridion::config-path))))))))

(deftest root-config-checks-file-and-both-symlink-ancestries ()
  (with-config-scratch (scratch)
    (let* ((path (merge-pathnames "source/config.cl" scratch))
           (link (merge-pathnames "cwd/config.cl" scratch)))
      (sb-posix:symlink (namestring path) (namestring link))
      (with-root-config-metadata ()
        (ok (equal (truename path) (enchiridion::check-root-config-path path)))
        (ok (equal (truename path) (enchiridion::check-root-config-path link))))
      (dolist (entry (list path (merge-pathnames "source/" scratch)
                          (merge-pathnames "cwd/" scratch)))
        (let ((candidate (if (equal entry path) path link)))
          (testing "an agent-owned file or parent is refused"
            (with-root-config-metadata ((list (namestring entry) 1000 #o755))
              (ok (signals (enchiridion::check-root-config-path candidate)
                           'enchiridion.errors:configuration-error))))
          (testing "a writable file or parent is refused"
            (with-root-config-metadata ((list (namestring entry) 0 #o777))
              (ok (signals (enchiridion::check-root-config-path candidate)
                           'enchiridion.errors:configuration-error))))))
      (with-root-config-metadata ()
        (ok (signals (enchiridion::check-root-config-path #p"config.cl")
                     'enchiridion.errors:configuration-error))))))

(deftest root-config-loading-does-not-execute-a-working-directory-shadow ()
  (with-config-scratch (scratch)
    (let ((source (merge-pathnames "source/" scratch))
          (cwd (merge-pathnames "cwd/nested/" scratch)))
      (with-open-file (stream (merge-pathnames "config.cl" cwd)
                              :direction :output :if-exists :supersede)
        (write-string "(error \"Working directory shadow executed.\")" stream))
      (with-open-file (stream (merge-pathnames "config.cl" source)
                              :direction :output :if-exists :supersede)
        (write-string "(setf enchiridion.user::*enchiridion-config* '(:model-primary \"trusted\"))" stream))
      (uiop:with-current-directory (cwd)
        (with-environment ("ENCHIRIDION_SOURCE" (namestring source))
          (with-process-uid (0)
            (with-root-config-metadata ()
              (let ((enchiridion:*config* nil)
                    (enchiridion:*config-source* nil))
                (progv '(enchiridion.user::*enchiridion-config*) '(nil)
                  (ok (equal "trusted"
                             (enchiridion:config-value
                              (enchiridion:read-config) :model-primary))))))))))))
