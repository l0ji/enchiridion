;;;; http.cl --- The webhook: three routes, one token, and a body limit.
;;;;
;;;; The webhook is a channel like any other, with one difference: a turn is
;;;; request and response, so the reply is the response body instead of a
;;;; message sent somewhere else. The channel therefore implements no
;;;; CHANNEL-SEND. The protocol default refuses it by name, which is the right
;;;; answer for a surface that has nothing to send to.
;;;;
;;;; It binds to loopback by default. A bind that listens to anything else
;;;; needs a token, and the refusal happens before a socket is opened rather
;;;; than at the first request: a server that comes up unauthenticated and
;;;; then argues about it was already reachable, and the window is the part
;;;; that matters.
;;;;
;;;; hunchentoot and not clack. The core clack system ships no handler, so
;;;; clackup needs clack-handler-hunchentoot, which is this same server plus a
;;;; layer nothing here uses; and clack:stop destroys its wrapper thread
;;;; without stopping the acceptor. hunchentoot starts and stops explicitly,
;;;; gives a thread per connection under a bounded taskmaster, and reads a
;;;; chunked body without help.
;;;;
;;;; Nothing in this file knows what a supervisor, a store or an agent is.
;;;; The three things a route needs arrive as functions: TURN runs one turn,
;;;; HEALTH reports the process, and USAGE reads the ledger. That is what
;;;; keeps the channel above the kernel instead of beside it.

(in-package #:enchiridion.channel.http)

;;;; Limits.

(defparameter +http-body-limit+ 65536
  "How many bytes of request body the webhook will read by default.

The limit is checked against the declared length before one byte is read,
because hunchentoot's own reader allocates what the header claims and the
header is written by the caller. A body that arrives chunked has no declared
length and is counted as it is read instead.")

(defparameter +http-usage-limit+ 50
  "How many ledger rows GET /usage returns by default. The CLI prints the same
fifty rows, so the two surfaces answer the same question the same way.")

(defparameter +http-max-usage-limit+ 1000
  "The largest ?limit= GET /usage will honour. A caller may ask for fewer rows
than the default, not for the whole table in one response.")

(defparameter +http-drain-seconds+ 30
  "How long CHANNEL-STOP waits for a turn already in flight.

hunchentoot:stop closes the listener and returns without killing a handler
thread, so a turn that started before the stop still finishes and still writes
its ledger row. The supervisor closes the store immediately after this returns,
which is why the wait counts turns and not only connections: a turn lost here is
a token row that never reaches the ledger. A turn that outlasts even this is
reported, and the operator can read why the shutdown was slow.")

(defparameter +http-read-timeout+ 5
  "How long a connection may take to send its request line, headers and body.

A client that declares a body and then sends nothing holds a handler thread for
this long. Eight of those exhaust the taskmaster before authentication had a
chance to refuse them, so the timeout is short: a real caller on a real network
sends a webhook request in milliseconds, and one that needs longer than five
seconds is one that is not sending. hunchentoot requires the read and write
timeouts to be equal, so the same number is used for both.")

;;;; The one condition this file signals.

(define-condition http-error (enchiridion.errors:enchiridion-error)
  ((status :initarg :status :initform 500 :reader http-error-status
           :documentation "The status code the client should see.")
   (message :initarg :message :initform "" :reader http-error-message
            :documentation "One line, safe to return to the caller.")
   (allow :initarg :allow :initform nil :reader http-error-allow
          :documentation "The Allow header, when the failure is a method.")
   (retry-after :initarg :retry-after :initform nil :reader http-error-retry-after
                :documentation "Seconds the caller should wait, or NIL."))
  (:report (lambda (condition stream)
             (format stream "HTTP ~D: ~A"
                     (http-error-status condition)
                     (http-error-message condition))))
  (:documentation
   "A request the webhook refuses, with the status it refuses it with.

The status and the message travel together because the alternative is a
handler that returns a string and a code from two places, and the two drift
the first time a route is added."))

(defmacro http-fail (status message &key allow retry-after)
  "Signal an HTTP-ERROR carrying STATUS and MESSAGE.

A macro and not a function, so the compiler sees the ERROR: a function that
signals looks to the type checker like a function that returns NIL, and every
declared return type around it becomes a lie the gate rejects."
  `(error 'http-error :status ,status :message ,message
                      :allow ,allow :retry-after ,retry-after))

;;;; JSON.

(declaim (ftype (function (&rest t) hash-table) json-object))

(defun json-object (&rest pairs)
  "Return PAIRS as the JSON object shape JZON writes.
A hash table and not a plist: JZON writes a plist as a JSON array, and every
body this file returns is an object."
  (let ((table (make-hash-table :test #'equal)))
    (loop for (key value) on pairs by #'cddr
          do (setf (gethash (string-downcase (string key)) table) value))
    table))

(declaim (ftype (function (t) string) json-text))

(defun json-text (value)
  "Return VALUE encoded as JSON text."
  (com.inuoe.jzon:stringify value))

(declaim (ftype (function (string) string) error-body))

(defun error-body (message)
  "Return the one line JSON error object the webhook answers with."
  (json-text (json-object "ok" nil "error" message)))

;;;; The service.

;; turn answers one message and returns (:ok-p :reply :error :reason :usage).
;; health reports the process, usage reads the ledger, token is the shared
;; secret or NIL, and the rest is where to listen and how much to read.
;; in-flight counts the turns a stop has to wait for, which hunchentoot's own
;; requests-in-progress does not: a turn that has finished reading its body and
;; is waiting on a model is a request hunchentoot considers answered.
(defstruct (http-service (:constructor %make-http-service))
  (turn nil :type t)
  (health nil :type t)
  (usage nil :type t)
  (token nil :type t)
  (bind "127.0.0.1" :type string)
  (port 8787 :type (integer 0 65535))
  (body-limit +http-body-limit+ :type (integer 1 *))
  (in-flight 0 :type integer)
  (in-flight-lock nil :type t))

(declaim (ftype (function (&key (:turn t) (:health t) (:usage t) (:token t)
                                (:bind string) (:port integer) (:body-limit integer))
                          http-service)
                make-http-service))

(defun make-http-service (&key turn health usage token (bind "127.0.0.1") (port 8787)
                               (body-limit +http-body-limit+))
  "Return an HTTP service. Nothing binds a port until a channel starts it.

The bind and the token are trimmed here, in one place, because both are read
from a configuration file a person edited: a token with a trailing space is a
token no header will ever match, and an empty bind would be handed to
hunchentoot as a hostname. An empty token becomes no token, which the policy
refuses on a reachable bind and allows on loopback."
  (check-type bind string)
  (check-type port (integer 0 65535))
  (check-type body-limit (integer 1 *))
  (let ((bind (string-trim '(#\Space #\Tab) bind))
        (token (and (stringp token)
                    (string-trim '(#\Space #\Tab #\Newline #\Return) token))))
    (%make-http-service :turn turn :health health :usage usage
                        :token (if (and token (plusp (length token))) token nil)
                        :bind (if (plusp (length bind)) bind "127.0.0.1")
                        :port port
                        :body-limit body-limit
                        :in-flight-lock (bordeaux-threads:make-lock
                                         "enchiridion http in flight"))))

(declaim (ftype (function (http-service) null) enter-turn))

(defun enter-turn (service)
  "Count one turn as running. Return NIL."
  (bordeaux-threads:with-lock-held ((http-service-in-flight-lock service))
    (incf (http-service-in-flight service)))
  nil)

(declaim (ftype (function (http-service) null) leave-turn))

(defun leave-turn (service)
  "Count one turn as finished. Return NIL."
  (bordeaux-threads:with-lock-held ((http-service-in-flight-lock service))
    (decf (http-service-in-flight service)))
  nil)

;;;; Authentication.

(declaim (ftype (function (string string) boolean) constant-time-string=))

(defun constant-time-string= (left right)
  "Compare LEFT and RIGHT without an early exit.

A comparison that stops at the first difference tells the caller how many
characters of a token were right, one request at a time. This folds every
character in and adds the length difference, so the only thing it leaks is the
length, which the caller chose. Strings, not bytes: the header is text by the
time it arrives."
  (declare (type string left right))
  (let ((difference (logxor (length left) (length right)))
        (limit (min (length left) (length right))))
    (dotimes (index limit)
      (setf difference (logior difference
                               (logxor (char-code (char left index))
                                       (char-code (char right index))))))
    (zerop difference)))

(declaim (ftype (function (t) (or null string)) bearer-token))

(defun bearer-token (authorization)
  "Return the token of an Authorization header, or NIL.
One spelling, Bearer, so there is one code path to read and one to test."
  (when (and (stringp authorization)
             (> (length authorization) 7)
             (string-equal "bearer " authorization :end2 7))
    (let ((token (string-trim '(#\Space #\Tab) (subseq authorization 7))))
      (if (plusp (length token)) token nil))))

(declaim (ftype (function (http-service t) boolean) authorized-p))

(defun authorized-p (service authorization)
  "Return T when AUTHORIZATION carries the service's token.

A service with no token answers T: that is the loopback case, and the policy
check is what keeps a reachable bind from being the no-token case. A missing
header is compared as an empty string rather than short-circuited, so a request
with no token and a request with the wrong one take the same path."
  (let ((expected (http-service-token service)))
    (if (or (null expected) (zerop (length expected)))
        t
        (constant-time-string= (or (bearer-token authorization) "") expected))))

;;;; Binding.

(declaim (ftype (function (t) boolean) loopback-bind-p))

(defun loopback-bind-p (bind)
  "Return T when BIND names only the loopback interface, or names nothing.

The empty string is loopback because MAKE-HTTP-SERVICE replaces it with
127.0.0.1 before an acceptor is made. NIL is NOT loopback: hunchentoot reads a
NIL address as the wildcard and binds every interface, so classifying NIL as
the safe default would make one spelling silently open the port to the network
while the policy said it was local.

0.0.0.0, ::, a hostname other than localhost, and every other address are not
loopback either: a name that resolves to the loopback today can resolve
elsewhere tomorrow, and a name server inside a startup security check is a
network call inside a security check.

The digit test is bounded to ASCII on purpose. DIGIT-CHAR-P accepts every
Unicode decimal digit, so a spelling such as 127.0.0.<arabic-indic one> would
be called loopback by a looser check; it does not resolve today, but the check
must not be the reason that stays true."
  (if (not (stringp bind))
      nil
      (let ((text (string-trim '(#\Space #\Tab) bind)))
        (cond
          ((zerop (length text)) t)
          ((string-equal "localhost" text) t)
          ((string= "::1" text) t)
          ((string= "::ffff:127.0.0.1" text) t)
          ((and (>= (length text) 5)
                (string= "127." text :end2 4)
                (= 3 (count #\. text))
                (every (lambda (character)
                         (or (char= character #\.)
                             (char<= #\0 character #\9)))
                       text))
           t)
          (t nil)))))

(declaim (ftype (function (http-service) null) check-http-policy))

(defun check-http-policy (service)
  "Refuse a reachable bind that has no token, before a socket is opened."
  (let ((bind (http-service-bind service))
        (token (http-service-token service)))
    (when (and (not (loopback-bind-p bind))
               (or (null token) (zerop (length token))))
      (error 'enchiridion.errors:configuration-error
             :key :http-token
             :detail (format nil
                             "A webhook bound to ~A answers the network, so it needs a token. Set the variable the :http channel names, or bind 127.0.0.1."
                             bind)))))

;;;; The request.

;; The request is a value, not a hunchentoot object, so a route can be tested
;; without a socket. REQUEST-FROM-HUNCHENTOOT is the only function here that
;; knows the server.
(defstruct (http-request (:constructor %make-http-request))
  (method "GET" :type string)
  (path "/" :type string)
  (query "" :type string)
  (authorization nil :type t)
  (content-type nil :type t)
  (content-length nil :type t)
  (body "" :type string))

(declaim (ftype (function (&key (:method string) (:path string) (:query string)
                                (:authorization t) (:content-type t)
                                (:content-length t) (:body string))
                          http-request)
                make-http-request))

(defun make-http-request (&key (method "GET") (path "/") (query "") authorization
                               content-type content-length (body ""))
  "Return a request value. Tests build this; the server side builds it in
REQUEST-FROM-HUNCHENTOOT."
  (check-type method string)
  (check-type path string)
  (check-type body string)
  (%make-http-request :method (string-upcase method) :path path :query query
                      :authorization authorization :content-type content-type
                      :content-length content-length :body body))

(declaim (ftype (function (t) (or null integer)) declared-length))

(defun declared-length (header)
  "Return HEADER as a byte count, or NIL when it is absent or not a number."
  (when (and (stringp header) (plusp (length header)))
    (parse-integer header :junk-allowed t)))

(declaim (ftype (function (t) boolean) json-content-type-p))

(defun json-content-type-p (value)
  "Return T when VALUE is a JSON content type.
A missing header is not JSON: a caller that sends a body has to say what it
is, and guessing is how a form post becomes a parse error three functions
later."
  (and (stringp value)
       (not (null (search "application/json" (string-downcase value))))))

(declaim (ftype (function (http-service t (or null integer)) string)
                read-request-body))

(defun read-request-body (service raw length)
  "Read the body of RAW, refusing more than the service's limit.

The declared length is checked first, because hunchentoot allocates what the
header claims. The bytes are then counted as they arrive, which is what bounds
a chunked body that declares nothing. READ-BYTE and not READ-SEQUENCE: the
byte loop consumes a chunked body's terminating chunk and read-sequence leaves
it, which hunchentoot then reports as a 500."
  (when (and length (> length (http-service-body-limit service)))
    (http-fail 413 (format nil "The body is larger than ~D bytes."
                           (http-service-body-limit service))))
  (let ((stream (hunchentoot:raw-post-data :request raw :want-stream t)))
    (if (null stream)
        ""
        (let ((octets (make-array 256 :element-type '(unsigned-byte 8)
                                      :adjustable t :fill-pointer 0))
              (limit (http-service-body-limit service)))
          (loop for octet = (read-byte stream nil :eof)
                until (eq octet :eof)
                do (when (>= (fill-pointer octets) limit)
                     (http-fail 413 (format nil "The body is larger than ~D bytes."
                                            limit)))
                   (vector-push-extend octet octets))
          (handler-case (enchiridion.compat:decode-utf8 octets)
            (error () (http-fail 400 "The body is not UTF-8 text.")))))))

(declaim (ftype (function (http-service t) http-request) request-from-hunchentoot))

(defun request-from-hunchentoot (service raw)
  "Return RAW, a hunchentoot request, as an HTTP-REQUEST with its body read."
  (let* ((method (string-upcase (string (hunchentoot:request-method* raw))))
         (length (declared-length (hunchentoot:header-in* :content-length raw))))
    (%make-http-request
     :method method
     :path (or (hunchentoot:script-name* raw) "/")
     :query (or (hunchentoot:query-string* raw) "")
     :authorization (hunchentoot:header-in* :authorization raw)
     :content-type (hunchentoot:header-in* :content-type raw)
     :content-length length
     :body (if (string= method "POST")
               (read-request-body service raw length)
               ""))))

;;;; The routes.

(declaim (ftype (function (t) t) channel-object))

(defun channel-object (row)
  "Return ROW, a channel row, as something JSON writes.
The status file already produces these as hash tables; a plist is accepted so
a test or a future caller does not have to build the other shape."
  (if (hash-table-p row)
      row
      (json-object "name" (or (getf row :name) "")
                   "state" (or (getf row :state) "")
                   "enabled" (not (null (getf row :enabled))))))

(declaim (ftype (function (t) hash-table) usage-object))

(defun usage-object (row)
  "Return ROW, one ledger row, as the JSON object the report carries."
  (json-object "id" (getf row :id)
               "session" (getf row :session)
               "model" (getf row :model)
               "input" (getf row :input)
               "output" (getf row :output)
               "cache-read" (getf row :cache-read)
               "cache-write" (getf row :cache-write)
               "channel" (getf row :channel)
               "ts" (getf row :ts)))

(declaim (ftype (function (string string) (or null string)) query-value))

(defun query-value (query name)
  "Return NAME from QUERY, a query string such as limit=5, or NIL."
  (when (and (stringp query) (plusp (length query)))
    (loop for pair in (uiop:split-string query :separator "&")
          for split = (position #\= pair)
          when (and split (string-equal name (subseq pair 0 split)))
            do (return (subseq pair (1+ split))))))

(declaim (ftype (function (http-request) (integer 1 *)) usage-limit))

(defun usage-limit (request)
  "Return the ?limit= of REQUEST, or the default, clamped to the maximum.
A limit that is not a positive number is the default rather than an error: the
parameter is a convenience, and refusing the whole report over it would make
the report harder to get than the rows are worth."
  (let ((value (and (query-value (http-request-query request) "limit")
                    (parse-integer (query-value (http-request-query request) "limit")
                                   :junk-allowed t))))
    (cond
      ((null value) +http-usage-limit+)
      ((< value 1) +http-usage-limit+)
      ((> value +http-max-usage-limit+) +http-max-usage-limit+)
      (t value))))

(declaim (ftype (function (http-service) (values integer string)) health-response))

(defun health-response (service)
  "Return the status and body for GET /health.

The report comes from the live process, not from the status file: a file read
by a process that has stopped reports the last thing it said, and an uptime
derived from a dead process grows forever."
  (let ((report (and (http-service-health service)
                     (funcall (http-service-health service)))))
    (if report
        (values 200 (json-text
                     (json-object "ok" (not (null (getf report :ok-p)))
                                  "uptime" (or (getf report :uptime) 0)
                                  "channels" (coerce (mapcar #'channel-object
                                                             (getf report :channels))
                                                     'vector))))
        (values 503 (json-text (json-object "ok" nil
                                            "error" "the supervisor is not running"))))))

(declaim (ftype (function (http-service http-request) (values integer string))
                usage-response))

(defun usage-response (service request)
  "Return the status and body for GET /usage.
A service with no store answers 503 and says so rather than reporting an empty
ledger, which would read as a day with no spend."
  (let ((report (and (http-service-usage service)
                     (funcall (http-service-usage service) (usage-limit request)))))
    (cond
      ((null report)
       (values 503 (json-text (json-object "error" "no memory store is open"))))
      ((not (getf report :ok-p))
       (values 503 (json-text (json-object "error" (or (getf report :error)
                                                       "the ledger is unreadable")))))
      (t
       (let ((rows (getf report :rows)))
         (values 200 (json-text (json-object "count" (length rows)
                                             "rows" (coerce (mapcar #'usage-object rows)
                                                            'vector)))))))))

(declaim (ftype (function (t) hash-table) usage-summary-object))

(defun usage-summary-object (usage)
  "Return USAGE, the plist a turn reports, as the JSON object a reply carries.
The turn's own rows are summed, not the completion's: a turn that called a
tool makes several model calls, and the completion is only the last one."
  (json-object "model" (or (getf usage :model) "")
               "input" (or (getf usage :input) 0)
               "output" (or (getf usage :output) 0)
               "cache-read" (or (getf usage :cache-read) 0)
               "cache-write" (or (getf usage :cache-write) 0)
               "rounds" (or (getf usage :rounds) 0)
               "total" (or (getf usage :total) 0)))

(declaim (ftype (function (string) hash-table) parse-json-object))

(defun parse-json-object (text)
  "Return TEXT parsed as a JSON object, or refuse it with a 400."
  (handler-case
      (let ((value (com.inuoe.jzon:parse text)))
        (if (hash-table-p value)
            value
            (http-fail 400 "The body must be a JSON object.")))
    (http-error (condition) (error condition))
    (error () (http-fail 400 "The body is not JSON."))))

(declaim (ftype (function (http-service http-request) (values integer string))
                message-response))

(defun message-response (service request)
  "Return the status and body for POST /message: one synchronous turn."
  (unless (json-content-type-p (http-request-content-type request))
    (http-fail 415 "POST /message needs a JSON body."))
  (let* ((body (parse-json-object (http-request-body request)))
         (text (gethash "text" body))
         (author (gethash "author" body)))
    (unless (and (stringp text)
                 (plusp (length (string-trim '(#\Space #\Tab #\Newline #\Return)
                                             text))))
      (http-fail 400 "The body needs a non-empty text field."))
    (let* ((turn (http-service-turn service))
           (message (enchiridion.channel:normalize
                     :channel :http
                     :author (if (stringp author) author "webhook")
                     :text text))
           (result (if turn
                       (progn
                         (enter-turn service)
                         (unwind-protect (funcall turn message)
                           (leave-turn service)))
                       (list :ok-p nil
                             :error "no agent is attached to this webhook."))))
      (cond
        ((getf result :ok-p)
         (values 200 (json-text
                      (json-object "reply" (or (getf result :reply) "")
                                   "usage" (usage-summary-object (getf result :usage))))))
        ((eq (getf result :reason) :busy)
         (http-fail 503 (or (getf result :error) "the agent is answering another turn.")
                    :retry-after "1"))
        (t
         (http-fail 502 (or (getf result :error) "the turn failed.")))))))

(declaim (ftype (function (http-service http-request) (values integer string))
                handle-http-request))

(defun handle-http-request (service request)
  "Return the status and the JSON body for an authenticated REQUEST.

Three routes and no more. A known path with the wrong method is 405 with the
method it takes; anything else is 404. The answer is a value rather than a
write so the whole routing table is testable without a socket."
  (let ((method (http-request-method request))
        (path (http-request-path request)))
    (cond
      ((and (string= method "POST") (string= path "/message"))
       (message-response service request))
      ((and (string= method "GET") (string= path "/health"))
       (health-response service))
      ((and (string= method "GET") (string= path "/usage"))
       (usage-response service request))
      ((member path '("/message" "/health" "/usage") :test #'string=)
       (http-fail 405 (format nil "~A takes ~A." path (if (string= path "/message")
                                                          "POST"
                                                          "GET"))
                  :allow (if (string= path "/message") "POST" "GET")))
      (t
       (http-fail 404 (format nil "There is no route ~A." path))))))

(declaim (ftype (function (http-service http-request) (values integer string))
                dispatch-http-request))

(defun dispatch-http-request (service request)
  "Authenticate REQUEST, then route it, and return the status and body.
A refusal and a wrong token are both 401: a 403 that means the token was right
and the caller was wrong is an oracle for guessing tokens."
  (if (authorized-p service (http-request-authorization request))
      (handle-http-request service request)
      (http-fail 401 "A bearer token is required.")))

;;;; The acceptor.

(defclass http-acceptor (hunchentoot:acceptor)
  ((service :accessor http-acceptor-service :initarg :service :initform nil :type t
            :documentation "The service this acceptor answers for."))
  (:documentation
   "A hunchentoot acceptor that routes to HANDLE-HTTP-REQUEST and always
answers JSON. It exists so the dispatch method has somewhere to live: a plain
acceptor would fall through to hunchentoot's own handler and answer an HTML
page."))

(declaim (ftype (function (integer string &key (:allow t) (:retry-after t)) t)
                abort-with))

(defun abort-with (status body &key allow retry-after)
  "Write STATUS, BODY and the optional headers, and end the handler.
Returning a string from a dispatch method sends nothing: ABORT-REQUEST-HANDLER
is the throw that delivers the body."
  (setf (hunchentoot:return-code*) status
        (hunchentoot:content-type*) "application/json; charset=utf-8")
  (when allow
    (setf (hunchentoot:header-out :allow) allow))
  (when retry-after
    (setf (hunchentoot:header-out :retry-after) retry-after))
  (hunchentoot:abort-request-handler body))

(defmethod hunchentoot:acceptor-dispatch-request ((acceptor http-acceptor) request)
  "Answer one request as JSON and never let a condition escape.

The token is checked from the header before the body is read. That order is the
difference between an anonymous caller being refused and an anonymous caller
holding a handler thread for the read timeout: a client that announces a body
and then sends nothing costs nothing until the body is wanted, and the
taskmaster is small.

An uncaught condition is rendered by hunchentoot as its own HTML error page,
with the server version and a backtrace on stderr: an API that answers HTML
when it fails is an API whose caller cannot tell a bug from a shutdown."
  (let ((service (http-acceptor-service acceptor)))
    (handler-case
        (progn
          (unless (authorized-p service (hunchentoot:header-in* :authorization request))
            (setf (hunchentoot:header-out :www-authenticate) "Bearer")
            (http-fail 401 "A bearer token is required."))
          (let ((parsed (request-from-hunchentoot service request)))
            (multiple-value-bind (status body) (handle-http-request service parsed)
              (abort-with status body))))
      (http-error (condition)
        (abort-with (http-error-status condition)
                    (error-body (http-error-message condition))
                    :allow (http-error-allow condition)
                    :retry-after (http-error-retry-after condition)))
      (error (condition)
        (format *error-output* "~&enchiridion: webhook error: ~A~%" condition)
        (finish-output *error-output*)
        (abort-with 500 (error-body "the webhook failed to answer."))))))

;;;; The channel.

(defclass http-channel (enchiridion.channel:channel)
  ((service :accessor http-channel-service :initarg :service :initform nil :type t
            :documentation "The service, with the token, the routes and the limit.")
   (acceptor :accessor http-channel-acceptor :initarg :acceptor :initform nil :type t
             :documentation "The running acceptor, or NIL while the channel is down.")
   (stopped-p :accessor http-channel-stopped-p :initarg :stopped-p :initform nil
              :type boolean
              :documentation "Set by CHANNEL-STOP to release the start loop."))
  (:documentation
   "The webhook as a channel. CHANNEL-START blocks until CHANNEL-STOP, the way
every channel does, because the supervisor calls CHANNEL-START in a restart
loop and a start that returned at once would bind the port again every second."))

(declaim (ftype (function (&key (:name string) (:service t)) http-channel)
                make-http-channel))

(defun make-http-channel (&key (name "http") service)
  "Return a stopped HTTP channel that answers through SERVICE."
  (make-instance 'http-channel :name name :service service))

(declaim (ftype (function (http-channel) null) stop-http-acceptor))

(defun stop-http-acceptor (channel)
  "Stop CHANNEL's acceptor and wait, briefly, for the work in flight.

Two things are waited for. hunchentoot's own count of requests in progress
covers a connection still inside the handler; the service's turn count covers
the longer and more expensive case, a turn that has read its body and is
waiting on a model. The supervisor closes the store as soon as this returns, so
a turn still running would write its ledger row into a closed store.

The slot is cleared first so that a stop from CHANNEL-STOP and a stop from the
start loop cannot both drive the same acceptor."
  (let ((acceptor (shiftf (http-channel-acceptor channel) nil))
        (service (http-channel-service channel)))
    (when acceptor
      (ignore-errors (hunchentoot:stop acceptor))
      (let ((deadline (+ (get-internal-real-time)
                         (* +http-drain-seconds+ internal-time-units-per-second))))
        (loop while (and (or (plusp (or (hunchentoot:acceptor-requests-in-progress
                                         acceptor)
                                        0))
                             (and service (plusp (http-service-in-flight service))))
                         (< (get-internal-real-time) deadline))
              do (sleep 0.05))
        (when (and service (plusp (http-service-in-flight service)))
          (format *error-output*
                  "~&enchiridion: a webhook turn outlasted the ~D second drain; it may not reach the ledger.~%"
                  +http-drain-seconds+)
          (finish-output *error-output*)))))
  nil)

(defmethod enchiridion.channel:channel-start ((channel http-channel) &key config)
  "Validate the bind policy, start the acceptor, and block until stopped.

HUCHENTOOT:*LOG-LISP-ERRORS-P* is bound to NIL around the start because every
handler thread inherits this thread's bindings: without it each failure prints
a backtrace on top of the one line this file writes, and the log becomes
unreadable exactly when it is needed."
  (declare (ignore config))
  (let ((service (http-channel-service channel)))
    (unless service
      (error 'enchiridion.errors:configuration-error
             :key :http
             :detail "The channel has no service to answer with."))
    (check-http-policy service)
    (let ((hunchentoot:*log-lisp-errors-p* nil))
      (setf (http-channel-stopped-p channel) nil)
      (setf (http-channel-acceptor channel)
            (hunchentoot:start
             (make-instance 'http-acceptor
                            :name 'enchiridion-http
                            :address (http-service-bind service)
                            :port (http-service-port service)
                            :service service
                            :taskmaster (make-instance
                                         'hunchentoot:one-thread-per-connection-taskmaster
                                         :max-thread-count 8
                                         :max-accept-count 16)
                            :read-timeout +http-read-timeout+
                            :write-timeout +http-read-timeout+
                            :access-log-destination nil
                            :message-log-destination nil
                            :persistent-connections-p t)))
      (setf (enchiridion.channel:channel-live-p channel) t
            (enchiridion.channel:channel-state channel) :live)
      (unwind-protect
           (loop while (and (enchiridion.channel:channel-live-p channel)
                            (not (http-channel-stopped-p channel)))
                 do (sleep 0.2))
        (stop-http-acceptor channel)))
    channel))

(defmethod enchiridion.channel:channel-stop ((channel http-channel))
  "Mark CHANNEL stopped, stop the acceptor, and wait for the turns in flight."
  (setf (http-channel-stopped-p channel) t)
  (setf (enchiridion.channel:channel-live-p channel) nil
        (enchiridion.channel:channel-state channel) :stopped)
  (stop-http-acceptor channel)
  channel)

(defmethod enchiridion.channel:channel-status ((channel http-channel))
  "Return CHANNEL's state."
  (enchiridion.channel:channel-state channel))

;;;; Entry points.

(declaim (ftype (function (&key (:turn t) (:health t) (:usage t) (:token t)
                                (:bind string) (:port integer) (:body-limit integer)
                                (:name string))
                          http-channel)
                start-http))

(defun start-http (&key turn health usage token (bind "127.0.0.1") (port 8787)
                        (body-limit +http-body-limit+) (name "http"))
  "Build a channel over these options, start it, and return it.
This blocks until STOP-HTTP, exactly as CHANNEL-START does."
  (let ((channel (make-http-channel
                  :name name
                  :service (make-http-service :turn turn :health health :usage usage
                                              :token token :bind bind :port port
                                              :body-limit body-limit))))
    (enchiridion.channel:channel-start channel)
    channel))

(declaim (ftype (function (http-channel) http-channel) stop-http))

(defun stop-http (channel)
  "Stop CHANNEL and return it."
  (enchiridion.channel:channel-stop channel))

(declaim (ftype (function (http-channel) boolean) http-running-p))

(defun http-running-p (channel)
  "Return T while CHANNEL is accepting requests."
  (not (null (enchiridion.channel:channel-live-p channel))))
