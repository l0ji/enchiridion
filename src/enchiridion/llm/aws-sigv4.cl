;;;; aws-sigv4.cl --- AWS Signature Version 4, over an HTTP request.
;;;;
;;;; Bedrock is the only AWS service this tree speaks to, and every request to
;;;; it has to be signed. Nothing about the signature is negotiated: a canonical
;;;; request is built from the method, the path, the query, the headers and the
;;;; hash of the body; that text is hashed into a string to sign; and a key
;;;; derived from the secret signs it. Every step here is a pure function of
;;;; text, which is the only reason a signature can be checked against AWS's own
;;;; published vectors without a socket and without a key.
;;;;
;;;; The request shape is not this file's business. SIGN-REQUEST reads an
;;;; HTTP-REQUEST and returns a new header list; the vendor handler decides the
;;;; URL, the region, the service and the body. The signed scheme is registered
;;;; under :AWS-SIGV4, so a dialect-driven handler reaches it through AUTH-APPLY
;;;; and this file never learns which handler called it.
;;;;
;;;; Being strict is deliberate. A missing credential raises instead of signing
;;;; with the empty string: a request signed with no key comes back a 403 that
;;;; names neither the key nor the field, and the operator is left guessing
;;;; which of several environment variables was the wrong one.

(in-package #:enchiridion.llm)

;;;; Credentials.
;;;;
;;;; A credential is a value and not three specials, because the signer must be
;;;; able to sign with a credential somebody else resolved: the Bedrock handler
;;;; resolves one per request, and a test injects one directly.

;; The session token is genuinely absent when there is none. An empty string
;; would be signed as an x-amz-security-token header whose value is nothing,
;; and AWS reads that as a malformed request rather than as no token at all.
(defstruct (aws-credential (:constructor %make-aws-credential))
  (:access-key "" :type string)
  (:secret-key "" :type string)
  (:session-token nil :type (or null string)))

(declaim (ftype (function (&key (:access-key t) (:secret-key t) (:session-token t))
                          aws-credential)
                make-aws-credential))

(defun make-aws-credential (&key access-key secret-key session-token)
  "Return an AWS credential holding ACCESS-KEY, SECRET-KEY and SESSION-TOKEN.

A missing key becomes the empty string, which AWS-CREDENTIAL-USABLE-P then
refuses: the value exists so that a half configured operator gets a
CONFIGURATION-ERROR naming :AWS-CREDENTIALS, and not a type error about a slot
that was handed NIL."
  (%make-aws-credential :access-key (or access-key "")
                        :secret-key (or secret-key "")
                        :session-token session-token))

(declaim (ftype (function (t) (or null string)) aws-nonempty-string))

(defun aws-nonempty-string (value)
  "Return VALUE when it is a string with at least one character, else NIL.

A variable that is set to the empty string is set and says nothing, which is
the same fact as an unset one here. Every reader below funnels through this so
that the two spellings of absence cannot disagree."
  (and (stringp value) (plusp (length value)) value))

(declaim (ftype (function (string) (or null string)) secret-or-environment))

(defun secret-or-environment (name)
  "Return NAME's value from the secret store, then from the environment.

The secret store wins because it holds what the loader read from the operator's
file. An exported variable is the weaker statement of the same fact, and a
stale export must not override the file the operator edits."
  (or (aws-nonempty-string (enchiridion.llm.secrets:secret-value name))
      (aws-nonempty-string (enchiridion.compat:environment-value name))))

(declaim (ftype (function (&key (:access-key t) (:secret-key t) (:session-token t))
                          (or null aws-credential))
                aws-credentials))

(defun aws-credentials (&key access-key secret-key session-token)
  "Return the AWS credentials available to sign with, or NIL when there are none.

An explicit argument wins over everything: the caller that passes one has
already decided. The names are the three every AWS toolchain reads.

Half a credential is not a credential and answers NIL rather than a struct
whose signature would be wrong. The caller that needs one says so with an error
that names the key, and that error is the point: it is the only place in the
system that can tell an operator which of the three variables was missing."
  (let ((access (or (aws-nonempty-string access-key)
                    (secret-or-environment "AWS_ACCESS_KEY_ID")))
        (secret (or (aws-nonempty-string secret-key)
                    (secret-or-environment "AWS_SECRET_ACCESS_KEY")))
        (token (or (aws-nonempty-string session-token)
                   (secret-or-environment "AWS_SESSION_TOKEN"))))
    (when (and access secret)
      (make-aws-credential :access-key access :secret-key secret
                           :session-token token))))

(declaim (type (or null function) *aws-credentials-function*))

(defparameter *aws-credentials-function* #'aws-credentials
  "The function SIGN-REQUEST asks for credentials when it is given none.

Bound in tests to a constant, so a signature is never a function of the
operator's own environment. NIL means no resolver at all, which is how a test
says 'signing must fail here'.")

(declaim (ftype (function () (or null aws-credential)) resolve-aws-credentials))

(defun resolve-aws-credentials ()
  "Return the credential *AWS-CREDENTIALS-FUNCTION* answers, or NIL.

The special is copied into a local before it is called because a special
variable is not narrowed by SBCL's flow analysis: FUNCALL on a perhaps-NIL
special is a warning waiting to happen, and this system makes a warning an
error."
  (let ((resolver *aws-credentials-function*))
    (if (functionp resolver) (funcall resolver) nil)))

(declaim (ftype (function (t) boolean) aws-credential-usable-p))

(defun aws-credential-usable-p (credentials)
  "Return T when CREDENTIALS can sign: an access key and a secret key."
  (and (aws-credential-p credentials)
       (not (null (aws-nonempty-string (aws-credential-access-key credentials))))
       (not (null (aws-nonempty-string (aws-credential-secret-key credentials))))))

(declaim (ftype (function () boolean) aws-credentials-available-p))

(defun aws-credentials-available-p ()
  "Return T when this process has AWS credentials to sign a request with.

The Bedrock handler asks before it chooses between a bearer token and a
signature: a provider key is a bearer token only while there is no access key
to sign with."
  (aws-credential-usable-p (resolve-aws-credentials)))

;;;; Octets, hex and hashing.
;;;;
;;;; IRONCLAD takes octets and answers octets. Text reaches it through
;;;; COMPAT:ENCODE-UTF8 and not through an ironclad string convenience, because
;;;; the body hash has to be the hash of the bytes that go on the wire: a body
;;;; with one non-ASCII character hashes differently under UTF-8 and Latin-1,
;;;; and the service compares its own hash of what it received.

(declaim (ftype (function (string) vector) aws-string-octets))

(defun aws-string-octets (text)
  "Return TEXT as the UTF-8 octets the wire will carry."
  (enchiridion.compat:encode-utf8 text))

(declaim (ftype (function (vector) string) aws-hex))

(defun aws-hex (octets)
  "Return OCTETS as lowercase hexadecimal text.

Lowercase, because AWS's published signatures are lowercase and a signature
that differs only in case is a signature that differs."
  (string-downcase (format nil "~{~2,'0X~}" (coerce octets 'list))))

(declaim (ftype (function (vector) vector) aws-sha256))

(defun aws-sha256 (octets)
  "Return the SHA-256 digest of OCTETS."
  (ironclad:digest-sequence :sha256 octets))

(declaim (ftype (function (vector vector) vector) aws-hmac))

(defun aws-hmac (key message)
  "Return HMAC-SHA256 of MESSAGE under KEY, both as octets."
  (ironclad:hmac-digest
   (ironclad:update-hmac (ironclad:make-hmac key :sha256) message)))

(declaim (ftype (function (t) string) aws-sha256-hex))

(defun aws-sha256-hex (text)
  "Return the lowercase hex SHA-256 of TEXT.

One function for the two places a hash is written down: the x-amz-content-sha256
header and the last line of the canonical request are the same number, and a
signature built from two different spellings of it is refused."
  (aws-hex (aws-sha256 (aws-string-octets (or text "")))))

;;;; Percent-encoding.
;;;;
;;;; The canonical query string is built from the bytes of each parameter and
;;;; not from re-encoded text: a value that arrived already encoded is decoded
;;;; to bytes and encoded again, so %2F stays %2F and a raw space becomes %20.
;;;; Encoding a decoded string instead would need a second string, and one for
;;;; every multi-byte character in it.

(declaim (ftype (function (vector) string) aws-encode-octets))

(defun aws-encode-octets (octets)
  "Return OCTETS percent-encoded the way SigV4 wants them.

The unreserved set is A-Z, a-z, 0-9, hyphen, underscore, dot and tilde. Every
other byte becomes an uppercase %XY, including the space, which AWS requires to
be %20 and not a plus: a plus is a legal character in a query value and would
be re-encoded as %2B, so using one for a space is a signature mismatch."
  (with-output-to-string (out)
    (loop for byte across octets
          do (if (or (<= 65 byte 90) (<= 97 byte 122) (<= 48 byte 57)
                     (member byte '(45 46 95 126)))
                 (write-char (code-char byte) out)
                 (format out "%~2,'0X" byte)))))

(declaim (ftype (function (string) string) aws-uri-encode))

(defun aws-uri-encode (text)
  "Return TEXT percent-encoded, as a URL path segment or query value wants it."
  (aws-encode-octets (aws-string-octets text)))

(declaim (ftype (function (string) vector) aws-percent-decode))

(defun aws-percent-decode (text)
  "Return TEXT with every %XY sequence replaced by its byte, as octets.

A character that is not part of an escape is encoded to its own UTF-8 bytes, so
a query value that is half encoded, half raw, still canonicalises to the bytes
the service will see. A percent sign that is not followed by two hexadecimal
digits is a literal percent sign and not an error: the input is a URL somebody
else built, and a URL with a stray % is a URL with a stray %."
  (let ((octets (make-array (length text) :element-type '(unsigned-byte 8)
                                          :fill-pointer 0)))
    (loop with index = 0
          while (< index (length text))
          for character = (char text index)
          do (if (and (char= character #\%)
                      (< (+ index 2) (length text))
                      (digit-char-p (char text (1+ index)) 16)
                      (digit-char-p (char text (+ index 2)) 16))
                 (progn
                   (vector-push (parse-integer text :start (1+ index)
                                                    :end (+ index 3)
                                                    :radix 16)
                                octets)
                   (incf index 3))
                 (progn
                   (loop for byte across (aws-string-octets (string character))
                         do (vector-push byte octets))
                   (incf index))))
    octets))

(declaim (ftype (function (character string) list) aws-split))

(defun aws-split (delimiter text)
  "Return TEXT split at every DELIMITER, as a list of strings.

An empty field is kept rather than dropped: the caller decides whether an empty
query parameter or an empty model name means anything, and a splitter that
silently removes one cannot tell the two apart."
  (let ((parts '())
        (start 0))
    (loop for position = (position delimiter text :start start)
          while position
          do (push (subseq text start position) parts)
             (setf start (1+ position)))
    (push (subseq text start) parts)
    (nreverse parts)))

;;;; The clock.
;;;;
;;;; SigV4 signs the moment of the request, so the signature expires with it. A
;;;; universal time is the argument and the special is the default, which is what
;;;; lets the published vectors be reproduced exactly.

(declaim (type (or null integer) *signing-time*))

(defparameter *signing-time* nil
  "The universal time SIGN-REQUEST signs with. NIL means the wall clock.

Bound in tests: a signature over the current second cannot be compared with a
vector, and a test that waits for a particular second is a test that fails on
the second attempt.")

(declaim (ftype (function (integer) (values string string)) aws-timestamp))

(defun aws-timestamp (universal-time)
  "Return UNIVERSAL-TIME as the two timestamps SigV4 needs.

The first value is the ISO 8601 basic format the x-amz-date header and the
string to sign carry, 20150830T123600Z. The second is the date, the first eight
characters of it, which starts the scope. Both are UTC: a signature is not a
local time, and a zone offset would change the characters that are signed."
  (multiple-value-bind (second minute hour day month year)
      (decode-universal-time universal-time 0)
    (let ((stamp (format nil "~4,'0D~2,'0D~2,'0DT~2,'0D~2,'0D~2,'0DZ"
                         year month day hour minute second)))
      (values stamp (subseq stamp 0 8)))))

;;;; The URL.
;;;;
;;;; The host, the path and the query are read out of the URL here rather than
;;;; kept beside it, because the URL is what the transport will send and a
;;;; signature over a second copy of the path is a signature over a copy that
;;;; can drift.

(declaim (ftype (function (string) (values string string string)) aws-url-parts))

(defun aws-url-parts (url)
  "Return URL's host, path and query as three values.

The scheme and any user information are dropped, and a port is kept, because
the Host header is the authority as the client sends it and AWS signs exactly
that. The path is returned as it appears in the URL: it is signed as sent, so a
caller that needs an escaped path escapes it before building the URL.

A URL with no host is a configuration error rather than a signature over an
empty host, which AWS answers with a message about the credential."
  (let* ((scheme (search "://" url))
         (after (if scheme (subseq url (+ scheme 3)) url))
         (cut (or (position-if (lambda (character) (find character "/?#"))
                               after)
                  (length after)))
         (authority (subseq after 0 cut))
         (rest (subseq after cut))
         (user-info (position #\@ authority :from-end t))
         (host (if user-info (subseq authority (1+ user-info)) authority))
         (end (or (position #\# rest) (length rest)))
         (question (position #\? rest :end end))
         (path (subseq rest 0 (or question end)))
         (query (if question (subseq rest (1+ question) end) "")))
    (unless (and (plusp (length host))
                 (not (find #\Space host)))
      (error 'enchiridion.errors:configuration-error
             :key :url
             :detail (format nil "~S has no host to sign for." url)))
    (values host path query)))

(declaim (ftype (function (t) string) aws-canonical-uri))

(defun aws-canonical-uri (path)
  "Return PATH as the canonical URI.

An empty path is the root, and a path is signed exactly as it goes on the wire,
so this adds the leading slash a relative path lacks and re-encodes nothing. A
canonicaliser that encoded here would double-encode a path the caller had
already escaped, and AWS compares the bytes it received with the bytes that were
signed."
  (cond
    ((or (null path) (zerop (length path))) "/")
    ((char= (char path 0) #\/) path)
    (t (concatenate 'string "/" path))))

;;;; The canonical request.
;;;;
;;;; The five pieces are built separately because each has a published vector:
;;;; a header value that was trimmed, a query whose parameters were sorted, a
;;;; body whose hash is the last line. Any one of them wrong produces a
;;;; signature that is wrong in a way no error message explains.

(declaim (ftype (function (t) string) aws-trim-header-value))

(defun aws-trim-header-value (value)
  "Return VALUE with the whitespace AWS removes from a header value.

AWS trims leading and trailing whitespace and collapses an internal run of
whitespace to one space before signing. The collapsing is not cosmetic: a
request whose header value has two spaces in a row is signed over the value
with one, and a signer that only trims produces a signature the service
refuses."
  (let ((text (if (stringp value) value (princ-to-string value))))
    (with-output-to-string (out)
      (let ((pending nil)
            (started nil))
        (loop for character across text
              do (if (member character '(#\Space #\Tab #\Newline #\Return))
                     (setf pending started)
                     (progn
                       (when pending (write-char #\Space out))
                       (setf pending nil
                             started t)
                       (write-char character out))))))))

(declaim (ftype (function (list) list) aws-canonical-header-pairs))

(defun aws-canonical-header-pairs (headers)
  "Return HEADERS as lowercased, trimmed, name-sorted pairs.

Names are lowercased because HTTP header names are case-insensitive and AWS
signs the lowercase spelling with an exact string comparison. Sorting is by the
lowercase name, which is what makes the signed header list and the canonical
header block agree without a second sort."
  (sort (loop for (name . value) in headers
              collect (cons (string-downcase (string name))
                            (aws-trim-header-value value)))
        #'string< :key #'car))

(declaim (ftype (function (t) string) aws-canonical-query-string))

(defun aws-canonical-query-string (query)
  "Return QUERY as the canonical query string, or the empty string.

Each parameter is decoded to bytes and encoded again, sorted by encoded name
and then by encoded value, and joined with &. A parameter with no value keeps
its =, because AWS distinguishes a parameter that has no value from one that is
absent, and the two are not the same request."
  (if (or (null query) (zerop (length query)))
      ""
      (let ((pairs '()))
        (dolist (part (aws-split #\& query))
          (unless (zerop (length part))
            (let* ((equals (position #\= part))
                   (name (aws-encode-octets
                          (aws-percent-decode
                           (if equals (subseq part 0 equals) part))))
                   (value (aws-encode-octets
                           (aws-percent-decode
                            (if equals (subseq part (1+ equals)) "")))))
              (push (cons name value) pairs))))
        (setf pairs (sort pairs
                          (lambda (left right)
                            (let ((left-name (car left))
                                  (right-name (car right)))
                              (cond ((string< left-name right-name) t)
                                    ((string< right-name left-name) nil)
                                    (t (string< (cdr left) (cdr right))))))))
        (format nil "~{~A~^&~}"
                (loop for (name . value) in pairs
                      collect (format nil "~A=~A" name value))))))

(declaim (ftype (function (list) string) aws-canonical-headers))

(defun aws-canonical-headers (pairs)
  "Return the canonical header block for PAIRS, ending in a newline.

The trailing newline is part of the block: the canonical request separates the
headers from the signed header list with an empty line, and splitting on lines
without it is where a hand written signer usually goes wrong."
  (with-output-to-string (out)
    (loop for (name . value) in pairs
          do (format out "~A:~A~%" name value))))

(declaim (ftype (function (list) string) aws-signed-headers))

(defun aws-signed-headers (pairs)
  "Return the semicolon separated names of PAIRS, in the order they are signed."
  (format nil "~{~A~^;~}" (mapcar #'car pairs)))

(declaim (ftype (function (string string string list string) string)
                aws-canonical-request))

(defun aws-canonical-request (method uri query headers payload-hash)
  "Return the canonical request text for one signed request.

METHOD is the verb as sent. URI is the path as sent. QUERY is the raw query
string, canonicalised here. HEADERS is the alist that will be sent, canonicalised
here. PAYLOAD-HASH is the lowercase hex SHA-256 of the body, which is also the
x-amz-content-sha256 header when one is sent, and the caller hashes once and
reuses the digest because two spellings of it cannot both be right."
  (let ((pairs (aws-canonical-header-pairs headers)))
    (format nil "~A~%~A~%~A~%~A~%~A~%~A"
            method
            (aws-canonical-uri uri)
            (aws-canonical-query-string query)
            (aws-canonical-headers pairs)
            (aws-signed-headers pairs)
            payload-hash)))

;;;; The signature.

(declaim (ftype (function (string string string) string) aws-scope))

(defun aws-scope (date region service)
  "Return the credential scope for DATE, REGION and SERVICE."
  (format nil "~A/~A/~A/aws4_request" date region service))

(declaim (ftype (function (string string string) string) aws-string-to-sign))

(defun aws-string-to-sign (canonical-request timestamp scope)
  "Return the string to sign for CANONICAL-REQUEST.

TIMESTAMP is the ISO 8601 basic timestamp and not the date: the string to sign
carries the full instant while the scope carries the date, and swapping them
produces a signature that is wrong only near midnight UTC."
  (format nil "AWS4-HMAC-SHA256~%~A~%~A~%~A"
          timestamp scope (aws-sha256-hex canonical-request)))

(declaim (ftype (function (string string string string) vector) aws-signing-key))

(defun aws-signing-key (secret date region service)
  "Return the SigV4 signing key for one date, region and service, as octets.

The key is derived, not stored: four HMACs, each over the previous result, so
the secret itself never reaches the wire and a captured signature cannot be
replayed against another region or another day."
  (let* ((initial (aws-string-octets (concatenate 'string "AWS4" secret)))
         (dated (aws-hmac initial (aws-string-octets date)))
         (scoped (aws-hmac dated (aws-string-octets region)))
         (for-service (aws-hmac scoped (aws-string-octets service))))
    (aws-hmac for-service (aws-string-octets "aws4_request"))))

(declaim (ftype (function (string string string string aws-credential) string)
                aws-signature))

(defun aws-signature (canonical-request timestamp region service credentials)
  "Return the lowercase hex signature for CANONICAL-REQUEST.

This is the whole algorithm minus the header assembly: hash the canonical
request into the string to sign, derive the key, sign. It is a function of its
arguments alone, which is what lets a test compare it with AWS's published
signature for a request nobody sends."
  (let* ((date (subseq timestamp 0 8))
         (scope (aws-scope date region service))
         (string-to-sign (aws-string-to-sign canonical-request timestamp scope))
         (key (aws-signing-key (aws-credential-secret-key credentials)
                               date region service)))
    (aws-hex (aws-hmac key (aws-string-octets string-to-sign)))))

(declaim (ftype (function (string string string string) string) aws-authorization))

(defun aws-authorization (access-key scope signed-headers signature)
  "Return the Authorization header value for a signed request.

The header is the only place the algorithm is visible on the wire, and it is
written here and not in SIGN-REQUEST because a test compares it whole with
AWS's expected value: the credential, the scope, the signed header list and the
signature are four separate chances to be wrong."
  (format nil "AWS4-HMAC-SHA256 Credential=~A/~A, SignedHeaders=~A, Signature=~A"
          access-key scope signed-headers signature))

;;;; The request.

(declaim (ftype (function (http-request string string
                                        &key (:credentials t) (:time t)
                                             (:method t) (:content-sha256-p t))
                          list)
                sign-request))

(defun sign-request (request region service &key credentials time
                                                     (method "POST")
                                                     (content-sha256-p t))
  "Return REQUEST's headers with SigV4 authentication added.

CREDENTIALS is the credential to sign with; NIL asks
*AWS-CREDENTIALS-FUNCTION*, which is the secret store and then the environment.
TIME is a universal time, NIL means *SIGNING-TIME*, and NIL again means the
clock. Both are arguments so that a signature can be a function of a published
vector rather than of the day the test ran.

METHOD is an argument because HTTP-REQUEST has no method slot: the transport
sends a POST and the model listers send a GET, and a signature computed for the
wrong verb is refused without saying so.

CONTENT-SHA256-P adds the x-amz-content-sha256 header and signs it, which is
the default because AWS requires every x-amz-* header to be signed and because
the digest is what lets the service check the body before reading it. AWS's own
published test suite predates that header, so the vector fixtures turn it off
rather than pretend the header is not part of this implementation.

HOST comes from the URL and is always signed: a request whose Host header was
replaced in transit is a request for another service, which is the whole reason
AWS requires it in the signed set."
  (let ((credentials (or credentials (resolve-aws-credentials))))
    (unless (aws-credential-usable-p credentials)
      (error 'enchiridion.errors:configuration-error
             :key :aws-credentials
             :detail "No AWS credential is available to sign with: set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY, or load them as secrets."))
    (multiple-value-bind (host path query) (aws-url-parts (http-request-url request))
      (multiple-value-bind (timestamp date)
          (aws-timestamp (or time *signing-time* (get-universal-time)))
        (let* ((payload-hash (aws-sha256-hex (http-request-body request)))
               (added (list (cons :host host)
                            (cons :x-amz-date timestamp))))
          (when content-sha256-p
            (push (cons :x-amz-content-sha256 payload-hash) added))
          (let ((token (aws-nonempty-string (aws-credential-session-token credentials))))
            (when token
              (push (cons :x-amz-security-token token) added)))
          (let* ((headers (merge-headers (http-request-headers request)
                                         (reverse added)))
                 (pairs (aws-canonical-header-pairs headers))
                 (signed (aws-signed-headers pairs))
                 (canonical (aws-canonical-request method path query headers
                                                   payload-hash))
                 (scope (aws-scope date region service))
                 (signature (aws-signature canonical timestamp region service
                                           credentials)))
            (merge-headers
             headers
             (list (cons :authorization
                         (aws-authorization
                          (aws-credential-access-key credentials)
                          scope signed signature))))))))))

;;;; The signed scheme.
;;;;
;;;; AUTH-APPLY calls a signer with (DIALECT KEY REQUEST) and merges what it
;;;; returns. The three facts a signature needs that a dialect record does not
;;;; carry travel in specials: the endpoint builder knows its region, its
;;;; service and its method, and binds them around the call. They are bound and
;;;; not passed because the signer's argument list is auth.cl's, and widening it
;;;; would put an AWS-specific parameter in a vendor-neutral dispatch table.

(declaim (type (or null string) *aws-region* *aws-service* *aws-request-method*))

(defparameter *aws-region* nil
  "The region SIGN-REQUEST signs for while a signer runs. Bound by the handler
that built the endpoint, because only it knows the region.")

(defparameter *aws-service* nil
  "The SigV4 service name while a signer runs. NIL means BEDROCK, which is the
service this tree signs for.")

(defparameter *aws-request-method* nil
  "The HTTP method while a signer runs. NIL means POST, which every signed call
here except the control plane's model list is.")

(declaim (ftype (function (t t http-request) list) aws-sigv4-signer))

(defun aws-sigv4-signer (dialect key request)
  "Sign REQUEST for the region, service and method bound around this call.

DIALECT and KEY are ignored: the scheme is already the dialect's answer, and
the key this scheme would carry is the bearer token the dialect would have used
for :BEARER instead. The credential comes from *AWS-CREDENTIALS-FUNCTION*,
which is the one place that decides where a signature's key comes from."
  (declare (ignore dialect key))
  (sign-request request
                (or (aws-nonempty-string *aws-region*)
                    (error 'enchiridion.errors:configuration-error
                           :key :region
                           :detail "No AWS region was bound around the SigV4 signer; the endpoint builder sets *AWS-REGION*."))
                (or (aws-nonempty-string *aws-service*) "bedrock")
                :method (or (aws-nonempty-string *aws-request-method*) "POST")))

(register-auth-signer :aws-sigv4 #'aws-sigv4-signer)
