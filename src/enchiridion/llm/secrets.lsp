;;;; secrets.lsp --- Load .env files and scrub secrets from text and data.
;;;;
;;;; Three filters replace matches with [redacted]:
;;;;   Literal  loaded values at least *minimum-secret-length* long
;;;;   Shape    Bearer tokens, sk-/gh*/xox* keys, JWTs, credential key=value pairs
;;;;   Role     fields named token, secret, password, api_key, or credential suffixes

(in-package #:enchiridion.llm.secrets)

;;;; State.

(defparameter *loaded-secrets*
  (make-hash-table :test #'equal)
  "Hash table mapping loaded secret names to values.")

(defparameter *loaded-sources*
  (make-hash-table :test #'equal)
  "Hash table mapping loaded secret names to their source (:env, :file, :argument).")

(defparameter *secrets-file-read*
  nil
  "Pathname of the .env file opened by LOAD-SECRETS, or NIL.
Captured at open time because the container copy is unlinked after loading.")

(defparameter *secrets-file-mode-read*
  nil
  "Permission mode of *SECRETS-FILE-READ* at open time, or NIL.
Captured before any post-load unlink.")

(defparameter *minimum-secret-length*
  8
  "Minimum length for literal scrubbing; shorter values are ignored to avoid over-redacting.")

(defparameter *sealed*
  nil
  "When true, SCRUB returns text unchanged. Used only by tests.")

(defparameter +redaction-marker+
  "[redacted]"
  "Replacement text for scrubbed secrets.")

(defparameter +shape-patterns+
  ;; Use \s (cl-ppcre in nixpkgs does not treat [[:space:]] as a POSIX class)
  ;; and escape \) inside [...] so cl-ppcre does not close the enclosing group.
  '("Bearer\\s+[^\\s\"',;\\)}]+"
    "sk-[A-Za-z0-9_\\-]{8,}"
    "gh[pousr]_[A-Za-z0-9]{16,}"
    "xox[baprs]-[A-Za-z0-9\\-]{8,}"
    "eyJ[A-Za-z0-9_\\-]{8,}\\.[A-Za-z0-9_\\-]{4,}\\.[A-Za-z0-9_\\-]*"
    "(?i)(?:api[_-]?key|apikey|access[_-]?token|auth[_-]?token|refresh[_-]?token|token|secret|password|passwd|private[_-]?key)\\s*[=:]\\s*[\"']?[A-Za-z0-9_\\-./+=]{6,}")
  "Regex pattern strings for credential shapes, combined into one cached scanner.")

(defparameter +role-names+
  '(:token :secret :password :api-key :api_key :apikey :api_secret :credentials
    :access-token :refresh-token :auth-token :private-key :authorization)
  "Field names whose values are always redacted regardless of content.")

(defparameter +role-suffixes+
  '("_secret" "_secrets" "_password" "_passwd" "_api_key" "_apikey"
    "_private_key" "_access_key" "_token" "_credential" "_credentials")
  "Underscore-delimited field-name suffixes that hold credentials.
Excludes _tokens (usage counters).")

(declaim (ftype (function (string string) boolean) string-ends-with-p))

(defun string-ends-with-p (text suffix)
  "Return T when TEXT ends with SUFFIX."
  (let ((offset (- (length text) (length suffix))))
    (and (not (minusp offset))
         (string= text suffix :start1 offset))))

(defparameter *pattern*
  nil
  "Combined scrub regex string, or NIL when unbuilt.")

(defparameter *scanner*
  nil
  "Compiled cl-ppcre scanner for *PATTERN*.")

(defparameter *pattern-stamp*
  nil
  "Secret count *PATTERN* was built for, used to detect invalidation.")

;;;; Accessors.

(defun secret-present-p (name)
  "Return T when a secret called NAME has been loaded."
  (and (stringp name)
       (not (null (gethash name *loaded-secrets*)))))

(defun secret-value (name)
  "Return the value of the secret called NAME, or NIL."
  (gethash name *loaded-secrets*))

(defun secret-source (name)
  "Return where the secret called NAME came from: :env, :file, or :argument."
  (gethash name *loaded-sources*))

(defun secret-names ()
  "Return every loaded secret name, sorted."
  (sort (loop for name being the hash-keys of *loaded-secrets*
               collect name)
        #'string<))

(declaim (ftype (function () (or null pathname)) secrets-file-read))

(defun secrets-file-read ()
  "Return the .env pathname opened by LOAD-SECRETS, or NIL.
Remembered at open time because the container copy is unlinked after loading."
  *secrets-file-read*)

(declaim (ftype (function () (or null (integer 0 #o777))) secrets-file-mode-read))

(defun secrets-file-mode-read ()
  "Return the permission bits of *SECRETS-FILE-READ* at open time, or NIL."
  *secrets-file-mode-read*)

(defun sealed-p ()
  "Return T when the scrubber is sealed."
  (declare (special *sealed*))
  (and *sealed* t))

(defun seal ()
  "Seal the scrubber."
  (declare (special *sealed*))
  (setf *sealed* t))

(defun unseal ()
  "Unseal the scrubber."
  (declare (special *sealed*))
  (setf *sealed* nil))

(defun clear-secrets ()
  "Clear all loaded secrets, file metadata, and cached scrub patterns. For tests."
  (clrhash *loaded-secrets*)
  (clrhash *loaded-sources*)
  (setf *secrets-file-read* nil
        *secrets-file-mode-read* nil
        *pattern* nil
        *scanner* nil
        *pattern-stamp* nil)
  nil)

;;;; Credential names.

(defparameter +credential-name-tokens+
  '("_API_KEY" "_APIKEY" "_TOKEN" "_SECRET" "_PASSWORD" "_PASSWD" "_PRIVATE_KEY")
  "Substrings identifying credential environment variables (matched anywhere in the name).")

(defparameter +credential-variable-names+
  '("OPENAI_API_KEY" "OPENCODE_API_KEY" "ANTHROPIC_API_KEY"
    "FLUXER_BOT_TOKEN" "ENCHIRIDION_HTTP_TOKEN")
  "Explicit credential environment variable names used by the shipped configuration.")

(declaim (ftype (function (t) boolean) credential-variable-p))

(defun credential-variable-p (name)
  "Return T when NAME is a credential environment variable name (case-insensitive).
Returns NIL for non-strings, empty strings, and non-credential system variables."
  (and (stringp name)
       (plusp (length name))
       (let ((wanted (string-upcase name)))
         (not (null (or (member wanted +credential-variable-names+
                                :test #'string=)
                        (some (lambda (token) (search token wanted))
                              +credential-name-tokens+)
                        (search "AUTHORIZATION" wanted)))))))

;;;; Loading.

(defparameter +container-secrets-path+
  #p"/run/secrets/.env"
  "Tmpfs path for container secrets. DISCARD-SECRETS-FILE only unlinks this path.
Defined with DEFPARAMETER (not DEFCONSTANT) so tests can rebind it.")

(defun host-secrets-file (directory)
  "Return the .env pathname inside DIRECTORY."
  (merge-pathnames ".env" (uiop:ensure-directory-pathname directory)))

(defun secrets-file (&key (directories (list #p"./"))
                            (container +container-secrets-path+))
  "Return the secret file to read: CONTAINER if it exists, else the first
existing .env in DIRECTORIES, else .env in the first directory."
  (or (and container (probe-file container))
      (loop for directory in directories
            for path = (host-secrets-file directory)
            when (probe-file path)
              return path)
      (host-secrets-file (or (first directories) #p"./"))))

(declaim (ftype (function () pathname) operator-secrets-file))

(defun operator-secrets-file ()
  "Resolve the operator's .env from the container path, then CWD, then
PROJECT-ROOT (dropping NIL when outside a checkout)."
  (the pathname
       (secrets-file :directories (remove nil
                                          (list (uiop:getcwd)
                                                (enchiridion:project-root))))))

(declaim (ftype (function (t) boolean) secret-file-mode-ok-p))

(defun secret-file-mode-ok-p (path)
  "Return T unless PATH has the world-read bit (#o004) set.
Missing files and unreadable modes return T; group-read is permitted."
  (let ((mode (enchiridion.compat:file-mode path)))
    (or (null mode)
        (zerop (logand mode #o004)))))

(declaim (ftype (function (t) boolean) discard-secrets-file))

(defun discard-secrets-file (path)
  "Unlink PATH and return T only if it equals +CONTAINER-SECRETS-PATH+;
otherwise return NIL without modifying anything. Returns NIL on read-only mounts."
  (when (and path
             (ignore-errors (uiop:pathname-equal path +container-secrets-path+)))
    (ignore-errors (delete-file path) t)))

(defun register-secret (name value &optional (source :argument))
  "Store VALUE under NAME with SOURCE, ignoring empty or non-string values,
and invalidate the cached scrub pattern."
  (when (and (stringp name)
             (stringp value)
             (plusp (length value)))
    (setf (gethash name *loaded-secrets*) value)
    (setf (gethash name *loaded-sources*) source)
    (setf *pattern* nil
          *scanner* nil
          *pattern-stamp* nil))
  name)

(defun parse-env-line (line)
  "Parse one .env LINE into (VALUES NAME VALUE T), or NIL for comments, blanks,
and malformed lines. Strips matching surrounding quotes."
  (let ((text (string-trim '(#\Space #\Tab) line)))
    (when (and (plusp (length text))
               (not (member (char text 0) '(#\# #\;))))
      (let* ((body (if (and (>= (length text) 7)
                            (string= "export " text :end2 7))
                       (string-trim '(#\Space #\Tab) (subseq text 7))
                       text))
             (split (position #\= body)))
        (when split
          (let ((name (string-trim '(#\Space #\Tab) (subseq body 0 split)))
                (value (string-trim '(#\Space #\Tab) (subseq body (1+ split)))))
            (when (and (plusp (length name)) (plusp (length value)))
              (when (and (>= (length value) 2)
                         (member (char value 0) '(#\" #\'))
                         (char= (char value 0) (char value (1- (length value)))))
                (setf value (subseq value 1 (1- (length value)))))
              (values name value t))))))))

(defun load-secrets-from (stream)
  "Load all valid NAME=VALUE pairs from STREAM, skipping malformed lines,
and return the names read."
  (let ((names '()))
    (loop for line = (read-line stream nil nil)
          while line
          do (multiple-value-bind (name value present) (parse-env-line line)
               (when present
                 (register-secret name value :file)
                 (push name names))))
    (nreverse names)))

(defun load-secrets (&key (path nil) (names '()))
  "Load secrets from PATH and from NAMED environment variables.
Returns sorted secret names; callers are responsible for unsetting env vars."
  (when path
    (with-open-file (stream path :direction :input
                              :external-format :utf-8
                              :if-does-not-exist :error)
      ;; Capture path and mode while open, before callers unlink the container copy.
      (setf *secrets-file-read* (pathname path)
            *secrets-file-mode-read* (enchiridion.compat:file-mode path))
      (load-secrets-from stream)))
  (dolist (name names)
    (let ((value (uiop:getenv name)))
      (when (and value (plusp (length value)))
        (register-secret name value :env))))
  (secret-names))

;;;; Scrubbing.

(declaim (ftype (function () (or null string)) pattern))

(defun pattern ()
  "Return the combined scrub regex, rebuilding when the secret count changes.
Literals are sorted longest-first before shape patterns."
  (let ((count (hash-table-count *loaded-secrets*)))
    (unless (and *pattern* (eql count *pattern-stamp*))
      (let* ((literals (sort
                        (loop for value being the hash-values of *loaded-secrets*
                              when (and (stringp value)
                                        (>= (length value) *minimum-secret-length*))
                                collect (quote-meta-chars value))
                        #'> :key #'length))
             (parts (append literals +shape-patterns+))
             (text nil)
             (scanner nil))
        ;; Join with | between parts only; a trailing | makes cl-ppcre reject an empty branch.
        (setf text (with-output-to-string (stream)
                     (write-string "(?:" stream)
                     (loop for part in parts
                           for first = t then nil
                           do (unless first
                                (write-string "|" stream))
                              (write-string part stream))
                     (write-string ")" stream))
              scanner (create-scanner text))
        ;; Publish *scanner* before *pattern* and *pattern-stamp* for concurrent readers.
        (setf *scanner* scanner
              *pattern* text
              *pattern-stamp* count)))
    *pattern*))

(defun scrubber ()
  "Return the compiled scrub scanner, looping if a concurrent REGISTER-SECRET
clears *SCANNER* between rebuild and read."
  (loop
    (pattern)
    (let ((scanner *scanner*))
      (when scanner
        (return scanner)))))

(defun scrub (text)
  "Replace every loaded secret and credential shape in TEXT with +REDACTION-MARKER+.
Returns non-strings unchanged."
  ;; cl-ppcre treats replacement as a template; +redaction-marker+ contains no backslashes.
  (if (not (stringp text))
      text
      (let ((scanner (scrubber)))
        (if (and scanner (not (sealed-p)))
            (regex-replace-all scanner text +redaction-marker+)
            text))))

(defun normalise-field-name (name)
  "Return NAME (symbol or string) lowercased with hyphens replaced by underscores.
Checks SYMBOLP explicitly so SBCL does not infer NAME as SYMBOL."
  (let ((text (if (symbolp name) (symbol-name name) (string-upcase name))))
    (string-downcase (substitute #\_ #\- text))))

(defun role-name-p (name)
  "Return T when field NAME (symbol or string) matches +ROLE-NAMES+ or
+ROLE-SUFFIXES+. Compares normalised strings without interning."
  (when (or (symbolp name) (stringp name))
    (let ((wanted (normalise-field-name name)))
      (or (some (lambda (entry) (string= wanted (normalise-field-name entry)))
                +role-names+)
          (some (lambda (suffix) (string-ends-with-p wanted suffix))
                +role-suffixes+)))))

(defun scrub-object (object)
  "Recursively scrub all strings (including keys) in OBJECT."
  (typecase object
    (string (scrub object))
    (cons (cons (scrub-object (car object)) (scrub-object (cdr object))))
    (vector (map 'vector #'scrub-object object))
    (hash-table (let ((copy (make-hash-table :test #'equal)))
                  (maphash (lambda (key value)
                             (setf (gethash (scrub-object key) copy)
                                   (scrub-object value)))
                           object)
                  copy))
    (t object)))

(defun scrub-tree (object)
  "Recursively scrub OBJECT and replace values of credential-named fields
(ROLE-NAME-P) with +REDACTION-MARKER+."
  (typecase object
    (string (scrub object))
    (cons (let ((head (car object))
                (tail (cdr object)))
            (cond
              ((and (consp tail) (or (symbolp head) (stringp head)))
               (cons (scrub head)
                     (cons (if (role-name-p head)
                               +redaction-marker+
                               (scrub-tree (car tail)))
                           (scrub-tree (cdr tail)))))
              ((and tail (atom tail) (role-name-p head))
               (cons (scrub head) +redaction-marker+))
              (t (cons (scrub-tree head) (scrub-tree tail))))))
    (vector (map 'vector #'scrub-tree object))
    (hash-table
     (let ((copy (make-hash-table :test (hash-table-test object))))
       (maphash (lambda (key value)
                  (setf (gethash (scrub-object key) copy)
                        (if (role-name-p key)
                            +redaction-marker+
                            (scrub-tree value))))
                object)
       copy))
    (t object)))

(setf enchiridion.log:*scrubber* #'scrub)
