;;;; gcp-oauth.cl --- A Google Cloud bearer token, from a static token or from
;;;; a service account.
;;;;
;;;; Vertex AI takes no API key. It takes a short lived OAuth 2.0 access token,
;;;; and this file is the only place in the tree that knows where one comes
;;;; from. There are two sources, in this order:
;;;;
;;;;   1. a token the operator already minted. GOOGLE_VERTEX_ACCESS_TOKEN and
;;;;      GCLOUD_ACCESS_TOKEN are read from the secret loader first and the
;;;;      process environment second, and the value is used as it stands. The
;;;;      operator's token is the authority here: minting a second one from a
;;;;      service account would ignore the credential they chose.
;;;;
;;;;   2. a service account JSON at GOOGLE_APPLICATION_CREDENTIALS. Its
;;;;      private_key signs an RS256 JWT, and the JWT is exchanged at
;;;;      https://oauth2.googleapis.com/token for an access token.
;;;;
;;;; The exchange is cached in memory until expires_in minus a safety margin,
;;;; so a long running process pays for one exchange and not one per turn.
;;;; Nothing is written to disk: a token in a file outlives the process that
;;;; could invalidate it, and the cache is the whole of the state kept here.
;;;;
;;;; The static token is deliberately not cached. It carries no expires_in to
;;;; cache against, reading it is an in-memory lookup, and a cached copy would
;;;; keep serving a value the operator rotated.
;;;;
;;;; Three specials carry every side effect: the clock, the one POST, and the
;;;; cache. A test drives the whole flow with no socket, no service account and
;;;; no passage of time.
;;;;
;;;; The service account file is PKCS#8 PEM, which is what the Google console
;;;; issues. Ironclad has no PEM reader and cl-base64 is the base64 half of
;;;; one, so the armor and the DER inside it are read here. PrivateKeyInfo is a
;;;; SEQUENCE of a version, an algorithm and an OCTET STRING that holds the
;;;; RSAPrivateKey of nine INTEGERs; reading two SEQUENCEs is cheaper than a
;;;; DER library and is the whole of what a service account needs. No public
;;;; key is ever parsed: nothing here verifies a signature.

(in-package #:enchiridion.llm)

;;;; The constants.

;; Every one of these is a DEFPARAMETER and not a DEFCONSTANT. SBCL evaluates
;; a DEFCONSTANT's init form when the file is compiled and again when the fasl
;; is loaded, and two strings with the same characters are not EQL, so the
;; second evaluation is a redefinition warning. This system makes a warning an
;; error, and the report would name a value that never changed.

(defparameter +gcp-scope+ "https://www.googleapis.com/auth/cloud-platform"
  "The OAuth scope a Vertex AI access token needs. Cloud platform is the
narrowest scope that reaches aiplatform.googleapis.com.")

(defparameter +gcp-token-url+ "https://oauth2.googleapis.com/token"
  "The token endpoint a service account JWT is exchanged at. It is also the
audience the JWT names, because Google checks that the two agree.")

(defparameter +gcp-jwt-lifetime+ 3600
  "How long the assertion is valid, in seconds. Google refuses an assertion
whose lifetime is longer than an hour and one that has already expired, so this
is the documented maximum and not a tuning knob.")

(defparameter +gcp-token-safety-margin+ 60
  "Seconds shaved off every expires_in before the token is cached. A token
cached up to the second it dies is handed to a request that arrives just as it
expires, and that request fails with a 401 that says nothing about the clock.")

(defparameter +gcp-token-default-lifetime+ 3600
  "Seconds a token is cached for when the reply carries no expires_in. Google
always sends one; a proxy that strips it should not turn every turn into an
exchange.")

(defparameter +gcp-credentials-variable+ "GOOGLE_APPLICATION_CREDENTIALS"
  "The variable naming the service account JSON. This is Google's own name for
it, used by every client library and by gcloud, so it is not this tree's to
choose.")

(defparameter +gcp-access-token-variables+
  '("GOOGLE_VERTEX_ACCESS_TOKEN" "GCLOUD_ACCESS_TOKEN")
  "The variables that may already hold an access token. The first is the
Vertex-specific spelling and the second is what the output of `gcloud auth
print-access-token` is usually stored as; the Vertex one wins because it names
the service this tree actually calls.")

(defparameter +gcp-token-timeout+ 30
  "Seconds before the one token exchange is abandoned. It is shorter than a
completion's timeout because the reply is small and a stalled token endpoint
should fail a provider build rather than a turn.")

(defparameter +sha256-digest-info+
  (make-array 19
              :element-type '(unsigned-byte 8)
              :initial-contents '(#x30 #x31 #x30 #x0d #x06 #x09 #x60 #x86
                                  #x48 #x01 #x65 #x03 #x04 #x02 #x01 #x05
                                  #x00 #x04 #x20))
  "The DER prefix that identifies a SHA-256 digest inside a PKCS#1 v1.5
signature: the DigestInfo of RFC 8017 appendix B, algorithm identifier and all.
RS256 is RSASSA-PKCS1-v1_5 with SHA-256, and it is told apart from a signature
over the raw digest by exactly these nineteen bytes, so they are part of the
algorithm and not decoration.")

;;;; Reading a setting.

(declaim (ftype (function (t) (or null string)) gcp-nonempty))

(defun gcp-nonempty (value)
  "Return VALUE as a non empty string, or NIL.

An empty variable is an unset variable. Google's own clients read it that way,
and the alternative is a service account path of \"\" that fails later with a
filesystem error naming nothing."
  (if (and (stringp value) (plusp (length value))) value nil))

(declaim (ftype (function (string) (or null string)) gcp-setting))

(defun gcp-setting (name)
  "Return the setting NAME from the secret loader, then the environment.

The loader comes first because a value in .env is not in the process
environment: the supervisor reads .env once and unsets the names it loaded, so
the environment is the fallback and not the source. A value that is present but
empty falls through to the next source, because the secret loader refuses to
store an empty value and the environment can hold one."
  (or (gcp-nonempty (enchiridion.llm.secrets:secret-value name))
      (gcp-nonempty (enchiridion.compat:environment-value name))))

;;;; The service account JSON.

(declaim (ftype (function () list) gcp-service-account))

(defun gcp-service-account ()
  "Return the service account JSON as a plist, or signal CONFIGURATION-ERROR.

The file is read through PARSE-JSON, so its objects are plists keyed by keyword
and its strings are strings. Every failure here is a configuration error and
not a transport error: a missing file, a file that is not JSON and a file with
no client_email are all the operator's to fix, and none of them is worth
retrying."
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
  "Return KEY from ACCOUNT, or signal CONFIGURATION-ERROR naming WHAT.

A field that is absent, null, or not a string is one failure: the JWT cannot be
built without it. The report names the field rather than printing the account,
which holds a private key and has no business in a log."
  (let ((value (getf account key)))
    (or (gcp-nonempty value)
        (error 'enchiridion.errors:configuration-error
               :key :gcp-credentials
               :detail (format nil "The service account has no ~A (~A)."
                               what (string-downcase (string key)))))))

;;;; PEM and DER.

(declaim (ftype (function (string) (vector (unsigned-byte 8))) gcp-pem-der))

(defun gcp-pem-der (pem)
  "Return the DER octets inside the first PEM block of PEM.

The armor is found by its BEGIN and END banners and dropped, whitespace and
all, because a PEM body is base64 wrapped into eighty column lines and the
decoder wants it unbroken. cl-base64 does the decoding; hand rolling base64 is
how a JWT ends up three bytes short in a way only the provider notices."
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
  "Return the DER element at POSITION as tag, content bounds, and its end.

DER lengths come in a short form for anything under 128 bytes and a long form
after that, and an RSA modulus is 256 bytes or more, so the long form is the
one that matters. Three length bytes is over sixteen megabytes, which no key
will ever be, so a longer one is refused rather than read. The fourth value is
both the end of the content and the start of the next element, which is why it
is returned twice rather than recomputed by every caller."
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
  "Return the RSAPrivateKey that OCTETS describe, whose elements are CHILDREN.

The order is fixed by PKCS#1: version, modulus, public exponent, private
exponent, the two primes, and then three values derived from those. Only four
of the first six are used: ironclad's private key holds the modulus, the
private exponent and the two primes, and the derived values are recomputable
from exactly those. The public exponent is skipped because the private key
object has no slot for it and signing never needs it."
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
  "Return DER as an ironclad RSA private key.

Two shapes are accepted, and they are told apart by their contents rather than
by the PEM banner, because the banner is the part a hand edited file gets
wrong. PKCS#8 PrivateKeyInfo is three elements whose third is an OCTET STRING
holding the key, and PKCS#1 RSAPrivateKey is nine INTEGERs. The inner key of a
PKCS#8 file is a second DER document, which is why this function calls itself
rather than duplicating the eight lines that read a SEQUENCE."
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
  "Return the RS256 signature of SIGNING-INPUT under KEY, as octets.

Ironclad signs a message with a bare modular exponentiation: its sign-message
is the RSA primitive and not a signature scheme, and in the version this tree
loads the PKCS#1 v1.5 padding that RS256 requires is not applied anywhere. The
padding is therefore built here, and it is the whole difference between a
signature Google accepts and one it rejects.

The block is 0x00 0x01, then 0xFF up to the digest, then 0x00 and the digest,
and its length is the modulus length. A key too small for a SHA-256 signature
is refused here rather than producing a short block the endpoint rejects
without saying why."
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
  "Return OCTETS as unpadded base64url text.

cl-base64's URI alphabet pads with a period rather than with an equals sign,
and a JWS has no padding at all, so the standard alphabet is encoded and then
translated: + to -, / to _, and the padding trimmed. Letting the library's URI
mode do it would put a period at the end of every JWT, which is a character the
token endpoint answers with an error about."
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
  "Return the signed JWT that is exchanged for an access token.

The header and the claims are two JSON objects written by STRINGIFY and
base64url encoded; the signature covers those two encodings joined by a period,
which is the JWS compact serialization. The claims are ISSUED-AT, that instant
plus the hour Google allows, the cloud platform scope, the token endpoint as
the audience, and the service account's own address as the issuer."
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
  "The clock the JWT lifetime and the cache expiry are read from. Bound in
tests so an expiry can be reached without waiting an hour.")

(defparameter *gcp-token-cache* nil
  "The last exchanged access token, as (TOKEN . EXPIRY-UNIVERSAL-TIME), or NIL.

A special and not a closure, because the test that proves the second call does
not POST has to start from an empty cache and no other test may inherit it.
The static token is not stored here: it has no expiry to be stored against.")

(declaim (ftype (function (string) string) gcp-token-error-detail))

(defun gcp-token-error-detail (payload)
  "Return the token endpoint's own message from PAYLOAD.

A failed exchange answers with error and error_description, and the
description is the half that says what is actually wrong: invalid_grant alone
could be a bad clock, a wrong audience or a revoked key. Anything unreadable
falls back to the generic provider message reader, which is the same fallback
every other handler uses."
  (handler-case
      (let ((data (parse-json payload)))
        (or (gcp-nonempty (json-string (getf data :error_description)))
            (gcp-nonempty (json-string (getf data :error)))
            (provider-error-message payload)))
    (error () (provider-error-message payload))))

(declaim (ftype (function (string string) string) gcp-token-http-post))

(defun gcp-token-http-post (url body)
  "POST BODY, an OAuth form, to URL and return the reply text.

The form content type is set explicitly because the body is built by hand and
dexador would otherwise send it as text/plain. A 4xx is dexador's condition and
becomes this tree's TRANSPORT-ERROR with the status and the endpoint's own
message, so a wrong service account reads as invalid_grant rather than as an
HTTP status with an HTML body."
  (handler-case
      (dexador:request url
                       :method :post
                       :headers (list (cons :content-type
                                            "application/x-www-form-urlencoded"))
                       :content body
                       :read-timeout +gcp-token-timeout+
                       :connect-timeout +gcp-token-timeout+)
    (dexador.error:http-request-failed (failure)
      (error 'enchiridion.errors:transport-error
             :status (dexador.error:response-status failure)
             :detail (format nil "The Google token endpoint refused the exchange: ~A"
                             (gcp-token-error-detail
                              (dexador.error:response-body failure)))))))

;; The transport is a special so a test can drive the whole token flow without
;; a socket, and so the JWT the exchange produced can be read back off the wire.
(defparameter *gcp-token-post-function* #'gcp-token-http-post
  "The function GCP-ACCESS-TOKEN uses to exchange a JWT, called with the token
URL and the form body. Bound in tests.")

(declaim (ftype (function (list string integer) string) gcp-exchange-access-token))

(defun gcp-exchange-access-token (account client-email now)
  "Exchange a freshly signed assertion for an access token and cache it.

The assertion is signed with the account's private key, and the form carries
Google's grant type with the assertion. The grant type is written percent
encoded because it holds a colon and slashes; the assertion needs no encoding
because base64url and a period are all unreserved characters, and URL encoding
it would only risk mangling a value the endpoint compares byte for byte."
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
  "Return a token the operator already minted, or NIL.

Each name is looked up in the secret loader and then the environment, in the
order the names are listed, so GOOGLE_VERTEX_ACCESS_TOKEN wins over
GCLOUD_ACCESS_TOKEN even when both are set."
  (loop for name in +gcp-access-token-variables+
        for value = (gcp-setting name)
        when value return value))

(declaim (ftype (function (&key) string) gcp-access-token))

(defun gcp-access-token (&key)
  "Return a Google Cloud access token.

A static token is used as it is; otherwise the service account is read, an
assertion is signed, and the exchange is made once and cached until it is
close to expiring. The precedence is the operator's token first, because a
process that was handed a credential must not mint a different one."
  (or (gcp-static-access-token)
      (let ((now (funcall *gcp-clock*)))
        (or (gcp-cached-access-token now)
            (let* ((account (gcp-service-account))
                   (client-email (gcp-service-account-field
                                  account :client_email "client_email")))
              (gcp-exchange-access-token account client-email now))))))

;;;; The shared scheme.
;;;;
;;;; AUTH.CL dispatches :GCP-OAUTH to whatever this table holds, so a handler
;;;; that goes through the dialect path gets its Authorization header here and
;;;; nothing above has to know that a token endpoint exists. The Vertex
;;;; handler builds the same header from GCP-ACCESS-TOKEN directly, because
;;;; nothing in its request is signed and the round trip through a dialect
;;;; would buy it nothing; the test that both produce the same header is what
;;;; keeps the two spellings from drifting.

(register-auth-signer
 :gcp-oauth
 (lambda (dialect key request)
   "Return the Authorization header a Google OAuth request carries."
   (declare (ignore dialect key request))
   (list (cons :authorization (format nil "Bearer ~A" (gcp-access-token))))))
