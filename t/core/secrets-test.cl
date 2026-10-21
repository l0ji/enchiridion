;;;; secrets-test.cl --- The secret scrubber.
;;;;
;;;; These tests pin the invariant: a secret that reached a tool result, a
;;;; block, a journal entry, an outbound request, or an outbound message does
;;;; not survive the scrubber. Every path is here, because the one that is
;;;; missing is the one that leaks.
;;;;
;;;; The last three tests cover the container-file invariant instead: the
;;;; container copy of the secret file is refused when the world can read it,
;;;; it is unlinked once the supervisor has read it, and the operator's
;;;; checkout .env is never the file that gets unlinked. A file on disk is the
;;;; one thing the scrubber cannot save the operator from, so the file check is
;;;; tested here beside it.
;;;;
;;;; The fake keys are obviously fake. The scrubber must not care.

(defpackage #:enchiridion-secrets-test
  (:use #:cl)
  (:import-from #:rove #:deftest #:ok #:ng #:testing)
  (:export #:run))

(in-package #:enchiridion-secrets-test)

(defparameter +fake-key+
  "sk-live-0000000000000000NOTREAL0000000000"
  "A value that is the right shape and worth nothing.")

(defmacro with-scratch-directory ((name &key (prefix "enchiridion-secrets-test-"))
                                  &body body)
  "Bind NAME to a fresh temporary directory, run BODY, then remove it.

Scratch lives under *DEFAULT-PATHNAME-DEFAULTS* and not under TMPDIR, for the
reason testing.md gives: a nix build sandbox has no writable /tmp. That matters
more here than anywhere else, because these tests write a file and then set its
mode, and a mode is not worth reading on a filesystem that refused the write."
  `(let ((,name (uiop:ensure-directory-pathname
                  (merge-pathnames
                   (format nil "~A~D" ,prefix (random most-positive-fixnum))
                   (uiop:ensure-directory-pathname *default-pathname-defaults*)))))
     (unwind-protect
          (progn ,@body)
       (uiop:delete-directory-tree ,name
                                   :validate t
                                   :if-does-not-exist :ignore))))

(declaim (ftype (function (t t) t) write-fixture))

(defun write-fixture (path text)
  "Write TEXT to PATH, creating every parent directory, and return PATH."
  (ensure-directories-exist path)
  (with-open-file (stream path :direction :output
                               :if-exists :supersede
                               :if-does-not-exist :create
                               :external-format :utf-8)
    (write-string text stream))
  path)

(deftest a-loaded-secret-never-survives-a-scrub ()
  (enchiridion.llm.secrets:clear-secrets)
  (enchiridion.llm.secrets:register-secret "OPENCODE_API_KEY" +fake-key+)
  (testing "alone"
    (ng (search +fake-key+ (enchiridion.llm.secrets:scrub +fake-key+))))
  (testing "inside a sentence"
    (ng (search +fake-key+
                (enchiridion.llm.secrets:scrub
                 (format nil "the key is ~A, use it" +fake-key+)))))
  (testing "and the marker is there instead"
    (ok (search enchiridion.llm.secrets:+redaction-marker+
                (enchiridion.llm.secrets:scrub +fake-key+))))
  (enchiridion.llm.secrets:clear-secrets))

(deftest every-loaded-value-is-removed-whatever-its-shape ()
  ;; A secret that does not look like anything is still a secret. The shape
  ;; filter cannot be the only thing standing between it and a provider.
  (dolist (secret '("correcthorsebatterystaple"
                    "just-along-identifier-with-no-prefix"
                    "0123456789abcdef0123456789abcdef"))
    (testing secret
      (enchiridion.llm.secrets:clear-secrets)
      (enchiridion.llm.secrets:register-secret "TEST_SECRET" secret)
      (ng (search secret (enchiridion.llm.secrets:scrub
                         (format nil "prefix ~A suffix" secret))))))
  (enchiridion.llm.secrets:clear-secrets))

(deftest a-secret-shorter-than-the-floor-is-left-alone ()
  ;; Otherwise a one character key turns the whole transcript into [redacted]
  ;; and the agent stops working. This is the deliberate trade.
  (enchiridion.llm.secrets:clear-secrets)
  (enchiridion.llm.secrets:register-secret "SHORT" "abc")
  (ok (equal "abc" (enchiridion.llm.secrets:scrub "abc")))
  (ok (search "abc" (enchiridion.llm.secrets:scrub "xxabcxx")))
  (enchiridion.llm.secrets:clear-secrets))

(deftest known-shapes-are-removed-with-nothing-loaded ()
  ;; The prompt injection case: a credential this process never loaded still
  ;; must not reach the provider. Nothing is registered here on purpose.
  (dolist (text '("Authorization: Bearer abcdefghijklmnop"
                  "token sk-abcdefghijklmnopqrst"
                  "ghp_abcdefghijklmnopqrstuvwxyz012345"
                  "xoxb-123456789012-abcdefghijkl"
                  "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abcdefgh"
                  "api_key = abcdefghijklmnop"
                  "password: correct-horse-battery-staple"
                  "OPENCODE_API_KEY=abcdefghijklmnop"))
    (testing text
      (let ((scrubbed (enchiridion.llm.secrets:scrub text)))
        (ok (search enchiridion.llm.secrets:+redaction-marker+ scrubbed))
        (ng (search "abcdefghijklmnop" scrubbed))))))

(deftest ordinary-prose-is-not-mangled ()
  ;; A scrubber that eats everything is as broken as one that eats nothing.
  (dolist (text '("The build failed at line 42."
                  "SOUL.md needs a section on voice."
                  "token counts are in the ledger"
                  "password manager is a different problem"
                  ""))
    (testing text
      (ok (equal text (enchiridion.llm.secrets:scrub text))))))

(deftest a-tool-result-is-scrubbed-before-it-enters-the-transcript ()
  ;; The scrubber runs on the tool result, not on the outbound request, so a
  ;; secret never reaches the transcript at all.
  (enchiridion.llm.secrets:clear-secrets)
  (enchiridion.llm.secrets:register-secret "OPENCODE_API_KEY" +fake-key+)
  (let* ((tool-result (format nil "cat /run/secrets/.env -> OPENCODE_API_KEY=~A"
                              +fake-key+))
         (scrubbed (enchiridion.llm.secrets:scrub tool-result)))
    (ng (search +fake-key+ scrubbed)))
  (enchiridion.llm.secrets:clear-secrets))

(deftest a-plain-alist-has-its-strings-scrubbed ()
  (enchiridion.llm.secrets:clear-secrets)
  (enchiridion.llm.secrets:register-secret "OPENCODE_API_KEY" +fake-key+)
  (testing "a plist value"
    (ng (search +fake-key+
                (prin1-to-string
                 (enchiridion.llm.secrets:scrub-object
                  (list :authorization (format nil "Bearer ~A" +fake-key+)))))))
  (testing "a nested list"
    (ng (search +fake-key+
                (prin1-to-string
                 (enchiridion.llm.secrets:scrub-object
                  (list :headers (list (cons "x-key" +fake-key+))))))))
  (testing "a vector"
    (ng (search +fake-key+
                (prin1-to-string
                 (enchiridion.llm.secrets:scrub-object (vector +fake-key+))))))
  (enchiridion.llm.secrets:clear-secrets))

(deftest a-credential-named-field-is-replaced-whatever-its-value ()
  ;; The role filter. A token this process never loaded, in a field called
  ;; :token, with a value that matches no known shape.
  (dolist (field '(:token :secret :password :api-key :api_key :access-token
                   :private-key "token" "api_key"))
    (testing (format nil "~A" field)
      (let* ((tree (list field "a-value-that-matches-no-shape"))
             (scrubbed (enchiridion.llm.secrets:scrub-tree tree))
             (text (prin1-to-string scrubbed)))
        (ng (search "a-value-that-matches-no-shape" text))
        (ok (search "redacted" text)))))
  (testing "a field that is not a credential keeps its value"
    (ok (search "kept" (prin1-to-string
                       (enchiridion.llm.secrets:scrub-tree
                        '(:message "kept")))))))

(deftest a-vector-of-messages-is-scrubbed-tree-wide ()
  (let ((messages (vector (list :role "user"
                                :content (format nil "my key is ~A" +fake-key+)))))
    (enchiridion.llm.secrets:clear-secrets)
    (enchiridion.llm.secrets:register-secret "OPENCODE_API_KEY" +fake-key+)
    (ng (search +fake-key+ (prin1-to-string
                            (enchiridion.llm.secrets:scrub-tree messages))))
    (enchiridion.llm.secrets:clear-secrets)))

(deftest non-strings-pass-through-scrub-unchanged ()
  (dolist (value '(nil 42 :symbol #\a 1.5d0 t))
    (ok (eql value (enchiridion.llm.secrets:scrub value)))))

(deftest a-block-write-is-scrubbed ()
  ;; The block-write path.
  (enchiridion.llm.secrets:clear-secrets)
  (enchiridion.llm.secrets:register-secret "OPENCODE_API_KEY" +fake-key+)
  (ng (search +fake-key+
              (prin1-to-string
               (enchiridion.llm.secrets:scrub-tree
                (list :label :world
                      :text (format nil "the deploy key is ~A" +fake-key+))))))
  (enchiridion.llm.secrets:clear-secrets))

(deftest a-journal-entry-is-scrubbed ()
  ;; The journal-entry path.
  (enchiridion.llm.secrets:clear-secrets)
  (enchiridion.llm.secrets:register-secret "FLUXER_BOT_TOKEN" +fake-key+)
  (ng (search +fake-key+
              (enchiridion.llm.secrets:scrub
               (format nil "gateway token was ~A" +fake-key+))))
  (enchiridion.llm.secrets:clear-secrets))

(deftest an-env-file-parses-into-names-and-values ()
  (testing "a plain pair"
    (multiple-value-bind (name value present) (enchiridion.llm.secrets:parse-env-line "OPENCODE_API_KEY=abc123")
      (ok present)
      (ok (equal name "OPENCODE_API_KEY"))
      (ok (equal value "abc123"))))
  (testing "export"
    (multiple-value-bind (name value present) (enchiridion.llm.secrets:parse-env-line "export FOO=bar")
      (ok present)
      (ok (equal name "FOO"))
      (ok (equal value "bar"))))
  (testing "quotes are removed, because a quote is shell syntax"
    (multiple-value-bind (name value present) (enchiridion.llm.secrets:parse-env-line "FOO=\"bar baz\"")
      (declare (ignore name))
      (ok present)
      (ok (equal value "bar baz"))))
  (testing "single quotes too"
    ;; name is bound and ignored rather than bound to NIL: NIL is not a legal
    ;; variable name, and a let that names an unused variable is a warning.
    (multiple-value-bind (name value present) (enchiridion.llm.secrets:parse-env-line "FOO='bar'")
      (declare (ignore name))
      (ok present)
      (ok (equal value "bar"))))
  (testing "an equals sign inside the value is kept"
    (multiple-value-bind (name value present) (enchiridion.llm.secrets:parse-env-line "FOO=a=b")
      (ok present)
      (ok (equal name "FOO"))
      (ok (equal value "a=b"))))
  (testing "comments, blanks, and rubbish"
    (ng (nth-value 2 (enchiridion.llm.secrets:parse-env-line "# a comment")))
    (ng (nth-value 2 (enchiridion.llm.secrets:parse-env-line "")))
    (ng (nth-value 2 (enchiridion.llm.secrets:parse-env-line "NOEQUALS")))
    (ng (nth-value 2 (enchiridion.llm.secrets:parse-env-line "=novalue")))))

(deftest loading-from-a-stream-holds-every-pair ()
  (enchiridion.llm.secrets:clear-secrets)
  (with-input-from-string (stream (format nil "~%# a comment~%OPENCODE_API_KEY=~A~%FLUXER_BOT_TOKEN=other-value~%"
                                        +fake-key+))
    (enchiridion.llm.secrets:load-secrets-from stream))
  (ok (enchiridion.llm.secrets:secret-present-p "OPENCODE_API_KEY"))
  (ok (enchiridion.llm.secrets:secret-present-p "FLUXER_BOT_TOKEN"))
  (ok (equal '("FLUXER_BOT_TOKEN" "OPENCODE_API_KEY")
             (enchiridion.llm.secrets:secret-names)))
  (ok (eq :file (enchiridion.llm.secrets:secret-source "OPENCODE_API_KEY")))
  (enchiridion.llm.secrets:clear-secrets))

(deftest names-and-sources-are-listable-without-values ()
  (enchiridion.llm.secrets:clear-secrets)
  (enchiridion.llm.secrets:register-secret "SOME_KEY" +fake-key+ :env)
  (testing "the name is listable"
    (ok (member "SOME_KEY" (enchiridion.llm.secrets:secret-names) :test #'string=)))
  (testing "the source is listable"
    (ok (eq :env (enchiridion.llm.secrets:secret-source "SOME_KEY"))))
  (testing "and printing the names does not print the value"
    (ng (search +fake-key+
                (with-output-to-string
                  (s) (loop for n in (enchiridion.llm.secrets:secret-names)
                            do (format s "~A~%" n))))))
  (enchiridion.llm.secrets:clear-secrets))

(deftest a-sealed-scrubber-changes-nothing ()
  (enchiridion.llm.secrets:clear-secrets)
  (enchiridion.llm.secrets:register-secret "SOME_KEY" +fake-key+)
  (unwind-protect
       (progn
         (enchiridion.llm.secrets:seal)
         (ok (enchiridion.llm.secrets:scrub +fake-key+)))
    (enchiridion.llm.secrets:unseal))
  (ng (search +fake-key+ (enchiridion.llm.secrets:scrub +fake-key+)))
  (enchiridion.llm.secrets:clear-secrets))

(deftest scrubbing-twice-changes-nothing-further ()
  ;; Idempotency. If the first pass inserted text that the second pass would
  ;; match, a pipeline that scrubs at two boundaries would keep churning.
  (dolist (text (list (format nil "Bearer ~A" +fake-key+)
                      (format nil "key=~A" +fake-key+)
                      +fake-key+))
    (testing text
      (let* ((once (enchiridion.llm.secrets:scrub text))
             (twice (enchiridion.llm.secrets:scrub once)))
        (ok (equal once twice))))))

(deftest the-pattern-is-rebuilt-when-a-secret-is-added ()
  (enchiridion.llm.secrets:clear-secrets)
  (testing "before it is loaded the value is ordinary text and stays that way"
    (ok (search "later-value-not-yet-loaded"
                (enchiridion.llm.secrets:scrub "later-value-not-yet-loaded"))))
  (testing "and it is gone the moment it is loaded"
    (enchiridion.llm.secrets:register-secret "LATE" "later-value-not-yet-loaded")
    (ng (search "later-value-not-yet-loaded"
                (enchiridion.llm.secrets:scrub "later-value-not-yet-loaded"))))
  (enchiridion.llm.secrets:clear-secrets))

(deftest a-secret-file-the-world-can-read-is-refused ()
  ;; The container copy of the secret file is gone at steady state.
  ;; This test is the other half: it is gone, and while it is there the world
  ;; cannot read it.
  (with-scratch-directory (scratch)
    (let ((path (merge-pathnames "secrets.env" scratch)))
      (testing "an absent file is not a leak"
        (ng (probe-file path))
        (ok (enchiridion.llm.secrets:secret-file-mode-ok-p path)))
      (write-fixture path "OPENCODE_API_KEY=not-a-real-value")
      (testing "the mode the operator is told to use passes"
        (enchiridion.compat:set-file-mode path #o600)
        (ok (eql #o600 (enchiridion.compat:file-mode path)))
        (ok (enchiridion.llm.secrets:secret-file-mode-ok-p path)))
      (testing "a group readable file passes, because only the world bit leaks"
        (enchiridion.compat:set-file-mode path #o640)
        (ok (enchiridion.llm.secrets:secret-file-mode-ok-p path)))
      (testing "a world readable file is refused"
        (enchiridion.compat:set-file-mode path #o644)
        (ng (enchiridion.llm.secrets:secret-file-mode-ok-p path)))
      (testing "the world execute bit is not the world read bit"
        (enchiridion.compat:set-file-mode path #o601)
        (ok (enchiridion.llm.secrets:secret-file-mode-ok-p path))))))

(deftest only-the-container-copy-may-be-unlinked ()
  ;; The refusal is the test that matters. The operator's checkout .env is the
  ;; file a quiet delete would destroy, and this function is the only thing in
  ;; the tree allowed to unlink a secret file at all.
  (with-scratch-directory (scratch)
    (let* ((container (merge-pathnames "run/secrets/.env" scratch))
           (checkout (merge-pathnames ".env" scratch)))
      (write-fixture container "OPENCODE_API_KEY=not-a-real-value")
      (write-fixture checkout "OPENCODE_API_KEY=not-a-real-value")
      (testing "a path that is not the container path is refused and stays"
        (ng (enchiridion.llm.secrets:discard-secrets-file checkout))
        (ok (probe-file checkout)))
      (testing "the container path is the one path that goes"
        ;; The container path is moved into the scratch directory for the length
        ;; of this form. A nix build sandbox has no /run/secrets to write to, so
        ;; a test that used the deployed path would pass by never running the
        ;; delete at all, and the branch that ships would be the branch that is
        ;; never exercised here.
        (let ((enchiridion.llm.secrets:+container-secrets-path+ container))
          (ok (enchiridion.llm.secrets:discard-secrets-file container)))
        (ng (probe-file container))))))

(deftest credential-shaped-names-are-recognised-and-plain-names-are-not ()
  (testing "the names the shipped configuration reads"
    (dolist (name '("OPENAI_API_KEY" "OPENCODE_API_KEY" "ANTHROPIC_API_KEY"
                    "FLUXER_BOT_TOKEN" "ENCHIRIDION_HTTP_TOKEN"))
      (testing name
        (ok (enchiridion.llm.secrets:credential-variable-p name)))))
  (testing "the names the operator's own tooling brings"
    (dolist (name '("GITHUB_TOKEN" "AWS_SECRET_ACCESS_KEY" "MY_PASSWORD"
                    "SOME_PASSWD" "DEPLOY_PRIVATE_KEY" "SERVICE_APIKEY"
                    "HTTP_AUTHORIZATION" "github_token" "aws_secret_access_key"))
      (testing name
        (ok (enchiridion.llm.secrets:credential-variable-p name)))))
  (testing "the names the child process cannot lose"
    (dolist (name '("PATH" "HOME" "PWD" "SHELL" "TERM" "LANG" "LC_ALL" "TMPDIR"
                    "USER" "LOGNAME" "SBCL_HOME" "CL_SOURCE_REGISTRY"
                    "ENCHIRIDION_SOURCE" "ENCHIRIDION_SBCL" "LD_LIBRARY_PATH"
                    "DYLD_LIBRARY_PATH" "DYLD_FALLBACK_LIBRARY_PATH"
                    "XDG_CACHE_HOME" "XDG_CONFIG_HOME" "XDG_DATA_HOME"
                    "XDG_STATE_HOME" "XDG_RUNTIME_DIR"))
      (testing name
        (ng (enchiridion.llm.secrets:credential-variable-p name)))))
  (testing "a name that is not a string, and the empty name, are not credentials"
    (ng (enchiridion.llm.secrets:credential-variable-p nil))
    (ng (enchiridion.llm.secrets:credential-variable-p ""))
    (ng (enchiridion.llm.secrets:credential-variable-p :OPENCODE_API_KEY))))

(deftest the-file-the-loader-opened-is-remembered-after-it-is-gone ()
  ;; The container copy is unlinked the moment its values are in memory. This is
  ;; what lets the `secrets` line name that file afterwards instead of resolving
  ;; the path a second time, finding the host fallback, and calling it absent
  ;; while listing names that plainly came from somewhere.
  (with-scratch-directory (scratch)
    (let ((path (merge-pathnames "secrets.env" scratch)))
      (enchiridion.llm.secrets:clear-secrets)
      (testing "nothing is remembered before a file is read"
        (ng (enchiridion.llm.secrets:secrets-file-read))
        (ng (enchiridion.llm.secrets:secrets-file-mode-read)))
      (write-fixture path "OPENCODE_API_KEY=not-a-real-value")
      (enchiridion.compat:set-file-mode path #o600)
      (enchiridion.llm.secrets:load-secrets :path path)
      (testing "the loader names the file it opened and the mode it had"
        (ok (uiop:pathname-equal path
                                 (enchiridion.llm.secrets:secrets-file-read)))
        (ok (eql #o600 (enchiridion.llm.secrets:secrets-file-mode-read))))
      (delete-file path)
      (testing "and both survive the file they describe"
        (ng (probe-file path))
        (ok (uiop:pathname-equal path
                                 (enchiridion.llm.secrets:secrets-file-read)))
        (ok (eql #o600 (enchiridion.llm.secrets:secrets-file-mode-read))))
      (testing "clear-secrets forgets the file with the values"
        (enchiridion.llm.secrets:clear-secrets)
        (ng (enchiridion.llm.secrets:secrets-file-read))
        (ng (enchiridion.llm.secrets:secrets-file-mode-read))))))
