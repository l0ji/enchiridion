;;;; aws-sigv4.lsp --- AWS Signature Version 4 signing over HTTP-REQUEST.
;;;;
;;;; Pure canonicalization, key derivation, and signing helpers (testable
;;;; directly against AWS SigV4 vectors), registered as :AWS-SIGV4 for AUTH-APPLY.

(in-package #:enchiridion.llm)

;;;; Credentials.

;; SESSION-TOKEN is NIL when absent so an empty x-amz-security-token is never signed.
(defstruct (aws-credential (:constructor %make-aws-credential))
  (:access-key "" :type string)
  (:secret-key "" :type string)
  (:session-token nil :type (or null string)))

(declaim (ftype (function (&key (:access-key t) (:secret-key t) (:session-token t))
                          aws-credential)
                make-aws-credential))

(defun make-aws-credential (&key access-key secret-key session-token)
  "Construct an AWS-CREDENTIAL; missing access/secret keys default to \"\" so
AWS-CREDENTIAL-USABLE-P rejects them cleanly."
  (%make-aws-credential :access-key (or access-key "")
                        :secret-key (or secret-key "")
                        :session-token session-token))

(declaim (ftype (function (t) (or null string)) aws-nonempty-string))

(defun aws-nonempty-string (value)
  "Return VALUE if it is a non-empty string, else NIL."
  (and (stringp value) (plusp (length value)) value))

(declaim (ftype (function (string) (or null string)) secret-or-environment))

(defun secret-or-environment (name)
  "Look up NAME in the secret store first, falling back to the environment."
  (or (aws-nonempty-string (enchiridion.llm.secrets:secret-value name))
      (aws-nonempty-string (enchiridion.compat:environment-value name))))

(declaim (ftype (function (&key (:access-key t) (:secret-key t) (:session-token t))
                          (or null aws-credential))
                aws-credentials))

(defun aws-credentials (&key access-key secret-key session-token)
  "Resolve AWS credentials from explicit args, then AWS_ACCESS_KEY_ID /
AWS_SECRET_ACCESS_KEY / AWS_SESSION_TOKEN (secrets then env). Returns NIL
unless both access and secret keys are present."
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
  "Zero-arg credential resolver used by SIGN-REQUEST when no credentials are
passed; NIL disables resolution.")

(declaim (ftype (function () (or null aws-credential)) resolve-aws-credentials))

(defun resolve-aws-credentials ()
  "Call *AWS-CREDENTIALS-FUNCTION* if it is a function, else return NIL.
Copies the special to a local so SBCL can narrow its type."
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
  "Return T when usable AWS signing credentials can be resolved."
  (aws-credential-usable-p (resolve-aws-credentials)))

;;;; Octets, hex and hashing.
;;;; Uses UTF-8 via COMPAT:ENCODE-UTF8 so digests match wire bytes.

(declaim (ftype (function (string) vector) aws-string-octets))

(defun aws-string-octets (text)
  "Return TEXT as the UTF-8 octets the wire will carry."
  (enchiridion.compat:encode-utf8 text))

(declaim (ftype (function (vector) string) aws-hex))

(defun aws-hex (octets)
  "Return OCTETS as lowercase hexadecimal text (as required by SigV4)."
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
  "Return the lowercase hex SHA-256 of TEXT (UTF-8; NIL treated as \"\")."
  (aws-hex (aws-sha256 (aws-string-octets (or text "")))))

;;;; Percent-encoding.

(declaim (ftype (function (vector) string) aws-encode-octets))

(defun aws-encode-octets (octets)
  "Percent-encode OCTETS per SigV4: keep A-Z, a-z, 0-9, '-', '_', '.', '~',
and encode all other bytes (including space as %20) as uppercase %XY."
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
  "Decode %XY escapes in TEXT to octets, UTF-8 encoding literal characters
(including any stray '%' not followed by two hex digits)."
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
  "Split TEXT at every DELIMITER into a list of strings, preserving empty fields."
  (let ((parts '())
        (start 0))
    (loop for position = (position delimiter text :start start)
          while position
          do (push (subseq text start position) parts)
             (setf start (1+ position)))
    (push (subseq text start) parts)
    (nreverse parts)))

;;;; The clock.

(declaim (type (or null integer) *signing-time*))

(defparameter *signing-time* nil
  "Universal time used by SIGN-REQUEST when :time is NIL; NIL uses wall clock.")

(declaim (ftype (function (integer) (values string string)) aws-timestamp))

(defun aws-timestamp (universal-time)
  "Return UNIVERSAL-TIME in UTC as (VALUES amz-date short-date), i.e.
YYYYMMDDTHHMMSSZ and YYYYMMDD."
  (multiple-value-bind (second minute hour day month year)
      (decode-universal-time universal-time 0)
    (let ((stamp (format nil "~4,'0D~2,'0D~2,'0DT~2,'0D~2,'0D~2,'0DZ"
                         year month day hour minute second)))
      (values stamp (subseq stamp 0 8)))))

;;;; The URL.

(declaim (ftype (function (string) (values string string string)) aws-url-parts))

(defun aws-url-parts (url)
  "Extract (VALUES host path query) from URL, dropping scheme/userinfo/fragment
and keeping port. Signals CONFIGURATION-ERROR if host is missing or has spaces."
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
  "Return PATH as the canonical URI (ensuring a leading '/', defaulting empty
to \"/\") without re-encoding."
  (cond
    ((or (null path) (zerop (length path))) "/")
    ((char= (char path 0) #\/) path)
    (t (concatenate 'string "/" path))))

;;;; The canonical request.

(declaim (ftype (function (t) string) aws-trim-header-value))

(defun aws-trim-header-value (value)
  "Trim leading/trailing whitespace from VALUE and collapse internal whitespace
runs to a single space, per SigV4."
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
  "Return HEADERS as (lowercase-name . trimmed-value) pairs sorted by name."
  (sort (loop for (name . value) in headers
              collect (cons (string-downcase (string name))
                            (aws-trim-header-value value)))
        #'string< :key #'car))

(declaim (ftype (function (t) string) aws-canonical-query-string))

(defun aws-canonical-query-string (query)
  "Canonicalize QUERY: percent-decode and re-encode each param, sort by encoded
name then encoded value, and join as name=value with '&' (valueless params keep '=')."
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
  "Format canonical header PAIRS as name:value lines, including the trailing
newline required before the signed-headers line."
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
  "Build the SigV4 canonical request from METHOD, URI, raw QUERY, HEADERS alist,
and lowercase hex PAYLOAD-HASH."
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
  "Build the AWS4-HMAC-SHA256 string to sign from CANONICAL-REQUEST, full
ISO 8601 TIMESTAMP, and credential SCOPE."
  (format nil "AWS4-HMAC-SHA256~%~A~%~A~%~A"
          timestamp scope (aws-sha256-hex canonical-request)))

(declaim (ftype (function (string string string string) vector) aws-signing-key))

(defun aws-signing-key (secret date region service)
  "Derive the SigV4 signing key via chained HMAC-SHA256 over \"AWS4\"+SECRET,
DATE, REGION, SERVICE, and \"aws4_request\"."
  (let* ((initial (aws-string-octets (concatenate 'string "AWS4" secret)))
         (dated (aws-hmac initial (aws-string-octets date)))
         (scoped (aws-hmac dated (aws-string-octets region)))
         (for-service (aws-hmac scoped (aws-string-octets service))))
    (aws-hmac for-service (aws-string-octets "aws4_request"))))

(declaim (ftype (function (string string string string aws-credential) string)
                aws-signature))

(defun aws-signature (canonical-request timestamp region service credentials)
  "Compute the lowercase hex SigV4 signature for CANONICAL-REQUEST."
  (let* ((date (subseq timestamp 0 8))
         (scope (aws-scope date region service))
         (string-to-sign (aws-string-to-sign canonical-request timestamp scope))
         (key (aws-signing-key (aws-credential-secret-key credentials)
                               date region service)))
    (aws-hex (aws-hmac key (aws-string-octets string-to-sign)))))

(declaim (ftype (function (string string string string) string) aws-authorization))

(defun aws-authorization (access-key scope signed-headers signature)
  "Format the AWS4-HMAC-SHA256 Authorization header value."
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
  "Return REQUEST's headers with SigV4 authentication added (Host, x-amz-date,
optional x-amz-content-sha256 and x-amz-security-token, and Authorization).
Resolves CREDENTIALS via *AWS-CREDENTIALS-FUNCTION* and TIME via *SIGNING-TIME*
or wall clock when NIL; CONTENT-SHA256-P can be disabled for legacy test vectors."
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

;;;; The signed scheme (:AWS-SIGV4 for AUTH-APPLY).
;;;; Region, service, and method travel in specials to keep AUTH-APPLY vendor-neutral.

(declaim (type (or null string) *aws-region* *aws-service* *aws-request-method*))

(defparameter *aws-region* nil
  "AWS region bound around AWS-SIGV4-SIGNER by the endpoint builder.")

(defparameter *aws-service* nil
  "SigV4 service name bound around AWS-SIGV4-SIGNER (defaults to \"bedrock\").")

(defparameter *aws-request-method* nil
  "HTTP method bound around AWS-SIGV4-SIGNER (defaults to \"POST\").")

(declaim (ftype (function (t t http-request) list) aws-sigv4-signer))

(defun aws-sigv4-signer (dialect key request)
  "AUTH-APPLY signer for :AWS-SIGV4; ignores DIALECT and KEY and signs REQUEST
using *AWS-REGION*, *AWS-SERVICE*, and *AWS-REQUEST-METHOD*."
  (declare (ignore dialect key))
  (sign-request request
                (or (aws-nonempty-string *aws-region*)
                    (error 'enchiridion.errors:configuration-error
                           :key :region
                           :detail "No AWS region was bound around the SigV4 signer; the endpoint builder sets *AWS-REGION*."))
                (or (aws-nonempty-string *aws-service*) "bedrock")
                :method (or (aws-nonempty-string *aws-request-method*) "POST")))

(register-auth-signer :aws-sigv4 #'aws-sigv4-signer)
