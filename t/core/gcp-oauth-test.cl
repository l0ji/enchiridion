;;;; gcp-oauth-test.cl --- Google Cloud credentials, with no network at all.
;;;;
;;;; The whole flow is driven through the three specials the file under test
;;;; offers: the clock, the one POST, and the cache. Nothing here opens a
;;;; socket, and nothing here reads a real service account.
;;;;
;;;; The service account fixture is built rather than embedded. A real test key
;;;; checked into the tree is a key that is worth exactly nothing but still
;;;; looks like one, and a key generated here proves more: the whole PKCS#8
;;;; path is exercised against a key whose numbers this test knows, and the
;;;; signature is verified against the matching public key with the PKCS#1
;;;; padding written out independently of the code that produced it.
;;;;
;;;; The assertions on the JWT are on the bytes: the header and the claims are
;;;; decoded back out of base64url, and the signature is checked by recovering
;;;; the PKCS#1 v1.5 block with the public exponent and comparing it to a block
;;;; this file builds from the digest. A test that only asked the signer
;;;; whether it liked its own answer would pass for a signature Google rejects.

(defpackage #:enchiridion-gcp-oauth-test
  (:use #:cl)
  (:import-from #:rove #:deftest #:ok #:ng #:testing #:signals)
  (:export #:run))

(in-package #:enchiridion-gcp-oauth-test)

;;;; Scratch space.

(defmacro with-scratch-directory ((name &key (prefix "enchiridion-gcp-oauth-test-"))
                                  &body body)
  "Bind NAME to a fresh temporary directory, run BODY, then remove it.

Scratch lives under *DEFAULT-PATHNAME-DEFAULTS* and not under TMPDIR, for the
reason testing.md gives and secrets-test.cl already relies on: a nix build
sandbox has no writable /tmp, and a service account fixture has to be written
somewhere before it can be read back."
  `(let ((,name (uiop:ensure-directory-pathname
                 (merge-pathnames
                  (format nil "~A~D" ,prefix (random most-positive-fixnum))
                  (uiop:ensure-directory-pathname *default-pathname-defaults*)))))
     (unwind-protect
          (progn ,@body)
       (uiop:delete-directory-tree ,name :validate t :if-does-not-exist :ignore))))

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

;;;; The test key.

;; Generated once when this file loads. 2048 bits is what a Google service
;; account carries, so the DER reader meets the same long form lengths a real
;; key has; a 512 bit key would fit in the short form and prove less.
(defparameter *test-key-pair*
  (multiple-value-list (ironclad:generate-key-pair :rsa :num-bits 2048))
  "A private key and its public key, generated for this run.")

(defparameter *test-private-key* (first *test-key-pair*)
  "The key the fixture's private_key field holds.")

(defparameter *test-public-key* (second *test-key-pair*)
  "The key the signature is verified against. It is never in the fixture.")

(defparameter *client-email* "vertex-runner@demo-project.iam.gserviceaccount.com"
  "The address the fixture names as its issuer.")

(defparameter *issued-at* 1700000000
  "The instant every test's clock reports, so the JWT is the same every run.")

(defparameter *token-reply*
  "{\"access_token\":\"ya29.test-token\",\"expires_in\":3600,\"token_type\":\"Bearer\"}"
  "What the injected token endpoint answers a good assertion with.")

(defparameter *rejected-reply*
  "{\"error\":\"invalid_grant\",\"error_description\":\"Invalid JWT Signature.\"}"
  "What the injected token endpoint answers a bad assertion with.")

;;;; DER, so a PKCS#8 PEM can be built rather than embedded.

(declaim (ftype (function (integer) (vector (unsigned-byte 8))) der-length))

(defun der-length (length)
  "Return LENGTH as a DER length field: one byte under 128, else the long form."
  (if (< length #x80)
      (make-array 1 :element-type '(unsigned-byte 8) :initial-element length)
      (let ((octets (ironclad:integer-to-octets length)))
        (concatenate '(vector (unsigned-byte 8))
                     (make-array 1 :element-type '(unsigned-byte 8)
                                   :initial-element (+ #x80 (length octets)))
                     octets))))

(declaim (ftype (function (integer (vector (unsigned-byte 8)))
                          (vector (unsigned-byte 8)))
                der-element))

(defun der-element (tag content)
  "Return TAG and CONTENT as one DER element."
  (concatenate '(vector (unsigned-byte 8))
               (make-array 1 :element-type '(unsigned-byte 8) :initial-element tag)
               (der-length (length content))
               content))

(declaim (ftype (function (integer) (vector (unsigned-byte 8))) der-integer))

(defun der-integer (value)
  "Return VALUE as a DER INTEGER.

DER integers are signed and big endian, so a leading zero goes in front of a
value whose top bit is set, and zero is one zero byte rather than none."
  (let* ((octets (ironclad:integer-to-octets value))
         (content (cond
                    ((zerop (length octets))
                     (make-array 1 :element-type '(unsigned-byte 8)
                                   :initial-element 0))
                    ((>= (aref octets 0) #x80)
                     (concatenate '(vector (unsigned-byte 8))
                                  (make-array 1 :element-type '(unsigned-byte 8)
                                                :initial-element 0)
                                  octets))
                    (t octets))))
    (der-element #x02 content)))

(declaim (ftype (function (integer integer) integer) modular-inverse))

(defun modular-inverse (value modulus)
  "Return the inverse of VALUE modulo MODULUS, by the extended Euclid.

PKCS#1 stores q^-1 mod p as its last number, and writing a key that leaves that
field out would produce a fixture a real reader rejects while this tree's
reader, which stops at the sixth number, accepted it anyway."
  (let ((old-r value) (r modulus)
        (old-s 1) (s 0))
    (loop while (plusp r)
          do (let ((quotient (floor old-r r)))
               (psetf old-r r r (- old-r (* quotient r)))
               (psetf old-s s s (- old-s (* quotient s)))))
    (mod old-s modulus)))

(declaim (ftype (function (string (vector (unsigned-byte 8))) string) pem-block))

(defun pem-block (label der)
  "Return DER as a PEM block with LABEL, wrapped at 64 columns."
  (let* ((base64 (cl-base64:usb8-array-to-base64-string der))
         (lines '()))
    (loop for start from 0 below (length base64) by 64
          do (push (subseq base64 start (min (length base64) (+ start 64)))
                   lines))
    (format nil "-----BEGIN ~A-----~%~{~A~%~}-----END ~A-----~%"
            label (nreverse lines) label)))

(declaim (ftype (function () string) service-account-private-key-pem))

(defun service-account-private-key-pem ()
  "Return the test key as the PKCS#8 PEM a service account file holds.

PrivateKeyInfo is a SEQUENCE of the version, the rsaEncryption algorithm
identifier, and an OCTET STRING that holds the PKCS#1 RSAPrivateKey. That inner
key has nine INTEGERs and this test writes all nine, so the fixture is a real
key and not one shaped to fit the reader."
  (let* ((modulus (ironclad:rsa-key-modulus *test-private-key*))
         (exponent (ironclad:rsa-key-exponent *test-private-key*))
         (public-exponent (ironclad:rsa-key-exponent *test-public-key*))
         (prime-1 (ironclad:rsa-key-prime-p *test-private-key*))
         (prime-2 (ironclad:rsa-key-prime-q *test-private-key*))
         (rsa (der-element
               #x30
               (concatenate
                '(vector (unsigned-byte 8))
                (der-integer 0)
                (der-integer modulus)
                (der-integer public-exponent)
                (der-integer exponent)
                (der-integer prime-1)
                (der-integer prime-2)
                (der-integer (mod exponent (1- prime-1)))
                (der-integer (mod exponent (1- prime-2)))
                (der-integer (modular-inverse prime-2 prime-1)))))
         (oid (der-element #x06 (make-array 9 :element-type '(unsigned-byte 8)
                                              :initial-contents '(#x2a #x86 #x48
                                                                  #x86 #xf7 #x0d
                                                                  #x01 #x01 #x01))))
         (null (der-element #x05 (make-array 0 :element-type '(unsigned-byte 8))))
         (algorithm (der-element #x30 (concatenate '(vector (unsigned-byte 8))
                                                   oid null))))
    (pem-block "PRIVATE KEY"
               (der-element #x30 (concatenate '(vector (unsigned-byte 8))
                                              (der-integer 0)
                                              algorithm
                                              (der-element #x04 rsa))))))

;;;; The service account JSON.

(declaim (ftype (function (string) string) service-account-text))

(defun service-account-text (private-key-pem)
  "Return a service account file holding PRIVATE-KEY-PEM."
  (enchiridion.llm:stringify
   (enchiridion.llm::json-object
    :type "service_account"
    :project_id "demo-project"
    :private_key_id "0123456789abcdef"
    :private_key private-key-pem
    :client_email *client-email*
    :client_id "100000000000000000000"
    :token_uri "https://oauth2.googleapis.com/token")))

;;;; base64url, read back.

(declaim (ftype (function (string) string) padded-base64url))

(defun padded-base64url (text)
  "Return TEXT, base64url, as standard base64 with its padding restored."
  (let* ((standard (substitute #\+ #\- (substitute #\/ #\_ text)))
         (remainder (mod (length standard) 4))
         (padding (if (zerop remainder) 0 (- 4 remainder))))
    (concatenate 'string standard (make-string padding :initial-element #\=))))

(declaim (ftype (function (string) string) unbase64url))

(defun unbase64url (text)
  "Return TEXT, base64url, as the string it encodes."
  (cl-base64:base64-string-to-string (padded-base64url text)))

(declaim (ftype (function (string) (vector (unsigned-byte 8))) unbase64url-octets))

(defun unbase64url-octets (text)
  "Return TEXT, base64url, as the octets it encodes."
  (cl-base64:base64-string-to-usb8-array (padded-base64url text)))

;;;; Verifying the signature the way a provider would.

(defparameter +sha256-digest-info+
  (make-array 19 :element-type '(unsigned-byte 8)
                 :initial-contents '(#x30 #x31 #x30 #x0d #x06 #x09 #x60 #x86
                                     #x48 #x01 #x65 #x03 #x04 #x02 #x01 #x05
                                     #x00 #x04 #x20))
  "RFC 8017's DigestInfo prefix for SHA-256, written out here rather than read
from the code under test so that a wrong prefix cannot verify itself.")

(declaim (ftype (function (ironclad:rsa-public-key string
                           (vector (unsigned-byte 8)))
                          boolean)
                verify-rs256))

(defun verify-rs256 (public-key signing-input signature)
  "Return T when SIGNATURE is an RS256 signature of SIGNING-INPUT under PUBLIC-KEY.

The recovered block is built here from the digest and compared byte for byte,
which is what RSASSA-PKCS1-v1_5 verification is. Ironclad's own verify-signature
is the bare RSA primitive and would compare the signature against the message
itself, which is not RS256 and would accept a signature no endpoint does."
  (let* ((modulus (ironclad:rsa-key-modulus public-key))
         (exponent (ironclad:rsa-key-exponent public-key))
         (size (ceiling (integer-length modulus) 8))
         (digest (ironclad:digest-sequence
                  :sha256
                  (ironclad:ascii-string-to-byte-array signing-input)))
         (padding (- size (+ (length +sha256-digest-info+) (length digest)) 3)))
    (and (= size (length signature))
         (not (minusp padding))
         (let ((expected (make-array size :element-type '(unsigned-byte 8)))
               (recovered (ironclad:integer-to-octets
                           (ironclad:expt-mod
                            (ironclad:octets-to-integer signature)
                            exponent modulus)
                           :n-bits (* 8 size))))
           (setf (aref expected 0) 0)
           (setf (aref expected 1) 1)
           (fill expected #xff :start 2 :end (+ 2 padding))
           (setf (aref expected (+ 2 padding)) 0)
           (replace expected +sha256-digest-info+ :start1 (+ 3 padding))
           (replace expected digest :start1 (+ 3 padding
                                                 (length +sha256-digest-info+)))
           (equalp expected recovered)))))

;;;; Driving the flow.

(defmacro with-service-account ((path) &body body)
  "Point GOOGLE_APPLICATION_CREDENTIALS at PATH for BODY, then forget it."
  `(unwind-protect
        (progn
          (enchiridion.llm.secrets:clear-secrets)
          (enchiridion.llm.secrets:register-secret "GOOGLE_APPLICATION_CREDENTIALS"
                                                   ,path)
          ,@body)
     (enchiridion.llm.secrets:clear-secrets)))

(defmacro with-empty-environment (&body body)
  "Unset every variable this file reads for BODY, then restore nothing.

The three names are unset rather than assumed absent, because a developer
machine that really does have GOOGLE_APPLICATION_CREDENTIALS exported must not
turn the missing-credential test green for the wrong reason."
  `(unwind-protect
        (progn
          (dolist (name (list enchiridion.llm::+gcp-credentials-variable+
                              "GOOGLE_VERTEX_ACCESS_TOKEN"
                              "GCLOUD_ACCESS_TOKEN"))
            (enchiridion.compat:unset-environment-variable name))
          (enchiridion.llm.secrets:clear-secrets)
          ,@body)
     (enchiridion.llm.secrets:clear-secrets)))

;;;; The static token.

(deftest a-token-the-operator-minted-is-used-as-it-is ()
  (with-empty-environment
    (let ((enchiridion.llm::*gcp-token-cache* nil)
          (enchiridion.llm::*gcp-token-post-function*
            (lambda (url body)
              (declare (ignore url body))
              (error "the static token path must not exchange anything"))))
      (enchiridion.llm.secrets:register-secret "GCLOUD_ACCESS_TOKEN"
                                               "ya29.from-gcloud")
      (ok (string= "ya29.from-gcloud" (enchiridion.llm::gcp-access-token)))
      (testing "and the Vertex-specific name wins when both are set"
        (enchiridion.llm.secrets:register-secret "GOOGLE_VERTEX_ACCESS_TOKEN"
                                                 "ya29.from-vertex")
        (ok (string= "ya29.from-vertex" (enchiridion.llm::gcp-access-token)))))))

(deftest a-token-in-the-environment-is-read-when-the-store-has-none ()
  (with-empty-environment
    (let ((enchiridion.llm::*gcp-token-cache* nil))
      (enchiridion.compat:set-environment-variable "GOOGLE_VERTEX_ACCESS_TOKEN"
                                                   "ya29.from-the-environment")
      (unwind-protect
           (ok (string= "ya29.from-the-environment"
                        (enchiridion.llm::gcp-access-token)))
        (enchiridion.compat:unset-environment-variable
         "GOOGLE_VERTEX_ACCESS_TOKEN")))))

;;;; The service account.

(deftest a-service-account-signs-a-jwt-a-provider-would-accept ()
  (with-scratch-directory (directory)
    (let* ((path (write-fixture (merge-pathnames "account.json" directory)
                                (service-account-text
                                 (service-account-private-key-pem))))
           (form nil)
           (url nil)
           (posts 0))
      (with-service-account ((namestring path))
        (let ((enchiridion.llm::*gcp-token-cache* nil)
              (enchiridion.llm::*gcp-clock* (lambda () *issued-at*))
              (enchiridion.llm::*gcp-token-post-function*
                (lambda (token-url body)
                  (incf posts)
                  (setf url token-url)
                  (setf form body)
                  *token-reply*)))
          (ok (string= "ya29.test-token" (enchiridion.llm::gcp-access-token)))
          (ok (= 1 posts))
          (ok (string= enchiridion.llm::+gcp-token-url+ url))
          (testing "the form asks for a JWT bearer grant and carries the assertion"
            (ok (search "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer"
                        form))
            (ok (search "&assertion=" form))))))))

(deftest the-assertion-decodes-to-the-claims-google-checks ()
  (with-scratch-directory (directory)
    (let* ((path (write-fixture (merge-pathnames "account.json" directory)
                                (service-account-text
                                 (service-account-private-key-pem))))
           (assertion nil))
      (with-service-account ((namestring path))
        (let ((enchiridion.llm::*gcp-token-cache* nil)
              (enchiridion.llm::*gcp-clock* (lambda () *issued-at*))
              (enchiridion.llm::*gcp-token-post-function*
                (lambda (url body)
                  (declare (ignore url))
                  (setf assertion (subseq body (+ (search "assertion=" body)
                                                  (length "assertion="))))
                  *token-reply*)))
          (enchiridion.llm::gcp-access-token)))
      (let* ((parts (uiop:split-string assertion :separator "."))
             (header (enchiridion.llm:parse-json (unbase64url (first parts))))
             (claims (enchiridion.llm:parse-json (unbase64url (second parts)))))
        (testing "three parts, because a JWT is header, claims and signature"
          (ok (= 3 (length parts))))
        (testing "the header names RS256 and the JWT type"
          (ok (string= "RS256" (getf header :alg)))
          (ok (string= "JWT" (getf header :typ))))
        (testing "the claims are the issuer, the scope, the audience and the hour"
          (ok (string= *client-email* (getf claims :iss)))
          (ok (string= enchiridion.llm::+gcp-scope+ (getf claims :scope)))
          (ok (string= enchiridion.llm::+gcp-token-url+ (getf claims :aud)))
          (ok (eql *issued-at* (getf claims :iat)))
          (ok (eql (+ *issued-at* enchiridion.llm::+gcp-jwt-lifetime+)
                   (getf claims :exp))))
        (testing "and the signature is a real PKCS#1 v1.5 RS256 signature"
          (ok (verify-rs256 *test-public-key*
                            (format nil "~A.~A" (first parts) (second parts))
                            (unbase64url-octets (third parts))))
          (testing "which means a tampered claim does not verify"
            (ng (verify-rs256 *test-public-key*
                              (format nil "~A.~A" (second parts) (first parts))
                              (unbase64url-octets (third parts))))))))))

(deftest an-exchanged-token-is-cached-until-it-is-close-to-expiring ()
  (with-scratch-directory (directory)
    (let* ((path (write-fixture (merge-pathnames "account.json" directory)
                                (service-account-text
                                 (service-account-private-key-pem))))
           (posts 0)
           (now *issued-at*)
           ;; What the fixture's expires_in of 3600 becomes once the safety
           ;; margin is taken off. It is computed from the constant rather than
           ;; written out, so a margin that changes moves this test with it
           ;; instead of leaving it green about a rule nobody follows any more.
           (expiry (+ *issued-at*
                      (- 3600 enchiridion.llm::+gcp-token-safety-margin+))))
      (with-service-account ((namestring path))
        (let ((enchiridion.llm::*gcp-token-cache* nil)
              (enchiridion.llm::*gcp-clock* (lambda () now))
              (enchiridion.llm::*gcp-token-post-function*
                (lambda (url body)
                  (declare (ignore url body))
                  (incf posts)
                  *token-reply*)))
          (testing "the first call exchanges once"
            (ok (string= "ya29.test-token" (enchiridion.llm::gcp-access-token)))
            (ok (= 1 posts)))
          (testing "the second call is answered from the cache"
            (ok (string= "ya29.test-token" (enchiridion.llm::gcp-access-token)))
            (ok (= 1 posts)))
          (testing "one second before the margin expires, it is still cached"
            (setf now (1- expiry))
            (ok (string= "ya29.test-token" (enchiridion.llm::gcp-access-token)))
            (ok (= 1 posts)))
          (testing "at the expiry instant it is exchanged again"
            (setf now expiry)
            (ok (string= "ya29.test-token" (enchiridion.llm::gcp-access-token)))
            (ok (= 2 posts)))
          (testing "and the refreshed token is cached in its turn"
            (ok (string= "ya29.test-token" (enchiridion.llm::gcp-access-token)))
            (ok (= 2 posts))))))))

(deftest a-rejected-exchange-carries-the-providers-own-message ()
  (with-scratch-directory (directory)
    (let ((path (write-fixture (merge-pathnames "account.json" directory)
                               (service-account-text
                                (service-account-private-key-pem)))))
      (with-service-account ((namestring path))
        (let ((enchiridion.llm::*gcp-token-cache* nil)
              (enchiridion.llm::*gcp-clock* (lambda () *issued-at*))
              (enchiridion.llm::*gcp-token-post-function*
                (lambda (url body)
                  (declare (ignore url body))
                  *rejected-reply*)))
          (handler-case
              (progn
                (enchiridion.llm::gcp-access-token)
                (ng t "a reply with no access token must signal"))
            (enchiridion.errors:backend-error (condition)
              (ok (string= "gcp" (enchiridion.errors::error-backend condition)))
              (ok (search "Invalid JWT Signature."
                          (enchiridion.errors:error-detail condition))))))))))

(deftest a-reply-that-is-not-json-is-a-backend-error ()
  (with-scratch-directory (directory)
    (let ((path (write-fixture (merge-pathnames "account.json" directory)
                               (service-account-text
                                (service-account-private-key-pem)))))
      (with-service-account ((namestring path))
        (let ((enchiridion.llm::*gcp-token-cache* nil)
              (enchiridion.llm::*gcp-clock* (lambda () *issued-at*))
              (enchiridion.llm::*gcp-token-post-function*
                (lambda (url body)
                  (declare (ignore url body))
                  "<html>a proxy answered</html>")))
          (ok (signals (enchiridion.llm::gcp-access-token)
                       'enchiridion.errors:backend-error)))))))

;;;; The configuration failures.

(deftest no-credential-at-all-names-the-setting-that-is-missing ()
  (with-empty-environment
    (let ((enchiridion.llm::*gcp-token-cache* nil))
      (handler-case
          (progn
            (enchiridion.llm::gcp-access-token)
            (ng t "no credential must signal"))
        (enchiridion.errors:configuration-error (condition)
          (ok (eq :gcp-credentials
                  (enchiridion.errors::configuration-key condition)))
          (ok (search "GOOGLE_APPLICATION_CREDENTIALS"
                      (enchiridion.errors:error-detail condition)))
          (testing "and it names the token variables too"
            (ok (search "GOOGLE_VERTEX_ACCESS_TOKEN"
                        (enchiridion.errors:error-detail condition)))))))))

(deftest a-credentials-file-that-is-not-there-is-a-configuration-error ()
  (with-empty-environment
    (with-service-account ("/nonexistent/enchiridion/account.json")
      (let ((enchiridion.llm::*gcp-token-cache* nil))
        (handler-case
            (progn
              (enchiridion.llm::gcp-access-token)
              (ng t "a missing file must signal"))
          (enchiridion.errors:configuration-error (condition)
            (ok (eq :gcp-credentials
                    (enchiridion.errors::configuration-key condition)))
            (ok (search "does not exist"
                        (enchiridion.errors:error-detail condition)))))))))

(deftest a-credentials-file-that-is-not-json-is-a-configuration-error ()
  (with-scratch-directory (directory)
    (let ((path (write-fixture (merge-pathnames "broken.json" directory)
                               "this is not a service account")))
      (with-service-account ((namestring path))
        (let ((enchiridion.llm::*gcp-token-cache* nil))
          (handler-case
              (progn
                (enchiridion.llm::gcp-access-token)
                (ng t "unparseable JSON must signal"))
            (enchiridion.errors:configuration-error (condition)
              (ok (eq :gcp-credentials
                      (enchiridion.errors::configuration-key condition)))
              (ok (search "could not be read as JSON"
                          (enchiridion.errors:error-detail condition))))))))))

(deftest a-private-key-that-is-not-a-pem-block-is-a-configuration-error ()
  (with-scratch-directory (directory)
    (let ((path (write-fixture (merge-pathnames "account.json" directory)
                               (service-account-text "not a pem block"))))
      (with-service-account ((namestring path))
        (let ((enchiridion.llm::*gcp-token-cache* nil))
          (handler-case
              (progn
                (enchiridion.llm::gcp-access-token)
                (ng t "a non-PEM key must signal"))
            (enchiridion.errors:configuration-error (condition)
              (ok (eq :gcp-credentials
                      (enchiridion.errors::configuration-key condition)))
              (ok (search "PEM" (enchiridion.errors:error-detail condition))))))))))

(deftest a-service-account-with-no-client-email-is-a-configuration-error ()
  (with-scratch-directory (directory)
    (let ((path (write-fixture (merge-pathnames "account.json" directory)
                               (enchiridion.llm:stringify
                                (enchiridion.llm::json-object
                                 :type "service_account"
                                 :private_key
                                 (service-account-private-key-pem))))))
      (with-service-account ((namestring path))
        (let ((enchiridion.llm::*gcp-token-cache* nil))
          (handler-case
              (progn
                (enchiridion.llm::gcp-access-token)
                (ng t "a missing client_email must signal"))
            (enchiridion.errors:configuration-error (condition)
              (ok (search "client_email"
                          (enchiridion.errors:error-detail condition))))))))))

;;;; The shared auth scheme.

(deftest the-gcp-oauth-scheme-is-registered-and-writes-a-bearer-header ()
  (let ((signer (enchiridion.llm:find-auth-signer :gcp-oauth)))
    (ok (functionp signer))
    (with-empty-environment
      (let ((enchiridion.llm::*gcp-token-cache* nil))
        (enchiridion.llm.secrets:register-secret "GOOGLE_VERTEX_ACCESS_TOKEN"
                                                 "ya29.bearer")
        (let ((headers (funcall signer nil nil nil)))
          (ok (string= "Bearer ya29.bearer"
                       (cdr (assoc :authorization headers)))))))))
