;;;; gcp-oauth.lsp --- Google Cloud OAuth 2.0 bearer tokens for Vertex AI.
;;;;
;;;; Token precedence:
;;;;   1. Static token from GOOGLE_VERTEX_ACCESS_TOKEN or GCLOUD_ACCESS_TOKEN
;;;;      (secrets then env), returned uncached.
;;;;   2. Service account JSON at GOOGLE_APPLICATION_CREDENTIALS: RS256 JWT
;;;;      exchanged at oauth2.googleapis.com/token and cached in memory until
;;;;      expires_in minus safety margin.
;;;; Includes a minimal PKCS#8/PKCS#1 PEM+DER reader for RSA private keys.

(in-package #:enchiridion.llm)

;;;; The constants.

;; DEFPARAMETER rather than DEFCONSTANT to avoid SBCL string redefinition warnings.

(defparameter +gcp-scope+ "https://www.googleapis.com/auth/cloud-platform"
  "OAuth scope required for Vertex AI (aiplatform.googleapis.com).")

(defparameter +gcp-token-url+ "https://oauth2.googleapis.com/token"
  "Google OAuth 2.0 token endpoint (also used as the JWT aud claim).")

(defparameter +gcp-jwt-lifetime+ 3600
  "Maximum JWT assertion lifetime in seconds (1 hour, per Google's limit).")

(defparameter +gcp-token-safety-margin+ 60
  "Seconds subtracted from expires_in when caching a token to avoid expiry races.")

(defparameter +gcp-token-default-lifetime+ 3600
  "Fallback token cache lifetime in seconds if the response omits expires_in.")

(defparameter +gcp-credentials-variable+ "GOOGLE_APPLICATION_CREDENTIALS"
  "Environment/secret variable naming the GCP service account JSON path.")

(defparameter +gcp-access-token-variables+
  '("GOOGLE_VERTEX_ACCESS_TOKEN" "GCLOUD_ACCESS_TOKEN")
  "Static access token variables checked in precedence order.")

(defparameter +gcp-token-timeout+ 30
  "HTTP timeout in seconds for the OAuth token exchange request.")

(defparameter +sha256-digest-info+
  (make-array 19
              :element-type '(unsigned-byte 8)
              :initial-contents '(#x30 #x31 #x30 #x0d #x06 #x09 #x60 #x86
                                  #x48 #x01 #x65 #x03 #x04 #x02 #x01 #x05
                                  #x00 #x04 #x20))
  "RFC 8017 DER DigestInfo prefix for SHA-256 in PKCS#1 v1.5 (RS256) signatures.")

;;;; Reading a setting.

(declaim (ftype (function (t) (or null string)) gcp-nonempty))

(defun gcp-nonempty (value)
  "Return VALUE if it is a non-empty string, else NIL."
  (if (and (stringp value) (plusp (length value))) value nil))

(declaim (ftype (function (string) (or null string)) gcp-setting))

(defun gcp-setting (name)
  "Look up NAME in the secret loader first, then the environment, treating
empty strings as absent."
  (or (gcp-nonempty (enchiridion.llm.secrets:secret-value name))
      (gcp-nonempty (enchiridion.compat:environment-value name))))

;;;; The service account JSON.

(declaim (ftype (function () list) gcp-service-account))

(defun gcp-service-account ()
  "Read and parse the service account JSON from +GCP-CREDENTIALS-VARIABLE+,
signaling CONFIGURATION-ERROR if missing or invalid."
  (let ((path (gcp-setting +gcp-credentials-variable+)))
    (unless path
      (error 'enchiridion.errors:configuration-error
             :key :gcp-credentials
             :detail (format nil "No Google credential: set ~A to a service account file, or ~{~A~^ or ~} to an access token."
                             +gcp-credentials-variable+
                             +gcp-access-token-variables+)))
    (unless (probe-file path)
      (error 'enchiridion.errors:configuration-error
             :key :gcp-credentials
             :detail (format nil "~A names ~A, which does not exist."
                             +gcp-credentials-variable+ path)))
    (handler-case (parse-json (uiop:read-file-string path))
      (error (condition)
        (error 'enchiridion.errors:configuration-error
               :key :gcp-credentials
               :detail (format nil "~A could not be read as JSON: ~A"
                               path condition))))))

(declaim (ftype (function (list symbol string) string) gcp-service-account-field))

(defun gcp-service-account-field (account key what)
  "Return non-empty string KEY from ACCOUNT, or signal CONFIGURATION-ERROR
naming WHAT (without logging account contents)."
  (let ((value (getf account key)))
    (or (gcp-nonempty value)
        (error 'enchiridion.errors:configuration-error
               :key :gcp-credentials
               :detail (format nil "The service account has no ~A (~A)."
                               what (string-downcase (string key)))))))

;;;; PEM and DER.

(declaim (ftype (function (string) (vector (unsigned-byte 8))) gcp-pem-der))

(defun gcp-pem-der (pem)
  "Strip PEM BEGIN/END banners and whitespace, then base64-decode to DER octets."
  (let* ((begin (search "-----BEGIN" pem))
         (body-start (and begin (position #\Newline pem :start begin)))
         (end (and body-start (search "-----END" pem :start2 body-start))))
    (unless (and body-start end)
      (error 'enchiridion.errors:configuration-error
             :key :gcp-credentials
             :detail "The service account private_key is not a PEM block: it has no BEGIN and END banners."))
    (let ((payload (remove-if (lambda (character)
                                (member character '(#\Space #\Tab #\Newline #\Return)))
                              (subseq pem body-start end))))
      (handler-case (cl-base64:base64-string-to-usb8-array payload)
        (error (condition)
          (error 'enchiridion.errors:configuration-error
                 :key :gcp-credentials
                 :detail (format nil "The service account private key is not readable base64: ~A"
                                 condition)))))))

(declaim (ftype (function (string) nil) gcp-der-error))

(defun gcp-der-error (detail)
  "Signal a CONFIGURATION-ERROR about the service account key. Never returns."
  (error 'enchiridion.errors:configuration-error
         :key :gcp-credentials
         :detail (format nil "The service account private key is malformed: ~A" detail)))

(declaim (ftype (function ((vector (unsigned-byte 8)) integer integer)
                          (values integer integer integer integer))
                gcp-der-element))

(defun gcp-der-element (octets position limit)
  "Parse one DER TLV at POSITION within LIMIT, returning
(VALUES tag content-start content-end next-position). Supports short and up to
3-byte long lengths."
  (unless (< position limit)
    (gcp-der-error "an element runs past the end of the key"))
  (let ((tag (aref octets position))
        (length-position (1+ position)))
    (unless (< length-position limit)
      (gcp-der-error "an element has no length byte"))
    (let ((first (aref octets length-position)))
      (multiple-value-bind (length next)
          (if (< first #x80)
              (values first (1+ length-position))
              (let ((count (- first #x80)))
                (when (or (zerop count)
                          (> count 3)
                          (> (+ length-position 1 count) limit))
                  (gcp-der-error "a length field is malformed"))
                (values (loop for index from 0 below count
                              for offset = (+ length-position 1 index)
                              sum (* (aref octets offset)
                                     (expt 256 (- count index 1))))
                        (+ length-position 1 count))))
        (let ((content-end (+ next length)))
          (when (> content-end limit)
            (gcp-der-error "an element claims more bytes than the key holds"))
          (values tag next content-end content-end))))))

(declaim (ftype (function ((vector (unsigned-byte 8)) integer integer) list)
                gcp-der-children))

(defun gcp-der-children (octets start end)
  "Return the DER elements between START and END, each as (TAG START END)."
  (let ((position start)
        (children '()))
    (loop while (< position end)
          do (multiple-value-bind (tag content-start next)
                 (gcp-der-element octets position end)
               (push (list tag content-start next) children)
               (setf position next)))
    (nreverse children)))

(declaim (ftype (function ((vector (unsigned-byte 8)) list) ironclad:rsa-private-key)
                gcp-pkcs1-private-key))

(defun gcp-pkcs1-private-key (octets children)
  "Build an ironclad:rsa-private-key from PKCS#1 RSAPrivateKey INTEGER children
(extracting n, d, p, q)."
  (let ((numbers (loop for (tag start end) in children
                       when (= tag #x02)
                         collect (ironclad:octets-to-integer octets
                                                             :start start
                                                             :end end))))
    (unless (>= (length numbers) 6)
      (gcp-der-error "the key has fewer numbers than an RSAPrivateKey needs"))
    (ironclad:make-private-key :rsa
                               :n (nth 1 numbers)
                               :d (nth 3 numbers)
                               :p (nth 4 numbers)
                               :q (nth 5 numbers))))

(declaim (ftype (function ((vector (unsigned-byte 8))) ironclad:rsa-private-key)
                gcp-rsa-private-key))

(defun gcp-rsa-private-key (der)
  "Parse DER octets into an ironclad:rsa-private-key, unwrapping PKCS#8
PrivateKeyInfo (3-element SEQUENCE ending in OCTET STRING) or reading PKCS#1 directly."
  (multiple-value-bind (tag content-start content-end)
      (gcp-der-element der 0 (length der))
    (unless (= tag #x30)
      (gcp-der-error "the key does not begin with a SEQUENCE"))
    (let ((children (gcp-der-children der content-start content-end)))
      (if (and (= (length children) 3)
               (= (first (third children)) #x04))
          (gcp-rsa-private-key
           (subseq der (second (third children)) (third (third children))))
          (gcp-pkcs1-private-key der children)))))

;;;; The assertion.

(declaim (ftype (function (ironclad:rsa-private-key string)
                          (vector (unsigned-byte 8)))
                gcp-rsa-sha256-sign))

(defun gcp-rsa-sha256-sign (key signing-input)
  "Return the RS256 (RSASSA-PKCS1-v1_5 + SHA-256) signature of SIGNING-INPUT
under KEY as octets. Builds 0x00 0x01 0xFF... 0x00 DigestInfo SHA256(input)
manually because ironclad performs bare modular exponentiation."
  (let* ((modulus (ironclad:rsa-key-modulus key))
         (exponent (ironclad:rsa-key-exponent key))
         (size (ceiling (integer-length modulus) 8))
         (digest (ironclad:digest-sequence
                  :sha256
                  (ironclad:ascii-string-to-byte-array signing-input)))
         (tail-length (+ (length +sha256-digest-info+) (length digest)))
         (padding-size (- size tail-length 3))
         (block (make-array size :element-type '(unsigned-byte 8))))
    (when (minusp padding-size)
      (gcp-der-error "the RSA key is too small for a SHA-256 signature"))
    (setf (aref block 0) 0)
    (setf (aref block 1) 1)
    (fill block #xff :start 2 :end (+ 2 padding-size))
    (setf (aref block (+ 2 padding-size)) 0)
    (replace block +sha256-digest-info+ :start1 (+ 3 padding-size))
    (replace block digest :start1 (+ 3 padding-size
                                          (length +sha256-digest-info+)))
    (ironclad:integer-to-octets
     (ironclad:expt-mod (ironclad:octets-to-integer block) exponent modulus)
     :n-bits (* 8 size))))

(declaim (ftype (function ((vector (unsigned-byte 8))) string) gcp-base64url))

(defun gcp-base64url (octets)
  "Encode OCTETS as unpadded base64url (+ -> -, / -> _, trailing '=' stripped;
avoids cl-base64's '.' URI padding)."
  (let ((text (cl-base64:usb8-array-to-base64-string octets)))
    (string-right-trim "="
                       (substitute #\- #\+
                                   (substitute #\_ #\/ text)))))

(declaim (ftype (function (string) string) gcp-base64url-text))

(defun gcp-base64url-text (text)
  "Return TEXT as unpadded base64url text."
  (gcp-base64url (ironclad:ascii-string-to-byte-array text)))

(declaim (ftype (function (string ironclad:rsa-private-key integer) string)
                gcp-jwt))

(defun gcp-jwt (client-email private-key issued-at)
  "Build and RS256-sign the JWS compact JWT assertion for CLIENT-EMAIL at ISSUED-AT."
  (let* ((header (gcp-base64url-text (stringify (json-object :alg "RS256"
                                                             :typ "JWT"))))
         (claims (gcp-base64url-text
                  (stringify (json-object :iss client-email
                                          :scope +gcp-scope+
                                          :aud +gcp-token-url+
                                          :iat issued-at
                                          :exp (+ issued-at
                                                  +gcp-jwt-lifetime+)))))
         (signing-input (format nil "~A.~A" header claims)))
    (format nil "~A.~A" signing-input
            (gcp-base64url (gcp-rsa-sha256-sign private-key signing-input)))))

;;;; The exchange.

(defparameter *gcp-clock* #'get-universal-time
  "Zero-arg universal-time clock for JWT timestamps and cache expiry; bound in tests.")

(defparameter *gcp-token-cache* nil
  "Cached exchanged token as (TOKEN . EXPIRY-UNIVERSAL-TIME) or NIL; static
tokens are never cached.")

(declaim (ftype (function (string) string) gcp-token-error-detail))

(defun gcp-token-error-detail (payload)
  "Extract error_description or error from a token endpoint JSON error response,
falling back to PROVIDER-ERROR-MESSAGE."
  (handler-case
      (let ((data (parse-json payload)))
        (or (gcp-nonempty (json-string (getf data :error_description)))
            (gcp-nonempty (json-string (getf data :error)))
            (provider-error-message payload)))
    (error () (provider-error-message payload))))

(declaim (ftype (function (string string) string) gcp-token-http-post))

(defun gcp-token-http-post (url body)
  "POST an application/x-www-form-urlencoded OAuth body to URL with retries
and a 64 KiB response cap."
  (post-with-retries
   (lambda (request) (bounded-http-request request :body-limit 65536))
   (make-http-request :url url :body body :timeout +gcp-token-timeout+
                      :headers '((:content-type . "application/x-www-form-urlencoded")))
   2))

(defparameter *gcp-token-post-function* #'gcp-token-http-post
  "Transport function (url body) -> reply-text used to exchange JWTs; bound in tests.")

(declaim (ftype (function (list string integer) string) gcp-exchange-access-token))

(defun gcp-exchange-access-token (account client-email now)
  "Sign a JWT assertion for ACCOUNT/CLIENT-EMAIL at NOW, exchange it at
+GCP-TOKEN-URL+, cache the token with safety margin, and return it."
  (let* ((private-key (gcp-rsa-private-key
                       (gcp-pem-der
                        (gcp-service-account-field account :private_key
                                                   "private key"))))
         (assertion (gcp-jwt client-email private-key now))
         (form (format nil
                       "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=~A"
                       assertion))
         (reply (funcall *gcp-token-post-function* +gcp-token-url+ form))
         (data (handler-case (parse-json reply)
                 (error (condition)
                   (error 'enchiridion.errors:backend-error
                          :backend "gcp"
                          :detail (format nil "The Google token endpoint answered with something that is not JSON: ~A"
                                          condition)))))
         (token (gcp-nonempty (json-string (getf data :access_token)))))
    (unless token
      (error 'enchiridion.errors:backend-error
             :backend "gcp"
             :detail (format nil "The Google token endpoint returned no access token: ~A"
                             (gcp-token-error-detail reply))))
    (let* ((reported (getf data :expires_in))
           (lifetime (if (and (integerp reported) (plusp reported))
                         reported
                         +gcp-token-default-lifetime+))
           (expiry (+ now (- lifetime +gcp-token-safety-margin+))))
      (setf *gcp-token-cache* (cons token expiry))
      token)))

(declaim (ftype (function (integer) (or null string)) gcp-cached-access-token))

(defun gcp-cached-access-token (now)
  "Return the cached access token when NOW is inside its lifetime, else NIL."
  (let ((entry *gcp-token-cache*))
    (when (and (consp entry)
               (stringp (car entry))
               (integerp (cdr entry))
               (< now (cdr entry)))
      (car entry))))

(declaim (ftype (function () (or null string)) gcp-static-access-token))

(defun gcp-static-access-token ()
  "Return the first non-empty static token from +GCP-ACCESS-TOKEN-VARIABLES+
(secrets then env), or NIL."
  (loop for name in +gcp-access-token-variables+
        for value = (gcp-setting name)
        when value return value))

(declaim (ftype (function (&key) string) gcp-access-token))

(defun gcp-access-token (&key)
  "Return a GCP access token: static token first (uncached), else cached
exchanged token, else a new JWT exchange from the service account."
  (or (gcp-static-access-token)
      (let ((now (funcall *gcp-clock*)))
        (or (gcp-cached-access-token now)
            (let* ((account (gcp-service-account))
                   (client-email (gcp-service-account-field
                                  account :client_email "client_email")))
              (gcp-exchange-access-token account client-email now))))))

;;;; Register :GCP-OAUTH signer for AUTH-APPLY.

(register-auth-signer
 :gcp-oauth
 (lambda (dialect key request)
   "Return the Authorization header a Google OAuth request carries."
   (declare (ignore dialect key request))
   (list (cons :authorization (format nil "Bearer ~A" (gcp-access-token))))))
