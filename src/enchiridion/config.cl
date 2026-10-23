;;;; config.cl --- Reading the operator configuration.
;;;;
;;;; config.example.cl writes a sectioned list: :LLM is followed by a list of
;;;; (key value) entries, then :CHANNELS by one entry per channel, and so on.
;;;; That is not a property list. GETF on it reads the first section name and
;;;; its first entry, then treats every later entry as a key, so a configured
;;;; model silently becomes the default. The reader below is the one place
;;;; that knows the difference.
;;;;
;;;; A flat property list is still accepted. The tests and a small config are
;;;; easier to read that way, and the flat shape was the only shape the first
;;;; adapter understood. The sectioned shape wins when both could match.

(in-package #:enchiridion)

(defparameter +config-sections+
  '(:llm :channels :budget :sandbox :memory :sleep)
  "The top-level section names. A sectioned config is one of these keywords,
followed by a list of (key value ...) entries, until the next section name.")

(declaim (ftype (function (t) boolean) sectioned-config-p))

(defun sectioned-config-p (config)
  "Return T when CONFIG uses the sectioned shape from config.example.cl."
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
  "Return the memory store path from the :MEMORY section of CONFIG, or NIL.

CONFIG-VALUE reads the :LLM section, because that is where every option it
was written for lives. The store path is the first option outside that
section, and a reader that looked in the wrong one would fall back to the
default file in silence, which is the failure this function exists to avoid.
A NIL return is not an error: it means the default beside the agent files."
  (second (assoc :db (config-section config :memory) :test #'eq)))

(declaim (ftype (function (t keyword &optional t) t) config-value))

(defun config-value (config key &optional default)
  "Return KEY from CONFIG, or DEFAULT.
CONFIG is either the sectioned shape from config.example.cl or a flat
property list. The sectioned shape is tried first. The flat shape is the
fallback, so a one-line config still reads the way it looks."
  (let ((entry (assoc key (config-section config :llm) :test #'eq)))
    (cond
      (entry (second entry))
      ((sectioned-config-p config) default)
      (t (getf config key default)))))

(declaim (ftype (function (t keyword keyword &optional t) t) config-section-value))

(defun config-section-value (config section key &optional default)
  "Return KEY from SECTION of CONFIG, or DEFAULT.

CONFIG-VALUE reads the :LLM section only, because that is where every option
it was written for lives. The budget caps, the agent uid, the sleep interval
and the memory limits live in sections of their own, and an option read
through CONFIG-VALUE falls back to the default in silence: `budget` prints no
cap for a cap that is configured, and the heartbeat never finds its interval.
A flat CONFIG has no sections, so there DEFAULT is the whole answer rather
than a value invented from a shape that does not carry one."
  (let ((entry (assoc key (config-section config section) :test #'eq)))
    (if entry (second entry) default)))

;;;; The active configuration.
;;;;
;;;; One plist is active for the life of the process, bound by READ-CONFIG.
;;;; A lookup asks the active configuration first and the defaults second, so
;;;; a config.cl that names two keys does not blank out the other twenty.

(defun default-config ()
  "Return the configuration every lookup falls back to.

It holds paths and behaviour only, exactly like config.cl: a secret never
comes from here, because a file in the repository is a file that ends up in a
store path. The model defaults match the shipped adapter defaults."
  '(:llm
    (:provider :openai)
    (:backend :openai)
    (:base-url nil)
    ;; NIL means the selected provider row's model. A named model here is an
    ;; override for every provider, and the shipped row already knows which
    ;; model its endpoint can serve.
    (:model-primary nil)
    (:model-cheap nil)
    (:model-sleep nil)
    ;; NIL and not a variable name: the provider table in the LLM module names
    ;; the key variable for the provider that was selected, and a name shipped
    ;; here would pin every install to OpenAI's. NIL means the provider decides.
    (:api-key-env nil)
    ;; The Messages API requires a max_tokens field on every request and has no
    ;; default of its own; the OpenAI-shaped wire ignores the key entirely. The
    ;; value bounds one reply, and it is not derived from the budget, which
    ;; bounds what a day may spend.
    (:max-tokens 4096)

    ;; The three providers this build ships a row for, so the default path
    ;; works with no catalog cached and no network. They are configuration and
    ;; not code on purpose: everything else this tree knows about a provider is
    ;; generated at run time from models.dev, and a row here is exactly the
    ;; same shape as a row the operator writes, so either can override the
    ;; other field by field. Each row pins the endpoint, the key variable and
    ;; the default model the shipped documentation promises.
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

    ;; The runtime catalog. :providers-url is models.dev and not a mirror, and
    ;; the two TTLs are a day: a provider's endpoint does not move hourly, and
    ;; a model list is a snapshot rather than an inventory.
    (:providers-url "https://models.dev/api.json")
    (:providers-ttl-seconds 86400)
    (:models-ttl-seconds 86400)
    ;; T means no network at start up at all: no catalog fetch, no model list.
    ;; An explicit `enchiridion providers refresh` still works, because the
    ;; operator asked for it.
    (:offline nil)

    ;; Cloud placement. Bedrock reads :region, Vertex reads :project and
    ;; :location; the environment variables of the same meaning win when these
    ;; are NIL.
    (:region nil)
    (:project nil)
    (:location nil)

    :channels
    (:cli (:enabled t))
    (:http (:enabled nil) (:bind "127.0.0.1") (:port 8787) (:token nil)
           (:token-env "ENCHIRIDION_HTTP_TOKEN") (:max-body-bytes 65536))
    (:fluxer (:enabled nil) (:allowed-users nil) (:token-env "FLUXER_BOT_TOKEN"))

    :budget
    (:max-tokens-per-tick 4000)
    (:max-tokens-per-day 400000)

    :sandbox
    (:agent-uid 1000)
    (:agent-gid 1000)
    (:proc-hidepid 2)

    :memory
    (:db nil)
    (:block-limits (:persona 1200 :operator 800 :world 1500 :session 400 :ledger 250))

    :sleep
    (:enabled t)
    (:interval-seconds 900)))

(defparameter *config* nil
  "The active configuration plist, or NIL before READ-CONFIG runs.
Bound once at start up so a command can ask a configuration question without
carrying the plist through every call.")

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
  "Return KEY from the active configuration, then from the defaults, then
DEFAULT. The :ABSENT sentinel is not a usable value for any key here, which is
what lets an explicit NIL in config.cl mean NIL rather than missing."
  (let ((value (config-value (config) key :absent)))
    (if (eq value :absent)
        (config-value (default-config) key default)
        value)))

(declaim (ftype (function (t) keyword) channel-key))

(defun channel-key (name)
  "Return NAME as the keyword the :CHANNELS section is keyed by.
A keyword and a string are one value everywhere else in the tree and they are
one value here."
  (if (keywordp name) name (intern (string-upcase (string name)) :keyword)))

(declaim (ftype (function (t) list) channel-options))

(defun channel-options (entry)
  "Return one :CHANNELS entry as a property list.

A channel entry is a list of (key value ...) entries, not a property list.
GETF on that shape reads the first option and nothing else, so every option
after :ENABLED was unreachable: the webhook could never find its bind address
and Fluxer could never find its allowlist. This is the one place that knows
the difference."
  (loop for option in (rest entry)
        append (list (first option) (second option))))

(declaim (ftype (function (t &optional t) t) channel-config))

(defun channel-config (name &optional (config (config)))
  "Return the plist under :CHANNELS for NAME, or the shipped entry for NAME.

NAME is a keyword or a string; the two are one value everywhere else in the
tree and they are one value here. The operator's options win key by key and
the shipped entry fills the gaps, so a config.cl that writes
(:http (:enabled t)) keeps the default bind address and port instead of
losing them. An explicit NIL in the operator's entry is a value and wins: it
means off, not missing."
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
  "Return KEY of the channel called NAME, or DEFAULT.
CHANNEL-CONFIG already merges the operator's entry over the shipped one, so
this is only the reader that gives a missing key a caller's default."
  (getf (channel-config name) key default))

(declaim (ftype (function (t) boolean) channel-enabled-p))

(defun channel-enabled-p (name)
  "Return T when the channel called NAME is enabled. A channel with no entry
is disabled, because an unconfigured channel that starts is a surprise."
  (not (null (channel-value name :enabled))))

(declaim (ftype (function (t) list) configured-secret-names))

(defun configured-secret-names (config)
  "Return every environment variable name the configuration says holds a secret.

The API key, the Fluxer bot token and the webhook token are each named by a
configuration key rather than written into the file, so the loader has to ask
the configuration which names to read. One list, one call to the loader, and
one place to audit: a channel whose token variable is missing from this list
is a token that never reaches the scrubber, and an unregistered token is the
one kind the shape filter cannot catch."
  (let ((names '()))
    (dolist (name (list (config-value config :api-key-env)
                        (getf (channel-config :fluxer config) :token-env)
                        (getf (channel-config :http config) :token-env)))
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

;;;; Paths.
;;;;
;;;; ENCHIRIDION_HOME wins: inside the container the installed source is read
;;;; only and the agent directory has to be on the volume. Without it the
;;;; current directory is the root, because `nix run` executes a script in the
;;;; store while the operator stands in the checkout.

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
  "Return the directory that holds the control and status files, with a
trailing slash. It is a plain directory of small files rather than a socket,
so tail and grep work on it."
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
  "Return the directory above DIRECTORY, or NIL at the top of the tree. At the
top, UIOP returns the same directory, so the walk has to be told to stop."
  (let ((parent (uiop:pathname-parent-directory-pathname directory)))
    (unless (equal (truename directory) (truename parent))
      parent)))

(declaim (ftype (function () (or null string)) project-root))

(defun project-root ()
  "Return the checkout root as a namestring, or NIL.
ENCHIRIDION_SOURCE wins, because the installed copy has no checkout above it.
Otherwise the nearest directory above the current one that holds
enchiridion.asd is the root."
  (or (enchiridion.compat:environment-value "ENCHIRIDION_SOURCE")
      (loop for directory = (uiop:ensure-directory-pathname (uiop:getcwd))
              then (config-parent directory)
            while directory
            thereis (when (probe-file (merge-pathnames "enchiridion.asd" directory))
                      (string-right-trim "/" (namestring directory))))))

(declaim (ftype (function () (or null pathname)) config-path))

(defun config-path ()
  "Return the config.cl to read, or NIL.
The current directory wins over the installed source, because a checkout keeps
config.cl beside the code and looking only beside the script would silently
fall back to the defaults."
  (let ((here (merge-pathnames "config.cl" (uiop:getcwd))))
    (or (probe-file here)
        (let ((root (project-root)))
          (and root
               (probe-file (merge-pathnames
                            "config.cl"
                            (uiop:ensure-directory-pathname root))))))))

(declaim (ftype (function () t) read-config))

(defun read-config ()
  "Load config.cl when there is one, make it active, and return it.
An absent file is not an error: it means the defaults. Environment variables
override the file, so a container can be injected with no file at all."
  (let ((path (config-path)))
    (setf *config-source* (or path :defaults))
    (when path
      ;; Deliberate. config.cl is operator written Lisp that lives outside
      ;; version control, and loading it is the only way to honour it.
      (load path :verbose nil :print nil))
    (setf *config*
          (or (and (boundp 'enchiridion.user::*enchiridion-config*)
                   (symbol-value 'enchiridion.user::*enchiridion-config*))
              (default-config)))
    *config*))

(declaim (ftype (function (&optional t) string) config-digest))

(defun config-digest (&optional (configuration (config)))
  "Return an eight character digest of CONFIGURATION, for the status file and
the log. A digest and not the configuration itself: the status file is world
readable and the configuration is not a place for a local path."
  (let ((hash 5381)
        (text (princ-to-string configuration)))
    (loop for character across text
          do (setf hash (mod (+ (* hash 33) (char-code character))
                             (expt 2 32))))
    (format nil "~8,'0X" hash)))
