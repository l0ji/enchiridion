;;;; config.lsp --- Operator configuration reader.
;;;;
;;;; Supports both the sectioned shape (:LLM (key val) ... :CHANNELS ...)
;;;; and flat plists; sectioned takes precedence when both could match.

(in-package #:enchiridion)

(defparameter +config-sections+
  '(:llm :channels :budget :sandbox :memory :sleep)
  "Top-level section keywords recognized in sectioned configs.")

(declaim (ftype (function (t) boolean) sectioned-config-p))

(defun sectioned-config-p (config)
  "Return T when CONFIG uses the sectioned shape from config.example.lsp."
  (and (consp config)
       (member (first config) +config-sections+ :test #'eq)
       (consp (second config))))

(declaim (ftype (function (t keyword) list) config-section))

(defun config-section (config name)
  "Return the entries under section NAME, each a (key value ...) list.
Return NIL when the section is absent or CONFIG is flat."
  (when (sectioned-config-p config)
    (let ((tail (member name config :test #'eq)))
      (when tail
        (loop for entry in (cdr tail)
              while (consp entry)
              collect entry)))))

(declaim (ftype (function (t) t) config-memory-db))

(defun config-memory-db (config)
  "Return :DB from the :MEMORY section of CONFIG, or NIL for the default path."
  (second (assoc :db (config-section config :memory) :test #'eq)))

(declaim (ftype (function (t keyword &optional t) t) config-value))

(defun config-value (config key &optional default)
  "Return KEY from the :LLM section of a sectioned CONFIG, or via GETF if flat."
  (let ((entry (assoc key (config-section config :llm) :test #'eq)))
    (cond
      (entry (second entry))
      ((sectioned-config-p config) default)
      (t (getf config key default)))))

(declaim (ftype (function (t keyword keyword &optional t) t) config-section-value))

(declaim (ftype (function (t keyword t) list) config-with-llm-value))

(defun config-with-llm-value (config key value)
  "Return a copy of CONFIG with :LLM option KEY prepended as VALUE."
  (if (sectioned-config-p config)
      (if (member :llm config :test #'eq)
          (loop for head in config
                collect head
                when (eq head :llm) collect (list key value))
          (list* :llm (list key value) config))
      (list* key value config)))

(defun config-section-value (config section key &optional default)
  "Return KEY from SECTION of a sectioned CONFIG, or DEFAULT (always DEFAULT if flat)."
  (let ((entry (assoc key (config-section config section) :test #'eq)))
    (if entry (second entry) default)))

(declaim (ftype (function (t keyword keyword) t) config-setting))

(defun config-setting (config section key)
  "Return KEY from SECTION in CONFIG, falling back to DEFAULT-CONFIG.
Signals an error if KEY is not defined in DEFAULT-CONFIG."
  (let ((shipped (assoc key (config-section (default-config) section) :test #'eq)))
    (unless shipped
      (error "~S is not a setting in the ~S section of the shipped configuration."
             key section))
    (second (or (assoc key (config-section config section) :test #'eq)
                shipped))))

(declaim (ftype (function (t) (integer 0 *)) config-tool-rounds))

(defun config-tool-rounds (config)
  "Return the maximum tool rounds per turn."
  (let ((rounds (config-setting config :budget :max-tool-rounds)))
    (unless (typep rounds '(integer 0 *))
      (error 'enchiridion.errors:configuration-error
             :key :max-tool-rounds :detail "Use a non-negative integer."))
    rounds))

;;;; Active configuration (falls back to DEFAULT-CONFIG per key).

(defun default-config ()
  "Return the shipped default configuration (paths and behavior only, no secrets)."
  '(:llm
    (:provider :openai)
    (:backend :openai)
    (:base-url nil)
    ;; NIL defers to the selected provider's default model.
    (:model-primary nil)
    (:model-cheap nil)
    (:model-sleep nil)
    ;; NIL defers to the selected provider's api-key-env.
    (:api-key-env nil)
    ;; Per-reply cap (required by Anthropic Messages API; ignored by OpenAI wire).
    (:max-tokens 4096)

    ;; Built-in provider rows for offline/uncached operation; same shape as operator overrides.
    (:providers
     ((:id :openai
       :name "OpenAI"
       :profile :openai
       :base-url "https://api.openai.com/v1/"
       :api-key-env "OPENAI_API_KEY"
       :model "gpt-5.6-luna")
      (:id :opencode
       :name "OpenCode Go"
       :profile :openai
       :base-url "https://opencode.ai/zen/go/v1"
       :api-key-env "OPENCODE_API_KEY"
       :model "deepseek-v4.1-flash")
      (:id :anthropic
       :name "Anthropic"
       :profile :anthropic
       :base-url "https://api.anthropic.com/"
       :api-key-env "ANTHROPIC_API_KEY"
       :model "claude-sonnet-5-5")))

    ;; Runtime provider catalog and daily cache TTLs.
    (:providers-url "https://models.dev/api.json")
    (:providers-ttl-seconds 86400)
    (:models-ttl-seconds 86400)
    ;; T disables startup network fetches (explicit refresh still works).
    (:offline nil)

    ;; Cloud placement overrides; NIL defers to environment variables.
    (:region nil)
    (:project nil)
    (:location nil)

    :channels
    (:cli (:enabled t))
    (:http (:enabled nil) (:bind "127.0.0.1") (:port 8787) (:token nil)
           (:token-env "ENCHIRIDION_HTTP_TOKEN") (:max-body-bytes 65536))
    (:fluxer (:enabled nil) (:allowed-users nil) (:token-env "FLUXER_BOT_TOKEN")
             (:custom-status nil) (:custom-status-user nil)
             (:custom-status-ttl-seconds 300)
             (:custom-status-cooldown-seconds 60))

    :budget
    (:max-tool-rounds 64)
    (:max-tokens-per-tick 400000)
    (:max-tokens-per-day 40000000)

    :sandbox
    (:agent-uid 1000)
    (:agent-gid 1000)

    :memory
    (:db nil)
    (:recent-turns 6)
    (:recent-window-chars 4000)
    (:block-limits (:persona 6000 :operator 1600 :world 3000 :adapt 1200
                    :session 400 :ledger 250 :bootstrap 300))
    ;; The limit for a block whose label :block-limits does not name.
    (:unlisted-block-limit 1200)
    ;; Episodic log and pull retrieval are on; push/promotion are off by default.
    (:enabled t)
    (:retrieve t)
    (:push nil)
    (:record-sleep t)
    (:pack-chars 4450)
    (:push-max-fraction 0.5)
    (:maintenance-batch 200)
    ;; Dense embeddings and model reranker (off by default).
    (:embed nil)
    (:embed-model "text-embedding-3-small")
    (:embed-dimensions 512)
    (:embed-base-url "https://api.openai.com/v1/")
    (:embed-key-env "OPENAI_API_KEY")
    (:rerank nil)
    (:graph-limit 20000)
    (:t2-enabled t)
    (:t2-interval-seconds 86400)
    (:t2-episode-threshold 200)
    (:t2-max-episodes-per-tick 5)
    (:t2-max-tokens-per-pass 2000000)
    ;; Higher reply cap for T2 deriver calls (reasoning models need headroom).
    (:t2-deriver-max-tokens 16384)
    (:t2-deriver-concurrency 4)
    ;; T2 deriver model; NIL falls back to :llm :model-cheap.
    (:t2-deriver-model nil)
    (:t2-max-tokens-per-episode 16000)
    (:t2-writes-per-episode 8)
    (:canaries :built-in)
    (:canary-min-families 4)
    (:gate-margin 0.05)
    (:gate-min-n 100)
    ;; Max Q&A pairs scored per utility run, newest first.
    (:utility-max-tasks 400)
    (:gate-alpha 0.05)
    ;; Pack size for utility A/B arms (~25% of :pack-chars).
    (:gate-pack-chars 1100)
    (:tail-rarity-fraction 0.10)
    (:tail-min-n 50)
    (:tail-margin 0.02)
    (:precision-min 0.8)
    ;; Promotion precision window and minimum checked count.
    (:precision-window 20)
    (:precision-min-checked 5)
    (:quarantine-max 0.5)
    ;; Quarantine rate window/minimum; exceeding :quarantine-max switches T2 to weekly.
    (:quarantine-window 20)
    (:quarantine-min-candidates 5)
    (:t2-frozen-interval-seconds 604800)
    (:compaction-rebase-every 8)
    (:compaction-rebase-turns 24)
    (:parameters nil)

    :sleep
    (:enabled t)
    (:interval-seconds 900)))

(defparameter *config* nil
  "Active configuration plist, or NIL before READ-CONFIG runs.")

(defparameter *config-source* :defaults
  "Where the active configuration came from: a pathname, or :DEFAULTS.")

(declaim (ftype (function () t) config))

(defun config ()
  "Return the active configuration, or the defaults when none was read."
  (or *config* (default-config)))

(declaim (ftype (function (t) t) config-set))

(defun config-set (config)
  "Make CONFIG the active configuration and return it."
  (setf *config* config)
  config)

(declaim (ftype (function (t &optional t) t) config-lookup))

(defun config-lookup (key &optional default)
  "Return KEY from active config, then DEFAULT-CONFIG, then DEFAULT.
Uses :ABSENT sentinel so an explicit NIL in config overrides the default."
  (let ((value (config-value (config) key :absent)))
    (if (eq value :absent)
        (config-value (default-config) key default)
        value)))

(declaim (ftype (function (t) keyword) channel-key))

(defun channel-key (name)
  "Convert channel NAME (keyword or string) to its :CHANNELS section keyword."
  (if (keywordp name) name (intern (string-upcase (string name)) :keyword)))

(declaim (ftype (function (t) list) channel-options))

(defun channel-options (entry)
  "Convert a :CHANNELS entry of (key value) pairs into a plist."
  (loop for option in (rest entry)
        append (list (first option) (second option))))

(declaim (ftype (function (t &optional t) t) channel-config))

(defun channel-config (name &optional (config (config)))
  "Return merged plist for channel NAME (operator options over DEFAULT-CONFIG).
Explicit NIL values in CONFIG override shipped defaults."
  (let ((key (channel-key name)))
    (let ((options '()))
      (dolist (entry (list (assoc key (config-section (default-config) :channels)
                                  :test #'eq)
                           (assoc key (config-section (or config (config)) :channels)
                                  :test #'eq)))
        (when entry
          (loop for (option value) on (channel-options entry) by #'cddr
                do (setf (getf options option) value))))
      options)))

(declaim (ftype (function (t keyword &optional t) t) channel-value))

(defun channel-value (name key &optional default)
  "Return KEY from merged CHANNEL-CONFIG for NAME, or DEFAULT."
  (getf (channel-config name) key default))

(declaim (ftype (function (t) boolean) channel-enabled-p))

(defun channel-enabled-p (name)
  "Return T when channel NAME is enabled (default: :cli enabled, network channels disabled)."
  (not (null (channel-value name :enabled))))

(declaim (ftype (function (t) list) config-api-key-env-list))

(defun config-api-key-env-list (config)
  "Return configured :API-KEY-ENV as a list of non-empty variable name strings."
  (let ((value (config-value config :api-key-env)))
    (cond ((and (stringp value) (plusp (length value))) (list value))
          ((listp value)
           (remove-if-not (lambda (name)
                            (and (stringp name) (plusp (length name))))
                          value))
          (t '()))))

(declaim (ftype (function (t) list) configured-secret-names))

(defun configured-secret-names (config)
  "Return all secret env var names referenced by CONFIG (LLM, Fluxer, HTTP, embed)
so the secret loader and scrubber share one authoritative list."
  (let ((names '()))
    (dolist (name (append (config-api-key-env-list config)
                          (list (getf (channel-config :fluxer config) :token-env)
                                (getf (channel-config :http config) :token-env)
                                ;; Dense retrieval key (may differ from chat provider).
                                (config-setting config :memory :embed-key-env))))
      (when (and (stringp name) (plusp (length name)))
        (pushnew name names :test #'string=)))
    (nreverse names)))

(declaim (ftype (function (keyword) t) model-for))

(defun model-for (tier)
  "Return the configured model name for TIER: :PRIMARY, :CHEAP or :SLEEP."
  (config-lookup (ecase tier
                   (:primary :model-primary)
                   (:cheap :model-cheap)
                   (:sleep :model-sleep))))

;;;; Paths (ENCHIRIDION_HOME overrides current working directory).

(defun home-root ()
  "Return the directory the agent directory and run/ live under, no trailing
slash."
  (string-right-trim
   "/"
   (or (enchiridion.compat:environment-value "ENCHIRIDION_HOME")
       (namestring (uiop:getcwd)))))

(declaim (ftype (function () string) agent-directory))

(defun agent-directory ()
  "Return the agent directory as a namestring with a trailing slash."
  (format nil "~A/agents/default/" (home-root)))

(declaim (ftype (function () string) run-directory))

(defun run-directory ()
  "Return the run/ directory holding control and status files, with trailing slash."
  (format nil "~A/run/" (home-root)))

(declaim (ftype (function () pathname) control-path))

(defun control-path ()
  "Return the control file the running supervisor polls, one request per line."
  (merge-pathnames "enchiridion.control" (run-directory)))

(declaim (ftype (function () pathname) status-path))

(defun status-path ()
  "Return the status file the running supervisor writes on every change."
  (merge-pathnames "enchiridion.status" (run-directory)))

(declaim (ftype (function (pathname) (or null pathname)) config-parent))

(defun config-parent (directory)
  "Return the parent of DIRECTORY, or NIL at filesystem root."
  (let ((parent (uiop:pathname-parent-directory-pathname directory)))
    (unless (equal (truename directory) (truename parent))
      parent)))

(declaim (ftype (function () (or null string)) project-root))

(defun project-root ()
  "Return ENCHIRIDION_SOURCE or the nearest ancestor containing enchiridion.asd, or NIL."
  (or (enchiridion.compat:environment-value "ENCHIRIDION_SOURCE")
      (loop for directory = (uiop:ensure-directory-pathname (uiop:getcwd))
              then (config-parent directory)
            while directory
            thereis (when (probe-file (merge-pathnames "enchiridion.asd" directory))
                      (string-right-trim "/" (namestring directory))))))

(declaim (ftype (function () (or null pathname)) config-path))

(defun check-root-config-path (path)
  "Reject a config file or ancestor replaceable by a non-root user."
  (labels ((refuse (entry)
             (error 'enchiridion.errors:configuration-error
                    :key :config
                    :detail (format nil "Root config requires root-owned paths without ~
                                         group or world write permission: ~A"
                                    entry)))
           (check-chain (entry)
             (loop
               (let ((info (sb-posix:stat (namestring entry))))
                 (unless (and (zerop (sb-posix:stat-uid info))
                              (zerop (logand #o022 (sb-posix:stat-mode info))))
                   (refuse entry)))
               (let ((parent (if (uiop:directory-pathname-p entry)
                                 (uiop:pathname-parent-directory-pathname entry)
                                 (uiop:pathname-directory-pathname entry))))
                 (when (equal entry parent) (return))
                 (setf entry parent)))))
    (unless (and (uiop:absolute-pathname-p path)
                 (notany (lambda (part) (member part '(:up :back)))
                         (pathname-directory path)))
      (refuse path))
    (check-chain path)
    (let ((resolved (truename path)))
      (check-chain resolved)
      resolved)))

(defun config-path ()
  "Return the operator config, excluding working-directory lookup for root."
  (let* ((explicit (enchiridion.compat:environment-value "ENCHIRIDION_CONFIG"))
         (source (enchiridion.compat:environment-value "ENCHIRIDION_SOURCE"))
         (root-p (zerop (enchiridion.compat:process-uid)))
         (path
           (cond
             (explicit (pathname explicit))
             (root-p
              (and source
                   (merge-pathnames
                    "config.lsp" (uiop:ensure-directory-pathname source))))
             (t
              (or (probe-file (merge-pathnames "config.lsp" (uiop:getcwd)))
                  (let ((root (project-root)))
                    (and root
                         (merge-pathnames
                          "config.lsp" (uiop:ensure-directory-pathname root)))))))))
    (when (and path (probe-file path))
      (if root-p (check-root-config-path path) (probe-file path)))))

(declaim (ftype (function () t) read-config))

(defun read-config ()
  "Load config.lsp if present, set *CONFIG* and *CONFIG-SOURCE*, and return it.
Falls back to DEFAULT-CONFIG when no file is found."
  (let ((path (config-path)))
    (setf *config-source* (or path :defaults))
    (when path
      ;; Load operator-authored config.lsp.
      (load path :verbose nil :print nil))
    (setf *config*
          (or (and (boundp 'enchiridion.user::*enchiridion-config*)
                   (symbol-value 'enchiridion.user::*enchiridion-config*))
              (default-config)))
    *config*))

(declaim (ftype (function (&optional t) string) config-digest))

(defun config-digest (&optional (configuration (config)))
  "Return an 8-hex-char digest of CONFIGURATION for logs and the world-readable status file."
  (let ((hash 5381)
        (text (princ-to-string configuration)))
    (loop for character across text
          do (setf hash (mod (+ (* hash 33) (char-code character))
                             (expt 2 32))))
    (format nil "~8,'0X" hash)))
