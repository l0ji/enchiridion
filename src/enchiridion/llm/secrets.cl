;;;; secrets.cl --- Load .env, and scrub every secret back out of text.
;;;;
;;;; Secrets that reach the context window are gone. They are sent to a
;;;; third party API and stored in that provider's logs. That leak is what
;;;; actually burns operators, and it is not a permissions problem, so no
;;;; amount of uid separation fixes it. This file scrubs a secret out of text
;;;; before that text is stored or sent.
;;;;
;;;; Three filters:
;;;;
;;;;   Literal  any loaded value, at least *minimum-secret-length* long
;;;;   Shape    Bearer tokens, sk- keys, ghp_ tokens, xox tokens, JWTs, and
;;;;            key=value pairs that name a credential
;;;;   Role     any field named token, secret, password, or api_key
;;;;
;;;; Literal and Shape match strings. Role matches fields, and is the filter
;;;; that catches a credential this process never loaded: the prompt
;;;; injection case. A hit becomes [redacted]. One regular expression per
;;;; string, and zero tokens.

;; The package is declared in packages.cl, and only there. A second defpackage
;; for the same name leaves two export lists to drift, and the one in the
;; second file silently wins.

(in-package #:enchiridion.llm.secrets)

;;;; What is held.
;;;;
;;;; A hash table of values, because scrubbing is on the hot path and scanning
;;;; a list per string would be quadratic in the number of secrets.

(defparameter *loaded-secrets*
  (make-hash-table :test #'equal)
  "Name to value for every secret this process has loaded. Values live here
and nowhere else.")

(defparameter *loaded-sources*
  (make-hash-table :test #'equal)
  "Name to a one word note saying where the value came from, so that
`enchiridion secrets` can print names and sources without printing a value.")

(defparameter *secrets-file-read*
  nil
  "The pathname the loader opened, or NIL when it opened none.

Remembered rather than resolved again, because the container copy is unlinked
the moment its values are in memory: by the time an operator asks where the
secrets came from, that file is gone, and a second resolution answers with the
host fallback instead and calls it absent. The one process that can name the
file is the one that opened it.")

(defparameter *secrets-file-mode-read*
  nil
  "The mode *SECRETS-FILE-READ* had when the loader opened it, or NIL when the
loader opened no file.

Remembered for the same reason the path is, and a mode read back later is not
the same answer: the file may be unlinked by then, and the question the line
answers is what the permissions were at the moment its values were read.")

(defparameter *minimum-secret-length*
  8
  "A loaded value shorter than this is not scrubbed by the literal filter.
Without a floor a one character secret turns almost every string in the
transcript into [redacted] and the agent becomes useless. Real keys are far
longer than eight characters.")

(defparameter *sealed*
  nil
  "When true the scrubber stops replacing anything. Only a test that
deliberately re-reads a value ever wants this.")

(defparameter +redaction-marker+
  "[redacted]"
  "What a scrubbed value becomes. A model that sees its own text change needs
to know something was removed without learning what.")

(defparameter +shape-patterns+
  ;; \s and not [[:space:]]. The cl-ppcre in this nixpkgs reads a POSIX class
  ;; as an ordinary bracket expression that never matches a space, so a Bearer
  ;; token and every key=value pair sailed through the scrubber untouched.
  ;; \s matches, and it means the same thing.
  ;;
  ;; The closing parenthesis in the first pattern is escaped, and that is not
  ;; decoration either. cl-ppcre reads a bare ) inside a bracket expression as
  ;; the end of the enclosing group, so the scanner fails to build and every
  ;; call to scrub signals a regex error instead of removing anything.
  '("Bearer\\s+[^\\s\"',;\\)}]+"
    "sk-[A-Za-z0-9_\\-]{8,}"
    "gh[pousr]_[A-Za-z0-9]{16,}"
    "xox[baprs]-[A-Za-z0-9\\-]{8,}"
    "eyJ[A-Za-z0-9_\\-]{8,}\\.[A-Za-z0-9_\\-]{4,}\\.[A-Za-z0-9_\\-]*"
    "(?i)(?:api[_-]?key|apikey|access[_-]?token|auth[_-]?token|refresh[_-]?token|token|secret|password|passwd|private[_-]?key)\\s*[=:]\\s*[\"']?[A-Za-z0-9_\\-./+=]{6,}")
  "Shapes that are a secret whatever their value is. Strings rather than
scanners, so that one combined scanner can be built once and cached.")

(defparameter +role-names+
  '(:token :secret :password :api-key :api_key :apikey :api_secret :credentials
    :access-token :refresh-token :auth-token :private-key :authorization)
  "Field names whose value is scrubbed whatever the value looks like. This is
the filter that catches a secret nobody loaded.")

(defparameter *pattern*
  nil
  "The combined scrub pattern. NIL means it has not been built.")

(defparameter *scanner*
  nil
  "The compiled scanner for *pattern*.")

(defparameter *pattern-stamp*
  nil
  "How many secrets *pattern* was built for, so that it is rebuilt when the
set changes and not on every call.")

;;;; Accessors.

(defun secret-present-p (name)
  "Return T when a secret called NAME has been loaded."
  (and (stringp name)
       (not (null (gethash name *loaded-secrets*)))))

(defun secret-value (name)
  "Return the value of the secret called NAME, or NIL. Callers other than the
scrubber and the tests have no business calling this."
  (gethash name *loaded-secrets*))

(defun secret-source (name)
  "Return where the secret called NAME came from: :env, :file, or :argument."
  (gethash name *loaded-sources*))

(defun secret-names ()
  "Return every loaded secret name, sorted. This is what `enchiridion secrets`
prints, with the source and never the value."
  (sort (loop for name being the hash-keys of *loaded-secrets*
               collect name)
        #'string<))

(declaim (ftype (function () (or null pathname)) secrets-file-read))

(defun secrets-file-read ()
  "Return the secret file the loader opened, or NIL when it opened none.

A report about that file cannot be a fresh lookup of a file that was never
there. The container copy is unlinked once its values are in memory, so a lookup
after the load finds the host fallback and calls it absent while the file that
was actually read goes unnamed. This accessor is the memory that lets the line
whose whole job is to report that the container copy is gone name the file it
is about."
  *secrets-file-read*)

(declaim (ftype (function () (or null (integer 0 #o777))) secrets-file-mode-read))

(defun secrets-file-mode-read ()
  "Return the permission bits *SECRETS-FILE-READ* had when the loader opened it,
or NIL when the loader opened no file.

Reading the mode again rather than remembering it answers NIL after the unlink,
which is the same answer as a file that never existed. The mode that matters is
the one the file had while its values were being read, and only this process
was there to see it."
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
  "Forget every loaded secret and rebuild nothing. For tests, and for nothing
else."
  (clrhash *loaded-secrets*)
  (clrhash *loaded-sources*)
  (setf *secrets-file-read* nil
        *secrets-file-mode-read* nil
        *pattern* nil
        *scanner* nil
        *pattern-stamp* nil)
  nil)

;;;; Credential names.
;;;;
;;;; The supervisor loads the secrets and then has to take the names back out of
;;;; its own environment, or every child it starts inherits the values. Which
;;;; names is a decision this file owns, because this file is the one that knows
;;;; what a credential is called. It is a decision about names only: no value is
;;;; read here, so nothing can leak through a mistake in the predicate.

(defparameter +credential-name-tokens+
  '("_API_KEY" "_APIKEY" "_TOKEN" "_SECRET" "_PASSWORD" "_PASSWD" "_PRIVATE_KEY")
  "Name fragments that make an environment variable a credential whatever its
value looks like. Matching anywhere in the name and not only at the end is
deliberate: the deployed tooling spells credentials like AWS_SECRET_ACCESS_KEY
and GITHUB_TOKEN, and in the first the credential word is not the last segment.
The leading underscore is what keeps ordinary prose out, so PASSWORD_ROUNDS is
not swept because no underscore delimits the fragment at the front, while
MAX_TOKEN_SIZE is swept because it names a token segment. That last one is the
cost of catching a credential whose name does not end in the credential word,
and the cost is one variable the child process did not need.")

(defparameter +credential-variable-names+
  '("OPENAI_API_KEY" "OPENCODE_API_KEY" "ANTHROPIC_API_KEY"
    "FLUXER_BOT_TOKEN" "ENCHIRIDION_HTTP_TOKEN")
  "The names the shipped configuration reads, listed outright even though every
one of them already matches a token above. This list is the belt to that
braces: if a token is ever edited out of +CREDENTIAL-NAME-TOKENS+, the names
this build actually uses still leave the environment, and the coverage of the
shipped configuration is a thing a reader can see rather than a thing a reader
has to derive.")

(declaim (ftype (function (t) boolean) credential-variable-p))

(defun credential-variable-p (name)
  "Return T when NAME is the name of an environment variable that holds a
credential, and NIL when it is not. The comparison is case-insensitive:
environment variables are conventionally upper case, an operator's .env is
written however the operator writes it, and a name that is credential shaped is
credential shaped in any case.

The NIL cases matter as much as the T ones. PATH, HOME, TERM, LANG, TMPDIR,
USER, LOGNAME, and SBCL_HOME are what the child process needs to run at all;
CL_SOURCE_REGISTRY, ENCHIRIDION_SOURCE, ENCHIRIDION_SBCL, the LD_ and DYLD_
loader paths, and every XDG_ name point at files the child still has to find.
A predicate that swept those would stop the agent instead of protecting it, so
it errs on the side of the exact name and never on the side of a prefix:
ENCHIRIDION_HTTP_TOKEN is a credential and ENCHIRIDION_SOURCE is not, and no
rule about ENCHIRIDION_ tells the two apart.

A non string, and the empty string, are NIL. The environment reader hands over
strings, and a name that is not a string is a caller's mistake rather than a
credential."
  (and (stringp name)
       (plusp (length name))
       (let ((wanted (string-upcase name)))
         (not (null (or (member wanted +credential-variable-names+
                                :test #'string=)
                        (some (lambda (token) (search token wanted))
                              +credential-name-tokens+)
                        (search "AUTHORIZATION" wanted)))))))

;;;; Loading.
;;;;
;;;; One place reads a secret. Everything else calls scrub, so there is one
;;;; thing to audit.

(defparameter +container-secrets-path+
  #p"/run/secrets/.env"
  "Where a container keeps its secret file: a tmpfs mount, never a layer of the
image, holding the operator's .env for exactly as long as it takes the
supervisor to read it. DISCARD-SECRETS-FILE unlinks exactly this path and
refuses every other, so the operator's checkout .env cannot be deleted by a
mistake at a call site.

A DEFPARAMETER and not a DEFCONSTANT, which is the one place in this file where
the choice is load bearing. The test suite has to point this at a scratch file,
because a nix build sandbox has no /run/secrets it may write, and SBCL folds a
DEFCONSTANT reference into the compiled code: a binding around the call would be
silently ignored, the refusal branch would be the only branch ever exercised,
and the delete branch would ship untested.")

(defun host-secrets-file (directory)
  "Return the .env path inside DIRECTORY. DIRECTORY is a directory pathname
or a namestring; a file pathname is not accepted because .env is always a
sibling of the code, never the code itself."
  (merge-pathnames ".env" (uiop:ensure-directory-pathname directory)))

(defun secrets-file (&key (directories (list #p"./"))
                            (container +container-secrets-path+))
  "Return the secret file to read. The container tmpfs wins when it exists,
because the host .env is never copied in at its own path: the run script puts
it at /run/secrets/.env and the supervisor deletes it once loaded.

DIRECTORIES is tried in order for a host .env, which is how `enchiridion ask`
finds the operator's file when the binary lives in a store path. The first
directory is the fallback when no file exists, so the caller can still tell
the operator which path it would have read. CONTAINER is nil in tests, so the
host lookup is not at the mercy of a /run/secrets that happens to exist; its
default is +CONTAINER-SECRETS-PATH+, read at call time, which is the other half
of why that name is a variable and not a constant."
  (or (and container (probe-file container))
      (loop for directory in directories
            for path = (host-secrets-file directory)
            when (probe-file path)
              return path)
      (host-secrets-file (or (first directories) #p"./"))))

(declaim (ftype (function () pathname) operator-secrets-file))

(defun operator-secrets-file ()
  "Return the .env the operator means, resolved the one way for every caller.

The current directory comes first, because that is where the operator stands
and where a checkout keeps .env, and `nix run` executes a script in the store
while the operator stands in the checkout. The source root comes second,
because the installed copy is the other place the file can live and the store
path has no checkout above it.

A NIL root is dropped rather than left in the list. PROJECT-ROOT answers NIL
outside a checkout, HOST-SECRETS-FILE takes a directory, and NIL is not one:
`uiop:ensure-directory-pathname` signals on it, so leaving it in the list turns
the case of no .env anywhere into a type error in the one command that exists to
report where the file would have been.

This is the one place that decides which .env the operator means. The loader in
src/main.cl and the `secrets` command both call it, so the file that is read
and the file that is reported cannot drift into two different files."
  (the pathname
       (secrets-file :directories (remove nil
                                          (list (uiop:getcwd)
                                                (enchiridion:project-root))))))

(declaim (ftype (function (t) boolean) secret-file-mode-ok-p))

(defun secret-file-mode-ok-p (path)
  "Return T when the secret file at PATH is one a supervisor may read.

The whole rule is one bit: NIL when the world read bit is set, T otherwise. An
absent file passes, because a missing file is not a leak: the loader complains
about the file it could not find on its own, in its own words. A mode that
cannot be read passes, which is what a build without stat reports.

The group bit is the deliberate part. The check exists because a secret file
readable by the world is a file that every uid in the container can read, and
the world read bit is the only bit that says so. Group readability is how a
normal deployment shares a file with a service account, refusing it would break
those deployments, and it would not close the other direction: the supervisor
already runs as the owner. So NIL is reserved for one condition and no other,
(logand mode #o004) not zero, and the docstring says so rather than leaving a
reader to infer it."
  (let ((mode (enchiridion.compat:file-mode path)))
    (or (null mode)
        (zerop (logand mode #o004)))))

(declaim (ftype (function (t) boolean) discard-secrets-file))

(defun discard-secrets-file (path)
  "Unlink PATH and return T, but only when PATH is +CONTAINER-SECRETS-PATH+;
return NIL and leave the file alone for every other path.

The container copy exists so the supervisor can read it once. It is gone at
steady state, and that invariant is kept by unlinking it as soon as its values
are in memory, so that no process that later gains access to the container
finds the rest of the operator's .env sitting on a tmpfs.

The operator's checkout .env is NEVER deleted. It is the file the operator
edits, it is not the container copy, and it is exactly the file a quiet delete
would destroy. The comparison against the container path is what stops that,
which is why this function takes a path and decides for itself instead of
deleting whatever its caller passes.

A read-only bind mount refuses the unlink, and a read-only mount is a normal
deployment rather than a fault. The caller has to print something either way,
so this answers NIL and lets the caller choose the words instead of signalling
a condition the caller would only catch in order to print anyway."
  (when (and path
             (ignore-errors (uiop:pathname-equal path +container-secrets-path+)))
    (ignore-errors (delete-file path) t)))

(defun register-secret (name value &optional (source :argument))
  "Hold VALUE under NAME, noting SOURCE. An empty or non string value is
ignored rather than stored, because a value the scrubber cannot use is worse
than no value at all."
  (when (and (stringp name)
             (stringp value)
             (plusp (length value)))
    (setf (gethash name *loaded-secrets*) value)
    (setf (gethash name *loaded-sources*) source)
    ;; A new secret changes the pattern, so the stamp is cleared here rather
    ;; than at the next call, which keeps scrub free of a comparison it does
    ;; not need on the hot path.
    (setf *pattern* nil
          *scanner* nil
          *pattern-stamp* nil))
  name)

(defun parse-env-line (line)
  "Return NAME, VALUE, and T for one .env LINE. Return NIL for a comment, a
blank line, and a malformed line. Surrounding quotes on the value are
removed, because a quote is shell syntax and not part of the key."
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
  "Hold every NAME=VALUE pair from STREAM. Return the names read. A malformed
line is skipped rather than signalled: a typo in .env should not stop the
agent from starting with the secrets that are correct."
  (let ((names '()))
    (loop for line = (read-line stream nil nil)
          while line
          do (multiple-value-bind (name value present) (parse-env-line line)
               (when present
                 (register-secret name value :file)
                 (push name names))))
    (nreverse names)))

(defun load-secrets (&key (path nil) (names '()))
  "Hold the secrets at PATH and the named environment variables. Return the
names loaded. The caller is expected to unset them from its own environment
afterwards, which is the step that stops the broker inheriting them."
  (when path
    (with-open-file (stream path :direction :input
                              :external-format :utf-8
                              :if-does-not-exist :error)
      ;; The stream is open, so the file exists, and this is the only moment at
      ;; which it can be named and measured. The caller may unlink it the
      ;; instant this returns, which is exactly what the supervisor does with
      ;; the container copy, and after that a resolution of the path finds
      ;; whatever is next in the search order rather than the file that was
      ;; read.
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
  "Return the combined scrub pattern, rebuilding it when the number of loaded
secrets has changed. Literals come first and longest first so that a short
secret cannot match the head of a longer one and leave the tail behind."
  (let ((count (hash-table-count *loaded-secrets*)))
    (unless (and *pattern* (eql count *pattern-stamp*))
      (let* ((literals (sort
                        (loop for value being the hash-values of *loaded-secrets*
                              when (and (stringp value)
                                        (>= (length value) *minimum-secret-length*))
                                collect (quote-meta-chars value))
                        #'> :key #'length))
             (parts (append literals +shape-patterns+)))
        ;; A separator BETWEEN the parts, never one after the last. Writing
        ;; "part then |" in a loop leaves the alternation ending on an empty
        ;; branch, and cl-ppcre refuses to compile that: the scanner never
        ;; builds and every call to scrub signals a regex error instead of
        ;; removing anything.
        (setf *pattern* (with-output-to-string (stream)
                          (write-string "(?:" stream)
                          (loop for part in parts
                                for first = t then nil
                                do (unless first
                                     (write-string "|" stream))
                                   (write-string part stream))
                          (write-string ")" stream))
              *scanner* (create-scanner *pattern*)
              *pattern-stamp* count)))
    *pattern*))

(defun scrubber ()
  "Return the compiled scanner. There is always one, because the shape
patterns exist even when nothing has been loaded: a key this process never
saw is still a key."
  (pattern)
  *scanner*)

(defun scrub (text)
  "Return TEXT with every loaded secret and every known secret shape replaced
by the redaction marker. A non string comes back unchanged, because a
scrubber that itself signals takes the agent down with it."
  ;; No :literal here. This version of cl-ppcre has no such keyword, and the
  ;; replacement is a template in which backslash N means the Nth match. The
  ;; marker holds no backslash, so it is inserted as written.
  (if (not (stringp text))
      text
      (let ((scanner (scrubber)))
        (if (and scanner (not (sealed-p)))
            (regex-replace-all scanner text +redaction-marker+)
            text))))

(defun normalise-field-name (name)
  "Return NAME as a lower case string with hyphens written as underscores, so
that :access-token, \"access-token\", and :ACCESS_TOKEN are one name.

The SYMBOLP test is not a nicety. SYMBOL-NAME takes a symbol: hand it a string
and SBCL, which infers the parameter type from the call, turns the whole
parameter into a SYMBOL and then refuses every string field name at the
safety check on entry. A JSON tool result keys its fields with strings, which
is the case this function exists for."
  (let ((text (if (symbolp name) (symbol-name name) (string-upcase name))))
    (string-downcase (substitute #\_ #\- text))))

(defun role-name-p (name)
  "Return T when NAME, a symbol or a string, names a field that holds a
credential whatever its value looks like.

Both sides are compared as normalised strings, and neither is interned. Intern
was the obvious way to compare a symbol against a list of keywords, and it
does not work here: (INTERN \"token\" :keyword) reads the second argument as
the string \"token\" and comes back with a symbol that matches nothing, so every
role check answered nil and the prompt injection case this filter exists for
went uncaught."
  (when (or (symbolp name) (stringp name))
    (let ((wanted (normalise-field-name name)))
      (some (lambda (entry) (string= wanted (normalise-field-name entry)))
            +role-names+))))

(defun scrub-object (object)
  "Return OBJECT with every string inside it scrubbed. Keys are scrubbed too,
because a key is text and text can hold a key."
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
  "Return OBJECT with every string scrubbed and every credential named field
replaced outright. This is the filter for data that arrived as JSON or as a
tool result: a field named token holds a token even when this process never
loaded it, which is the prompt injection case the literal filter misses."
  (typecase object
    (string (scrub object))
    (cons (let ((head (car object))
                (tail (cdr object)))
            (if (and (consp tail)
                     (role-name-p head)
                     (stringp (car tail)))
                ;; The name stays, so the caller can still see that a token
                ;; was there and that it was removed.
                (cons head (cons +redaction-marker+ (cdr tail)))
                (cons (scrub-tree head) (scrub-tree tail)))))
    (vector (map 'vector #'scrub-tree object))
    (t object)))