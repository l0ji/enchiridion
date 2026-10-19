;;;; http.cl --- One transport, one retry loop, and the headers that ride on it.
;;;;
;;;; There used to be two transports, http-post and anthropic-http-post, and
;;;; they differed in nothing but their headers. Keeping both forced every
;;;; caller through a six argument call whose last parameter meant "the
;;;; session id" on one wire and "the anthropic version" on the other, and it
;;;; made a third wire (Bedrock, Vertex) impossible without a third copy of the
;;;; retry policy.
;;;;
;;;; A request is now a value: URL, body, headers, timeout. A handler builds
;;;; one, signs or decorates it, and hands it to POST-WITH-RETRIES. The retry
;;;; policy is written once and cannot drift between providers, because there
;;;; is no second loop to drift from.
;;;;
;;;; Nothing here knows a provider. The header builders live with the handler
;;;; that sends them; this file owns only how a request is put on the wire and
;;;; what is worth sending again.

(in-package #:enchiridion.llm)

;;;; Small shared helpers.

(declaim (ftype (function (string) string) ensure-trailing-slash))

(defun ensure-trailing-slash (url)
  "Return URL ending in a slash, adding one when it lacks it.

Every path in this tree is appended to a base URL, so a missing slash silently
turns /v1 into a host named v1 and the request fails with a name error instead
of a useful message. One function for it means the rule cannot be right in one
handler and wrong in another."
  (if (and (plusp (length url))
           (char= (char url (1- (length url))) #\/))
      url
      (concatenate 'string url "/")))

(declaim (ftype (function () string) new-session-id))

(defun new-session-id ()
  "Return a 32 character hexadecimal session id. OpenCode Go asks for one on
every request so that it can route a conversation and keep its prompt cache
warm. A handler generates one when it is built and reuses it for every turn."
  (format nil "~32,'0X" (random (expt 2 128))))

(declaim (ftype (function (list list) list) merge-headers))

(declaim (ftype (function (list) list) header-pairs))

(defun header-pairs (headers)
  "Return HEADERS as an alist of conses.

dexador walks a header list with (LOOP FOR (NAME . VALUE) IN HEADERS), so a
two element list leaves VALUE bound to the list of its one element and the
header goes on the wire as `X-Tenant: (acme)`. That is a real defect and not a
style point: the operator writes ((\"X-Tenant\" \"acme\")) in config.cl, the
docs show that spelling, and it must reach the wire as a header.

Both spellings are accepted and both come out as conses, because a value that
is a keyword such as :content-type and a value that is a list are one fact to
every caller here. This is the one place that knows the difference."
  (loop for header in headers
        when header
          collect (if (consp (cdr header))
                      (cons (car header) (cadr header))
                      header)))

(declaim (ftype (function (list list) list) merge-headers))

(defun merge-headers (base extra)
  "Return BASE with every header in EXTRA added, EXTRA winning a name clash.

Names are compared case-insensitively because HTTP header names are, and
because one side of this call is a list of keywords written in Lisp and the
other is a list of strings that came out of config.cl. A provider that wants a
different Authorization header must be able to replace the one the handler
built, and that is exactly what this merge allows.

Both sides go through HEADER-PAIRS, so a caller may write a header either way
and cannot smuggle a parenthesised value onto the wire."
  (let ((result (header-pairs base)))
    (dolist (header (header-pairs extra) result)
      (let ((name (car header)))
        (setf result
              (remove-if (lambda (candidate)
                           (string-equal (string (car candidate)) (string name)))
                         result))
        (push header result)))))

;;;; The request.

;; Headers is an alist of conses and not a list of two element lists. dexador
;; walks the header list with (LOOP FOR (NAME . VALUE) IN HEADERS), so a two
;; element list leaves VALUE bound to a list of one string and the header goes
;; on the wire as a parenthesised list.
;;
;; The constructor is MAKE-HTTP-REQUEST and not a %MAKE- one because this
;; structure is built by every handler and by tests, and a private constructor
;; would only mean an exported wrapper per caller.
(defstruct (http-request (:constructor make-http-request))
  (:url "" :type string)
  (:body "" :type string)
  (:headers '() :type list)
  (:timeout 60 :type (integer 1 *)))

;;;; The transport.

;; dexador signals HTTP-REQUEST-FAILED on any 4xx or 5xx and returns the body
;; on a 2xx, so the status is read off the condition rather than off a return
;; value. RESPONSE-STATUS is that condition's reader; it is not a way to ask
;; "what did the last call return", and calling it with no arguments is a
;; style warning about arity.
;;
;; The argument names are dexador's, not guesses. It spells the payload :CONTENT
;; and not :DATA, spells the content type as a header and not as a :CONTENT-TYPE
;; argument, and spells both halves of a deadline :READ-TIMEOUT and
;; :CONNECT-TIMEOUT with no :TIMEOUT at all. Passing the names that read well
;; instead of the names it accepts is a style warning about unknown argument
;; keywords, and a warning here is an error.
;;
;; No :FORCE-BINARY. A provider reply is JSON text and dexador decodes it using
;; the charset the reply names, which is the only decoding that is correct for a
;; reply that is not ASCII. Forcing binary returns a vector of octets instead,
;; and the first thing that touches the reply is PARSE-JSON, which wants a
;; string: the error path fails while reporting the error, and the report is a
;; vector of numbers.
(declaim (ftype (function (http-request) string) http-post))

(defun http-post (request)
  "POST REQUEST and return the reply text."
  (dexador:request (http-request-url request)
                   :method :post
                   :headers (http-request-headers request)
                   :content (http-request-body request)
                   :read-timeout (http-request-timeout request)
                   :connect-timeout (http-request-timeout request)))

;; The transport is a special so a test can replace it without a network. That
;; is also the only way to test the retry path, because the retry path is about
;; what happens between two calls and not about what a provider says.
(defparameter *http-post-function* #'http-post
  "The function POST-WITH-RETRIES uses to make one HTTP request. Bound in tests.")

(defparameter *retry-delay* 2
  "The base delay in seconds for a retry. Attempt N waits N times this. Bound
to 0 in tests so a retry test does not spend six seconds asleep.")

(declaim (ftype (function (string) (or null string)) provider-error-message))

(defun provider-error-message (payload)
  "Return the provider's own error text from PAYLOAD, or a short note when
there is none. A reply that is not JSON at all is not a crash: a proxy in
front of the provider answers HTML."
  (handler-case
      (let* ((parsed (parse-json payload))
             (error-object (getf parsed :error)))
        (cond
          ((and (listp error-object) (stringp (getf error-object :message)))
           (getf error-object :message))
          ((stringp error-object) error-object)
          ;; AWS and GCP spell the same fact with a capitalized key and no
          ;; wrapper object; reading it here keeps every handler's errors
          ;; legible without a per-vendor error parser.
          ((stringp (getf parsed :message)) (getf parsed :message))
          ((stringp (getf parsed :Message)) (getf parsed :Message))
          (t (string-right-trim '(#\Space #\Newline #\Return) (or payload "")))))
    (error () "the provider replied with something that is not JSON")))

(declaim (ftype (function (function http-request (integer 0 *)) string)
                post-with-retries))

(defun post-with-retries (transport request retries)
  "POST REQUEST with TRANSPORT, repeating a retryable status.

429 and 5xx are repeated with a growing gap, because they are the two the same
request is worth sending again. 529 is Anthropic's overloaded status and 504
is its gateway timeout; both are above 500 and are covered by the same test.
Everything else in the 4xx range is reported at once: a wrong key or a wrong
model does not become right by being repeated.

There is no loop inside the handler. The handler returns after it sleeps, the
body of the outer loop ends, and the outer loop runs again. An inner (loop)
would be a new infinite loop and a 429 would hang the process instead of
retrying the request."
  (let ((attempt 0))
    (loop
      (handler-case
          (return (funcall transport request))
        (dexador.error:http-request-failed (failure)
          (let ((status (dexador.error:response-status failure)))
            (if (and (integerp status)
                     (or (= status 429) (>= status 500))
                     (< attempt retries))
                (progn (incf attempt)
                       (sleep (* *retry-delay* attempt)))
                (error 'enchiridion.errors:transport-error
                       :status status
                       :detail (format nil "~D after ~D attempt~:P: ~A"
                                       status
                                       (1+ attempt)
                                       (provider-error-message
                                        (dexador.error:response-body failure)))))))))))

;;;; The one GET.

;; The catalog and the model-list calls need a GET and nothing else. The
;; injection point mirrors *HTTP-POST-FUNCTION* and the web tool's
;; *WEB-GET-FUNCTION*, so a test can answer from a fixture.
(defparameter +http-get-timeout+ 10
  "Seconds before one catalog or model-list request is abandoned.")

(defun http-get (url &key headers (timeout +http-get-timeout+))
  "GET URL and return the reply text."
  (dexador:get url
               :headers headers
               :read-timeout timeout
               :connect-timeout timeout))

(defparameter *http-get-function* #'http-get
  "The function the catalog and the model listers use to make one HTTP GET.
Bound in tests so no catalog test opens a socket.")
