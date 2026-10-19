;;;; aws-sigv4-test.cl --- Signature Version 4 against AWS's published vectors.
;;;;
;;;; The fixtures below are AWS's own test suite, verbatim: the request, the
;;;; canonical request, the string to sign and the Authorization header the
;;;; service expects. Nothing here opens a socket or reads a key from the
;;;; process environment; the credential, the clock and the transport are all
;;;; injected. A signature that equals a published one is right for a reason no
;;;; local round trip could establish.
;;;;
;;;; The vectors predate the x-amz-content-sha256 header, so they are signed
;;;; with CONTENT-SHA256-P off. That is the only difference between them and a
;;;; real Bedrock call, and it is asserted below rather than hidden.

(defpackage #:enchiridion-aws-sigv4-test
  (:use #:cl)
  (:import-from #:rove #:deftest #:ok #:ng #:testing #:signals)
  (:export #:run))

(in-package #:enchiridion-aws-sigv4-test)

;;;; Helpers.

(defun header (headers name)
  "Return the value of header NAME in HEADERS, or NIL.

Names are compared case-insensitively, which is what an HTTP header is: the
signer writes keywords and dexador writes strings, and a test that only looks
for one spelling is a test that misses a duplicated header."
  (cdr (assoc name headers :test #'string-equal)))

(defun lines (&rest lines)
  "Return LINES joined by newlines, so a fixture can show an empty line.

A string literal cannot be continued with a backslash: the newline after a
single escape is part of the string, so the usual pretty-printed fixture quietly
gains a blank line where the source wrapped and every hash over it changes."
  (format nil "~{~A~^~%~}" lines))

(defmacro with-environment ((name value) &body body)
  "Run BODY with environment variable NAME set to VALUE, then restore it.

A VALUE of NIL removes the variable, and the previous value is always put back,
because a test that leaks an AWS_REGION into the next suite is a test that fails
somewhere else."
  `(let ((previous (enchiridion.compat:environment-value ,name)))
     (unwind-protect
          (progn
            (if ,value
                (enchiridion.compat:set-environment-variable ,name ,value)
                (enchiridion.compat:unset-environment-variable ,name))
            ,@body)
       (if previous
           (enchiridion.compat:set-environment-variable ,name previous)
           (enchiridion.compat:unset-environment-variable ,name)))))

(defmacro signaled-key (form)
  "Return the :key of the CONFIGURATION-ERROR FORM signals, or NIL.

NIL when FORM returns normally, so the assertion that reads it fails rather
than passes when nothing was signalled at all."
  `(handler-case (progn ,form nil)
     (enchiridion.errors:configuration-error (condition)
       (enchiridion.errors::configuration-key condition))))

;;;; The published vectors.

(defparameter *vector-region* "us-east-1"
  "The region every vector in AWS's suite signs for.")

(defparameter *vector-service* "service"
  "The service name every vector in AWS's suite signs for.")

(defparameter *vector-access-key* "AKIDEXAMPLE"
  "The access key AWS's published vectors sign with.")

(defparameter *vector-secret-key* "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
  "The secret key AWS's published vectors sign with. Published, and not a key
anybody has ever used: it is the example in AWS's own documentation.")

(defparameter *vector-time* (encode-universal-time 0 36 12 30 8 2015 0)
  "20150830T123600Z as a universal time, which is the instant every vector is
signed at.")

(defparameter *empty-body-hash*
  "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  "SHA-256 of the empty string, as AWS's vectors print it.")

(defun vector-credential (&optional session-token)
  "Return the credential AWS's published vectors sign with."
  (enchiridion.llm::make-aws-credential :access-key *vector-access-key*
                                        :secret-key *vector-secret-key*
                                        :session-token session-token))

(defun sign-vector (vector &key (time *vector-time*) (content-sha256-p nil))
  "Return the headers SIGN-REQUEST produces for VECTOR, a published case.

CONTENT-SHA256-P is off for a published vector, because the suite was recorded
before that header existed and the signature covers the signed header list."
  (enchiridion.llm::sign-request
   (enchiridion.llm::make-http-request :url (getf vector :url)
                                       :body (getf vector :body)
                                       :headers (getf vector :headers)
                                       :timeout 10)
   *vector-region* *vector-service*
   :credentials (vector-credential)
   :time (getf vector :time time)
   :method (getf vector :method)
   :content-sha256-p content-sha256-p))

(defun sign-request-for (url)
  "Return the headers SIGN-REQUEST produces for URL with the vector credential.

The shape every header test signs: no body, no extra headers, the published
instant and the published credential. It is defined before the tests that use
it, because a test body is compiled and an undefined function inside one is a
warning, which this project makes an error."
  (enchiridion.llm::sign-request
   (enchiridion.llm::make-http-request :url url :body "" :headers '() :timeout 10)
   *vector-region* *vector-service*
   :credentials (vector-credential)
   :time *vector-time*))

;; get-vanilla: the empty canonical request. It is the only vector whose string
;; to sign is published in full here, and it is the one that proves the empty
;; body hash, the blank query line and the trailing newline of the header block.
(defparameter *get-vanilla*
  (list :name "get-vanilla"
        :method "GET"
        :url "https://example.amazonaws.com/"
        :path "/"
        :query ""
        :headers '()
        :canonical-headers '(("Host" . "example.amazonaws.com")
                             ("X-Amz-Date" . "20150830T123600Z"))
        :body ""
        :payload-hash *empty-body-hash*
        :canonical-request
        (lines "GET" "/" ""
               "host:example.amazonaws.com" "x-amz-date:20150830T123600Z" ""
               "host;x-amz-date" *empty-body-hash*)
        :string-to-sign
        (lines "AWS4-HMAC-SHA256" "20150830T123600Z"
               "20150830/us-east-1/service/aws4_request"
               "bb579772317eb040ac9ed261061d46c1f17a8133879d6129b6e1c25292927e63")
        :authorization
        "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")
  "get-vanilla: no query, no body, two headers.")

;; get-vanilla-query-order-key-case: the parameters are given in the wrong order
;; and must be sorted. Sorting is by encoded byte, which is why the uppercase
;; Param1 sorts before Param2 but after every lowercase name would.
(defparameter *query-order*
  (list :name "get-vanilla-query-order-key-case"
        :method "GET"
        :url "https://example.amazonaws.com/?Param2=value2&Param1=value1"
        :path "/"
        :query "Param2=value2&Param1=value1"
        :headers '()
        :canonical-headers '(("Host" . "example.amazonaws.com")
                             ("X-Amz-Date" . "20150830T123600Z"))
        :body ""
        :payload-hash *empty-body-hash*
        :canonical-request
        (lines "GET" "/" "Param1=value1&Param2=value2"
               "host:example.amazonaws.com" "x-amz-date:20150830T123600Z" ""
               "host;x-amz-date" *empty-body-hash*)
        :authorization
        "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=b97d918cfa904a5beff61c982a1b6f458b799221646efd99d3219ec94cdf2500")
  "get-vanilla-query-order-key-case: the same request with a sorted query.")

;; post-x-www-form-urlencoded: a body that is not signed as a string but hashed,
;; and a content-type header that is part of the signed set.
(defparameter *urlencoded-post*
  (list :name "post-x-www-form-urlencoded"
        :method "POST"
        :url "https://example.amazonaws.com/"
        :path "/"
        :query ""
        :headers '(("Content-Type" . "application/x-www-form-urlencoded"))
        :canonical-headers
        '(("Content-Type" . "application/x-www-form-urlencoded")
          ("Host" . "example.amazonaws.com")
          ("X-Amz-Date" . "20150830T123600Z"))
        :body "Param1=value1"
        :payload-hash
        "9095672bbd1f56dfc5b65f3e153adc8731a4a654192329106275f4c7b24d0b6e"
        :canonical-request
        (lines "POST" "/" ""
               "content-type:application/x-www-form-urlencoded"
               "host:example.amazonaws.com" "x-amz-date:20150830T123600Z" ""
               "content-type;host;x-amz-date"
               "9095672bbd1f56dfc5b65f3e153adc8731a4a654192329106275f4c7b24d0b6e")
        :authorization
        "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=content-type;host;x-amz-date, Signature=ff11897932ad3f4e8b18135d722051e5ac45fc38421b1da7b9d196a0fe09473a")
  "post-x-www-form-urlencoded: a form body and a content type.")

;; get-header-value-trim: the request carries ' value1' and '"a   b   c"', and
;; the canonical form is 'value1' and '"a b c"'. Trimming is not enough; the
;; internal run of spaces has to collapse too.
(defparameter *header-trim*
  (list :name "get-header-value-trim"
        :method "GET"
        :url "https://example.amazonaws.com/"
        :path "/"
        :query ""
        :headers '(("My-Header1" . " value1")
                   ("My-Header2" . " \"a   b   c\""))
        :canonical-headers '(("Host" . "example.amazonaws.com")
                             ("My-Header1" . " value1")
                             ("My-Header2" . " \"a   b   c\"")
                             ("X-Amz-Date" . "20150830T123600Z"))
        :body ""
        :payload-hash *empty-body-hash*
        :canonical-request
        (lines "GET" "/" ""
               "host:example.amazonaws.com" "my-header1:value1"
               "my-header2:\"a b c\"" "x-amz-date:20150830T123600Z" ""
               "host;my-header1;my-header2;x-amz-date" *empty-body-hash*)
        :authorization
        "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;my-header1;my-header2;x-amz-date, Signature=acc3ed3afb60bb290fc8d2dd0098b9911fcaa05412b367055dee359757a9c736")
  "get-header-value-trim: whitespace in a header value, canonicalised.")

(defun published-vectors ()
  "Return the four published vectors this file checks."
  (list *get-vanilla* *query-order* *urlencoded-post* *header-trim*))

;;;; The vectors, step by step.

(deftest the-published-canonical-requests-are-exact ()
  (dolist (vector (published-vectors))
    (testing (getf vector :name)
      (ok (string= (getf vector :canonical-request)
                   (enchiridion.llm::aws-canonical-request
                    (getf vector :method)
                    (getf vector :path)
                    (getf vector :query)
                    (getf vector :canonical-headers)
                    (getf vector :payload-hash)))))))

(deftest the-published-string-to-sign-is-exact ()
  (ok (string= (getf *get-vanilla* :string-to-sign)
               (enchiridion.llm::aws-string-to-sign
                (getf *get-vanilla* :canonical-request)
                "20150830T123600Z"
                "20150830/us-east-1/service/aws4_request"))))

(deftest the-published-signatures-are-exact ()
  (dolist (vector (published-vectors))
    (testing (getf vector :name)
      (ok (string= (getf vector :authorization)
                   (header (sign-vector vector) :authorization))))))

(deftest the-signature-comes-from-the-key-chain-and-not-from-the-secret ()
  (ok (string= (getf *get-vanilla* :authorization)
               (enchiridion.llm::aws-authorization
                *vector-access-key*
                "20150830/us-east-1/service/aws4_request"
                "host;x-amz-date"
                (enchiridion.llm::aws-signature
                 (getf *get-vanilla* :canonical-request)
                 "20150830T123600Z"
                 *vector-region*
                 *vector-service*
                 (vector-credential))))))

;;;; The headers a signed request carries.

(deftest the-content-sha256-header-is-the-hash-of-the-body ()
  (testing "the published form body hashes to the published digest"
    (let ((headers (enchiridion.llm::sign-request
                    (enchiridion.llm::make-http-request
                     :url "https://example.amazonaws.com/"
                     :body (getf *urlencoded-post* :body)
                     :headers '()
                     :timeout 10)
                    *vector-region* *vector-service*
                    :credentials (vector-credential)
                    :time *vector-time*)))
      (ok (string= (getf *urlencoded-post* :payload-hash)
                   (header headers :x-amz-content-sha256)))
      (testing "and AWS requires an x-amz header to be inside the signed set"
        (ok (search "x-amz-content-sha256"
                    (header headers :authorization))))))
  (testing "an empty body hashes to the digest the suite prints"
    (ok (string= *empty-body-hash*
                 (header (sign-vector *get-vanilla* :content-sha256-p t)
                         :x-amz-content-sha256))))
  (testing "and the published vectors are reproduced without it"
    (ng (header (sign-vector *get-vanilla*) :x-amz-content-sha256))))

(deftest a-session-token-is-a-signed-header ()
  (let ((headers (enchiridion.llm::sign-request
                  (enchiridion.llm::make-http-request
                   :url "https://bedrock-runtime.us-east-1.amazonaws.com/model/m/invoke"
                   :body "{}"
                   :headers '()
                   :timeout 10)
                  *vector-region* "bedrock"
                  :credentials (vector-credential "the-session-token")
                  :time *vector-time*)))
    (ok (string= "the-session-token" (header headers :x-amz-security-token)))
    (testing "and it is signed, not merely sent"
      (ok (search "x-amz-security-token" (header headers :authorization)))))
  (testing "a credential without one sends no such header"
    (let ((headers (sign-vector *get-vanilla*)))
      (ng (header headers :x-amz-security-token))
      (ng (search "x-amz-security-token" (header headers :authorization))))))

(deftest the-host-comes-from-the-url-and-is-always-signed ()
  (let ((headers (enchiridion.llm::sign-request
                  (enchiridion.llm::make-http-request
                   :url "https://bedrock-runtime.eu-west-1.amazonaws.com/model/m/invoke"
                   :body ""
                   :headers '()
                   :timeout 10)
                  "eu-west-1" "bedrock"
                  :credentials (vector-credential)
                  :time *vector-time*)))
    (ok (string= "bedrock-runtime.eu-west-1.amazonaws.com" (header headers :host)))
    (ok (string= "bedrock-runtime.eu-west-1.amazonaws.com"
                 (cdr (assoc "HOST" headers :test #'string-equal)))
        "one header, whatever case each side wrote it in"))
  (testing "a port is part of the authority AWS signs"
    (ok (string= "localhost:8443"
                 (header (sign-request-for "https://localhost:8443/model/m/invoke")
                         :host))))
  (testing "user information is not part of the host"
    (ok (string= "example.test"
                 (header (sign-request-for "https://user:password@example.test/path")
                         :host)))))

(deftest a-url-with-no-host-is-a-configuration-error ()
  (ok (eq :url (signaled-key (sign-request-for "https:///model/m/invoke"))))
  (testing "and a relative path is not a host either"
    (ok (eq :url (signaled-key (sign-request-for "file:///tmp/request"))))))

;;;; The URL.

(deftest url-parts-split-host-path-and-query ()
  (multiple-value-bind (host path query)
      (enchiridion.llm::aws-url-parts "https://bedrock.us-east-1.amazonaws.com/foundation-models?byProvider=anthropic")
    (ok (string= "bedrock.us-east-1.amazonaws.com" host))
    (ok (string= "/foundation-models" path))
    (ok (string= "byProvider=anthropic" query)))
  (testing "and a fragment is not part of the query"
    (multiple-value-bind (host path query)
        (enchiridion.llm::aws-url-parts "https://example.test/a/b?x=1#fragment")
      (ok (string= "example.test" host))
      (ok (string= "/a/b" path))
      (ok (string= "x=1" query))))
  (testing "a URL with a host and nothing else has an empty path"
    (multiple-value-bind (host path query)
        (enchiridion.llm::aws-url-parts "example.test")
      (declare (ignore host))
      (ok (string= "" path))
      (ok (string= "" query)))))

(deftest the-canonical-uri-is-the-path-as-sent ()
  (ok (string= "/" (enchiridion.llm::aws-canonical-uri "")))
  (ok (string= "/" (enchiridion.llm::aws-canonical-uri nil)))
  (testing "an escaped path is signed escaped, and not escaped twice"
    (ok (string= "/model/a%3A0/invoke"
                 (enchiridion.llm::aws-canonical-uri "/model/a%3A0/invoke"))))
  (testing "and a relative path gains the slash it lacks"
    (ok (string= "/model/a/invoke"
                 (enchiridion.llm::aws-canonical-uri "model/a/invoke")))))

;;;; The query string.

(deftest the-query-string-is-sorted-encoded-and-kept ()
  (ok (string= "a=0&a=1&b=2&empty=&enc=%2F&flag="
               (enchiridion.llm::aws-canonical-query-string
                "b=2&a=1&a=0&flag&empty=&enc=%2F"))
      "duplicate names sort by value, an empty value keeps its =")
  (testing "an absent query and an empty one are the same empty string"
    (ok (string= "" (enchiridion.llm::aws-canonical-query-string "")))
    (ok (string= "" (enchiridion.llm::aws-canonical-query-string nil))))
  (testing "a space is %20 and a plus is a plus"
    (ok (string= "q=a%20b" (enchiridion.llm::aws-canonical-query-string "q=a b")))
    (ok (string= "q=a%2Bb"
                 (enchiridion.llm::aws-canonical-query-string "q=a+b"))))
  (testing "an empty parameter between two separators is dropped"
    (ok (string= "a=1" (enchiridion.llm::aws-canonical-query-string "a=1&&")))))

(deftest the-encoding-rules-are-aws's ()
  (ok (string= "a%20b" (enchiridion.llm::aws-uri-encode "a b")))
  (testing "the unreserved set is left alone"
    (ok (string= "a-b_c.d~e" (enchiridion.llm::aws-uri-encode "a-b_c.d~e"))))
  (testing "a slash and a colon are not a path here"
    (ok (string= "%2F%3A" (enchiridion.llm::aws-uri-encode "/:"))))
  (testing "and a character outside ASCII is encoded as its UTF-8 bytes"
    (ok (string= "%C3%A9" (enchiridion.llm::aws-uri-encode
                           (string (code-char 233)))))))

;;;; The clock.

(deftest the-timestamp-is-utc ()
  (multiple-value-bind (stamp date) (enchiridion.llm::aws-timestamp *vector-time*)
    (ok (string= "20150830T123600Z" stamp))
    (ok (string= "20150830" date))))

(deftest the-signing-time-special-is-what-a-caller-with-no-time-gets ()
  (let ((enchiridion.llm::*signing-time* *vector-time*))
    (ok (string= (getf *get-vanilla* :authorization)
                 (header (sign-vector *get-vanilla* :time nil) :authorization)))))

;;;; Credentials.

(deftest a-missing-credential-names-the-key ()
  (let ((enchiridion.llm::*aws-credentials-function* (constantly nil)))
    (ok (eq :aws-credentials
            (signaled-key
             (enchiridion.llm::sign-request
              (enchiridion.llm::make-http-request
               :url "https://example.amazonaws.com/"
               :body ""
               :headers '()
               :timeout 10)
              *vector-region* *vector-service*
              :time *vector-time*))))
    (testing "and the detail says which variables would fix it"
      (handler-case
          (progn
            (enchiridion.llm::sign-request
             (enchiridion.llm::make-http-request
              :url "https://example.amazonaws.com/"
              :body ""
              :headers '()
              :timeout 10)
             *vector-region* *vector-service*
             :time *vector-time*)
            (ng t "signing must signal"))
        (enchiridion.errors:configuration-error (condition)
          (ok (search "AWS_ACCESS_KEY_ID"
                      (enchiridion.errors:error-detail condition))))))))

(deftest credentials-come-from-the-store-then-the-environment ()
  (enchiridion.llm.secrets:clear-secrets)
  (unwind-protect
       (progn
         (testing "with neither, there are none"
           (with-environment ("AWS_ACCESS_KEY_ID" nil)
             (with-environment ("AWS_SECRET_ACCESS_KEY" nil)
               (ok (null (enchiridion.llm::aws-credentials))))))
         (testing "the environment answers when the store is empty"
           (with-environment ("AWS_ACCESS_KEY_ID" "AKIDEXAMPLEFROMENV")
             (with-environment ("AWS_SECRET_ACCESS_KEY" "secret-from-the-env")
               (with-environment ("AWS_SESSION_TOKEN" "token-from-the-env")
                 (let ((credentials (enchiridion.llm::aws-credentials)))
                   (ok (not (null credentials)))
                   (ok (string= "AKIDEXAMPLEFROMENV"
                                (enchiridion.llm::aws-credential-access-key
                                 credentials)))
                   (ok (string= "token-from-the-env"
                                (enchiridion.llm::aws-credential-session-token
                                 credentials))))
                 (testing "and the store wins over it"
                   (enchiridion.llm.secrets:register-secret
                    "AWS_ACCESS_KEY_ID" "AKIDEXAMPLEFROMSTORE")
                   (ok (string= "AKIDEXAMPLEFROMSTORE"
                                (enchiridion.llm::aws-credential-access-key
                                 (enchiridion.llm::aws-credentials)))))))))
         (testing "half a credential is not a credential"
           (with-environment ("AWS_SECRET_ACCESS_KEY" nil)
             (ok (null (enchiridion.llm::aws-credentials))))))
    (enchiridion.llm.secrets:clear-secrets)))

(deftest the-credential-special-is-what-the-signer-reaches ()
  (let ((enchiridion.llm::*aws-credentials-function* (constantly (vector-credential))))
    (ok (enchiridion.llm::aws-credentials-available-p))
    (ok (string= (getf *get-vanilla* :authorization)
                 (header (sign-vector *get-vanilla*) :authorization))))
  (testing "and a resolver that answers nothing is a missing credential"
    (let ((enchiridion.llm::*aws-credentials-function* (constantly nil)))
      (ng (enchiridion.llm::aws-credentials-available-p)))))

;;;; The signed scheme.

(deftest the-signed-scheme-is-registered-and-reaches-sign-request ()
  (ok (not (null (enchiridion.llm:find-auth-signer :aws-sigv4))))
  (testing "auth-apply signs with the facts the endpoint bound around it"
    (let ((enchiridion.llm::*aws-region* "us-east-1")
          (enchiridion.llm::*aws-service* "bedrock")
          (enchiridion.llm::*aws-request-method* "GET")
          (enchiridion.llm::*signing-time* *vector-time*)
          (enchiridion.llm::*aws-credentials-function* (constantly (vector-credential))))
      (let* ((dialect (enchiridion.llm:make-dialect-for :bedrock-invoke
                                                        :protocol :anthropic))
             (request (enchiridion.llm:make-http-request
                       :url "https://bedrock-runtime.us-east-1.amazonaws.com/model/m/invoke"
                       :body ""
                       :headers '()
                       :timeout 10))
             (signed (enchiridion.llm:auth-apply dialect "" request))
             (headers (enchiridion.llm:http-request-headers signed)))
        (ok (search "AWS4-HMAC-SHA256" (header headers :authorization)))
        (testing "the method it was told is the method it signed"
          (ok (search "Credential=AKIDEXAMPLE/20150830/us-east-1/bedrock/aws4_request"
                      (header headers :authorization)))))))
  (testing "and with no region bound there is nothing to sign for"
    (let ((enchiridion.llm::*aws-region* nil)
          (enchiridion.llm::*aws-credentials-function* (constantly (vector-credential))))
      (ok (eq :region
              (signaled-key
               (enchiridion.llm:auth-apply
                (enchiridion.llm:make-dialect-for :bedrock-invoke :protocol :anthropic)
                ""
                (enchiridion.llm:make-http-request
                 :url "https://example.amazonaws.com/x"
                 :body ""
                 :headers '()
                 :timeout 10))))))))
