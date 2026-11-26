;;;; http-test.lsp --- The webhook: its routes, its token, and its limits.
;;;;
;;;; Almost everything here is a pure function over a request value, which is
;;;; the point of building the request as a struct instead of reading
;;;; hunchentoot's object directly: the routing table, the token comparison,
;;;; the loopback rule and the JSON shapes are all testable without a socket.
;;;; One test binds a real port, because the acceptor, the dispatch method and
;;;; the response write are the parts a pure test cannot reach.

(defpackage #:enchiridion-http-test
  (:use #:cl)
  (:import-from #:rove #:deftest #:ok #:ng #:testing)
  (:export #:run))

(in-package #:enchiridion-http-test)

(defun json-of (text)
  "Return TEXT parsed as JSON, for an assertion about a shape rather than a
string. Comparing serialised JSON would fail on key order, which carries no
meaning."
  (com.inuoe.jzon:parse text))

(defun http-error-of (function)
  "Call FUNCTION and return the HTTP-ERROR it signalled, or NIL.
The status, the message and the headers travel on the condition, so a test
reads them from one place rather than from three return values."
  (handler-case (progn (funcall function) nil)
    (enchiridion.channel.http:http-error (condition) condition)))

(defun service-with (&key turn health usage token (bind "127.0.0.1") (port 8787)
                          (body-limit enchiridion.channel.http:+http-body-limit+)
                          (followups-p nil))
  "Return a service whose routes are the given functions.
FOLLOWUPS-P makes TURN accept the second checkpoint argument."
  (enchiridion.channel.http:make-http-service
   :turn turn :health health :usage usage :token token :bind bind :port port
   :body-limit body-limit :followups-p followups-p))

(defun get-request (path &key query authorization)
  "Return a GET request value for PATH."
  (enchiridion.channel.http:make-http-request
   :method "GET" :path path :query (or query "") :authorization authorization))

(defun post-request (body &key (content-type "application/json")
                               authorization)
  "Return a POST /message request value carrying BODY."
  (enchiridion.channel.http:make-http-request
   :method "POST" :path "/message" :body body
   :content-type content-type :authorization authorization
   :content-length (length body)))

(defun followup-key (&optional (character #\a))
  "Return a well-formed capability. The caller mints it; the service checks it."
  (make-string enchiridion.channel.http::+http-turn-key-length+
               :initial-element character))

(defun json-body (&rest pairs)
  "Return PAIRS as a JSON object body."
  (let ((table (make-hash-table :test #'equal)))
    (loop for (key value) on pairs by #'cddr
          do (setf (gethash key table) value))
    (com.inuoe.jzon:stringify table)))

(defun message-call (service body &key authorization)
  "Post BODY to SERVICE, returning (STATUS BODY) or the HTTP-ERROR it signalled."
  (handler-case
      (multiple-value-list
       (enchiridion.channel.http:dispatch-http-request
        service (post-request body :authorization authorization)))
    (enchiridion.channel.http:http-error (condition) condition)))

(defun error-code (condition)
  "Return the follow-up code on CONDITION."
  (enchiridion.channel.http::http-error-code condition))

;;;; Tokens.

(deftest a-constant-time-comparison-still-compares ()
  (ok (enchiridion.channel.http:constant-time-string= "secret" "secret"))
  (ng (enchiridion.channel.http:constant-time-string= "secret" "secreu"))
  (ng (enchiridion.channel.http:constant-time-string= "secret" "secret "))
  (ng (enchiridion.channel.http:constant-time-string= "secret" ""))
  (testing "an empty pair is equal, which is why a missing token is checked
before this is reached"
    (ok (enchiridion.channel.http:constant-time-string= "" ""))))

(deftest a-bearer-token-is-read-one-way ()
  (ok (string= "abc" (enchiridion.channel.http:bearer-token "Bearer abc")))
  (ok (string= "abc" (enchiridion.channel.http:bearer-token "bearer abc")))
  (ok (string= "abc" (enchiridion.channel.http:bearer-token "Bearer  abc  ")))
  (ng (enchiridion.channel.http:bearer-token "Basic abc"))
  (ng (enchiridion.channel.http:bearer-token "abc"))
  (ng (enchiridion.channel.http:bearer-token nil))
  (ng (enchiridion.channel.http:bearer-token "Bearer ")))

(deftest authorization-depends-on-the-service-token ()
  (let ((open (service-with))
        (locked (service-with :token "s3cret")))
    (testing "a service with no token answers anything"
      (ok (enchiridion.channel.http:authorized-p open nil))
      (ok (enchiridion.channel.http:authorized-p open "Bearer wrong")))
    (testing "a service with a token answers only that token"
      (ok (enchiridion.channel.http:authorized-p locked "Bearer s3cret"))
      (ng (enchiridion.channel.http:authorized-p locked "Bearer wrong"))
      (ng (enchiridion.channel.http:authorized-p locked nil))
      (ng (enchiridion.channel.http:authorized-p locked "s3cret")))))

(deftest a-token-is-trimmed-and-a-blank-one-is-no-token ()
  ;; A token comes from a file a person edited, and a stray space in it used to
  ;; be a permanent 401 that looks exactly like a wrong token. It is trimmed
  ;; now; a token that is only whitespace is no token at all, which the bind
  ;; policy refuses on anything but loopback.
  (let ((service (service-with :token "  s3cret	")))
    (testing "the surrounding whitespace does not matter"
      (ok (enchiridion.channel.http:authorized-p service "Bearer s3cret"))
      (testing "and a different token is still refused"
        (ng (enchiridion.channel.http:authorized-p service "Bearer s3cret2"))
        (ng (enchiridion.channel.http:authorized-p service "Bearer s3cre")))))
  (testing "a blank token is no token"
    (ok (enchiridion.channel.http:authorized-p (service-with :token "   ") nil))
    (testing "and a reachable bind with a blank token is refused rather than locked"
      (ok (handler-case
              (progn (enchiridion.channel.http:check-http-policy
                      (service-with :token "   " :bind "0.0.0.0"))
                     nil)
            (enchiridion.errors:configuration-error () t)))))
  (testing "an empty bind is the loopback default, not the wildcard"
    (ok (string= "127.0.0.1"
                 (enchiridion.channel.http:http-service-bind
                  (service-with :bind ""))))))

;;;; Binding.

(deftest only-the-loopback-names-count-as-loopback ()
  (dolist (bind '("" "   " "127.0.0.1" "127.0.0.2" "127.1.2.3" "127.000.000.001"
                  "localhost" "LOCALHOST" "::1" "::ffff:127.0.0.1" " 127.0.0.1 "))
    (testing (format nil "~S is loopback" bind)
      (ok (enchiridion.channel.http:loopback-bind-p bind))))
  ;; NIL is the wildcard to hunchentoot, so it is not the safe default; the
  ;; last entry is a Unicode digit, which DIGIT-CHAR-P would accept.
  (dolist (bind '(nil "0.0.0.0" "::" "*" "example.test" "10.0.0.1" "128.0.0.1"
                  "127.0.0.1.example.test" "127.0.0" "1270.0.1"
                  "127.0.0.١"))
    (testing (format nil "~S is not loopback" bind)
      (ng (enchiridion.channel.http:loopback-bind-p bind)))))

(deftest a-reachable-bind-without-a-token-is-refused ()
  (testing "loopback without a token is the default and is allowed"
    (ok (null (enchiridion.channel.http:check-http-policy
               (service-with :bind "127.0.0.1")))))
  (testing "a reachable bind without a token is refused by name"
    (let ((condition (handler-case
                         (progn (enchiridion.channel.http:check-http-policy
                                 (service-with :bind "0.0.0.0"))
                                nil)
                       (enchiridion.errors:configuration-error (found) found))))
      (ok condition)
      (ok (eq :http-token (enchiridion.errors::configuration-key condition)))
      (ok (search "0.0.0.0" (enchiridion.errors:error-detail condition)))))
  (testing "and a reachable bind with a token is allowed"
    (ok (null (enchiridion.channel.http:check-http-policy
               (service-with :bind "0.0.0.0" :token "s3cret"))))))

;;;; Request reading.

(deftest a-declared-length-is-read-or-refused ()
  (ok (eql 12 (enchiridion.channel.http:declared-length "12")))
  (ok (null (enchiridion.channel.http:declared-length nil)))
  (ok (null (enchiridion.channel.http:declared-length "")))
  (ok (null (enchiridion.channel.http:declared-length "twelve"))))

(deftest a-length-that-frames-nothing-is-no-body ()
  ;; Hunchentoot bounds the stream it hands back by the header whatever this
  ;; returns, so the number decides whether a connection may be kept alive, not
  ;; what bounds the read.
  (testing "zero and a negative count frame no body"
    (ok (null (enchiridion.channel.http:declared-length "0")))
    (ok (null (enchiridion.channel.http:declared-length "-5"))))
  (testing "and a positive one still does"
    (ok (eql 12 (enchiridion.channel.http:declared-length " 12")))))

(deftest only-a-framed-body-is-read ()
  (testing "a declared length frames a body"
    (ok (enchiridion.channel.http::body-declared-p 12 nil)))
  (testing "a chunked encoding frames one without a length"
    (ok (enchiridion.channel.http::body-declared-p nil "chunked"))
    (ok (enchiridion.channel.http::body-declared-p nil "gzip, Chunked")))
  (testing "neither header frames nothing, so nothing is read"
    (ng (enchiridion.channel.http::body-declared-p nil nil))
    (ng (enchiridion.channel.http::body-declared-p 0 nil))
    (ng (enchiridion.channel.http::body-declared-p nil "gzip"))))

(deftest a-body-is-refused-before-it-is-read ()
  (let ((service (enchiridion.channel.http:make-http-service :body-limit 16)))
    (testing "a declared length over the limit is a 413, and no stream is asked for"
      (let ((condition (http-error-of
                        (lambda ()
                          (enchiridion.channel.http::read-request-body
                           service nil 70000 nil)))))
        (ok (eql 413 (enchiridion.channel.http:http-error-status condition)))))
    (testing "a body framed both ways is refused for the framing, not for its size"
      (let ((condition (http-error-of
                        (lambda ()
                          (enchiridion.channel.http::read-request-body
                           service nil 12 t)))))
        (ok (eql 400 (enchiridion.channel.http:http-error-status condition)))
        (ok (search "chunked"
                    (enchiridion.channel.http:http-error-message condition)))))))

;; A request object, built without a socket. The reply and acceptor are bound
;; because hunchentoot's request initialiser writes a return code when it cannot
;; parse the URI or verify a session.
(defun request-object-with (headers &key content-stream)
  "Return a hunchentoot request carrying HEADERS and CONTENT-STREAM."
  (let ((hunchentoot:*reply* (make-instance 'hunchentoot:reply))
        (hunchentoot:*acceptor* (make-instance 'hunchentoot:acceptor :port 0)))
    (make-instance 'enchiridion.channel.http::http-request-object
                   :headers-in headers
                   :method :post
                   :uri "/message"
                   :server-protocol :http/1.1
                   :content-stream content-stream)))

(deftest a-request-body-is-sealed-until-the-bounded-read-opens-it ()
  ;; HUNCHENTOOT:START-OUTPUT calls (RAW-POST-DATA :FORCE-BINARY T) before every
  ;; answer, and an empty slot makes that call allocate the declared
  ;; Content-Length. The constructor seals the slot; only the bounded read opens
  ;; it.
  (testing "a fresh request is sealed"
    (let ((request (request-object-with (list (cons :content-length "999999999")))))
      (ok (eq t (slot-value request 'hunchentoot::raw-post-data)))
      (testing "so the answer has nothing to read into memory"
        (ok (null (hunchentoot:raw-post-data :request request :force-binary t)))))
    (testing "and the bounded read opens it"
      (let ((request (request-object-with (list (cons :content-length "4")))))
        (enchiridion.channel.http::open-request-body request)
        (ok (null (slot-value request 'hunchentoot::raw-post-data))))))
  (testing "a refusal seals it again"
    (let ((request (request-object-with (list (cons :content-length "999999999")))))
      (enchiridion.channel.http::seal-request-body request)
      (ok (eq t (slot-value request 'hunchentoot::raw-post-data)))
      (ok (null (hunchentoot:raw-post-data :request request :force-binary t)))))
  (testing "a body that was read is not sealed"
    (let ((request (request-object-with (list (cons :content-length "4"))))
          (stream (make-string-input-stream "body")))
      (setf (slot-value request 'hunchentoot::raw-post-data) stream)
      (ok (eq stream (hunchentoot:raw-post-data :request request :force-binary t)))))
  (testing "a request of the library's own class is left alone"
    (let* ((hunchentoot:*reply* (make-instance 'hunchentoot:reply))
           (hunchentoot:*acceptor* (make-instance 'hunchentoot:acceptor :port 0))
           (request (make-instance 'hunchentoot:request
                                   :headers-in (list (cons :content-length "4"))
                                   :method :post :uri "/" :server-protocol :http/1.1
                                   :content-stream nil)))
      (ok (null (enchiridion.channel.http::seal-request-body request))))))

(deftest a-chunked-body-is-framed-without-a-length ()
  ;; A chunked body declares no length, so the framing test has to take the
  ;; transfer encoding itself. Passing a boolean where the header belongs made
  ;; every chunked request look unframed: the body was skipped and refused.
  (let* ((service (enchiridion.channel.http:make-http-service :body-limit 16))
         (request (request-object-with
                   (list (cons :transfer-encoding "chunked"))
                   :content-stream (flex:make-in-memory-input-stream
                                    (make-array 0 :element-type '(unsigned-byte 8)))))
         (parsed (enchiridion.channel.http::request-from-hunchentoot service request)))
    (ok (string= "" (enchiridion.channel.http:http-request-body parsed)))
    (testing "and the body counts as read, not abandoned"
      (ng (enchiridion.channel.http::body-abandoned-p request)))))

(deftest a-zero-length-and-a-chunked-encoding-are-still-two-framings ()
  ;; Hunchentoot bounds a chunked stream by the Content-Length it finds, so a
  ;; zero leaves every chunk on the connection: the refusal is for the header's
  ;; presence, not for its number.
  (let* ((service (enchiridion.channel.http:make-http-service :body-limit 16))
         (request (request-object-with (list (cons :content-length "0")
                                             (cons :transfer-encoding "chunked"))))
         (condition (http-error-of
                     (lambda ()
                       (enchiridion.channel.http::request-from-hunchentoot
                        service request)))))
    (ok (eql 400 (enchiridion.channel.http:http-error-status condition)))
    (ok (search "chunked"
                (enchiridion.channel.http:http-error-message condition)))))

(deftest only-a-json-content-type-is-json ()
  (ok (enchiridion.channel.http:json-content-type-p "application/json"))
  (ok (enchiridion.channel.http:json-content-type-p "application/json; charset=utf-8"))
  (ok (enchiridion.channel.http:json-content-type-p "APPLICATION/JSON"))
  (ng (enchiridion.channel.http:json-content-type-p "text/plain"))
  (ng (enchiridion.channel.http:json-content-type-p nil)))

(deftest the-usage-limit-is-clamped ()
  (flet ((limit (query) (enchiridion.channel.http:usage-limit (get-request "/usage" :query query))))
    (ok (= enchiridion.channel.http:+http-usage-limit+ (limit "")))
    (ok (= 5 (limit "limit=5")))
    (ok (= enchiridion.channel.http:+http-usage-limit+ (limit "limit=0")))
    (ok (= enchiridion.channel.http:+http-usage-limit+ (limit "limit=nonsense")))
    (testing "a limit above the maximum is capped rather than honoured"
      (ok (= enchiridion.channel.http:+http-max-usage-limit+ (limit "limit=999999"))))
    (testing "another parameter does not confuse it"
      (ok (= 7 (limit "other=3&limit=7"))))))

;;;; The routes.

(deftest health-reports-the-live-process-or-its-absence ()
  (testing "a live process answers with what it knows"
    (let ((service (service-with
                    :health (lambda ()
                              (list :ok-p t :uptime 812
                                    :channels (list (list :name "http"
                                                          :state "live"
                                                          :enabled t)))))))
      (multiple-value-bind (status body)
          (enchiridion.channel.http:handle-http-request service (get-request "/health"))
        (ok (eql 200 status))
        (let ((data (json-of body)))
          (ok (eq t (gethash "ok" data)))
          (ok (eql 812 (gethash "uptime" data)))
          (ok (= 1 (length (gethash "channels" data))))))))
  (testing "a process that is not running says so with 503"
    (multiple-value-bind (status body)
        (enchiridion.channel.http:handle-http-request (service-with) (get-request "/health"))
      (ok (eql 503 status))
      (ok (null (gethash "ok" (json-of body)))))))

(deftest health-carries-readiness-beside-the-process-facts ()
  (testing "a live but degraded supervisor is a 503 that names why"
    (let ((service
            (service-with
             :health
             (lambda ()
               (list :ok-p nil :ready nil :uptime 12
                     :reasons #("channel fluxer is failed")
                     :channels (vector (list :name "http" :state "live" :enabled t))
                     :heartbeat (list :enabled t :alive nil :ticks 3 :last-tick 1
                                      :ok t :running nil :report "")
                     :persistence (list :failures 2
                                        :last (list :kind "usage"
                                                    :detail "disk full"))
                     :providers (list :state :done :report "")
                     :writes (list :ok t :report "" :age nil))))))
      (multiple-value-bind (status body)
          (enchiridion.channel.http:handle-http-request service (get-request "/health"))
        (ok (eql 503 status))
        (let ((data (json-of body)))
          (ok (null (gethash "ok" data)))
          (ok (null (gethash "ready" data)))
          (ok (equal "channel fluxer is failed"
                     (aref (gethash "reasons" data) 0)))
          (testing "the heartbeat is an object, not an array"
            (let ((heartbeat (gethash "heartbeat" data)))
              (ok (hash-table-p heartbeat))
              (ok (null (gethash "alive" heartbeat)))
              (ok (eql 3 (gethash "ticks" heartbeat)))))
          (testing "persistence reports its count and the last refusal"
            (let ((persistence (gethash "persistence" data)))
              (ok (eql 2 (gethash "failures" persistence)))
              (ok (equal "disk full"
                         (gethash "detail" (gethash "last" persistence))))))
          (testing "the provider refresh reports what it finished with"
            (ok (equal "done" (gethash "state" (gethash "providers" data)))))))))
  (testing "no persistence failure is null rather than false"
    (let ((service (service-with
                    :health (lambda ()
                              (list :ok-p t :uptime 1
                                    :persistence (list :failures 0 :last :null))))))
      (multiple-value-bind (status body)
          (enchiridion.channel.http:handle-http-request service (get-request "/health"))
        (declare (ignore status))
        (ok (search "\"last\":null" body)))))
  (testing "a ready supervisor answers 200"
    (let ((service
            (service-with
             :health
             (lambda ()
               (list :ok-p t :uptime 1 :reasons #()
                     :channels (list (list :name "http" :state "live" :enabled t)))))))
      (multiple-value-bind (status body)
          (enchiridion.channel.http:handle-http-request service (get-request "/health"))
        (ok (eql 200 status))
        (ok (eq t (gethash "ok" (json-of body))))))))

(deftest usage-answers-from-the-ledger-or-says-there-is-none ()
  (testing "rows come back with every column the ledger holds"
    (let ((service (service-with
                    :usage (lambda (limit)
                             (ok (= 50 limit))
                             (list :ok-p t
                                   :rows (list (list :id 1 :session "s" :model "m"
                                                     :input 10 :output 2
                                                     :cache-read 3 :cache-write 4
                                                     :channel "cli" :ts 1)))))))
      (multiple-value-bind (status body)
          (enchiridion.channel.http:handle-http-request service (get-request "/usage"))
        (ok (eql 200 status))
        (let* ((data (json-of body))
               (row (aref (gethash "rows" data) 0)))
          (ok (eql 1 (gethash "count" data)))
          (ok (eql 10 (gethash "input" row)))
          (ok (eql 3 (gethash "cache-read" row)))
          (ok (eql 4 (gethash "cache-write" row)))))))
  (testing "no store is 503 and not an empty ledger"
    (multiple-value-bind (status body)
        (enchiridion.channel.http:handle-http-request
         (service-with :usage (lambda (limit) (declare (ignore limit))
                                      (list :ok-p nil :error "no store")))
         (get-request "/usage"))
      (ok (eql 503 status))
      (ok (search "no store" body)))))

(deftest a-message-runs-one-turn-and-reports-what-it-cost ()
  (let* ((seen '())
         (service (service-with
                   :turn (lambda (message)
                           (push message seen)
                           (list :ok-p t
                                 :reply "the answer"
                                 :error ""
                                 :reason nil
                                 :usage (list :model "fake" :input 7 :output 3
                                              :cache-read 2 :cache-write 1
                                              :rounds 2 :total 10))))))
    (multiple-value-bind (status body)
        (enchiridion.channel.http:handle-http-request
         service (post-request "{\"text\":\"hello\",\"author\":\"penny\"}"))
      (ok (eql 200 status))
      (let ((data (json-of body)))
        (ok (string= "the answer" (gethash "reply" data)))
        (testing "the usage is the turn's, not one completion's"
          (let ((usage (gethash "usage" data)))
            (ok (eql 7 (gethash "input" usage)))
            (ok (eql 3 (gethash "output" usage)))
            (ok (eql 2 (gethash "rounds" usage)))
            (ok (eql 10 (gethash "total" usage)))))))
    (testing "the turn was handed a normalised message, not a string"
      (ok (= 1 (length seen)))
      (ok (eq :http (enchiridion.channel:msg-channel (first seen))))
      (ok (string= "hello" (enchiridion.channel:msg-text (first seen))))
      (ok (string= "penny" (enchiridion.channel:msg-author (first seen)))))))

(deftest a-message-that-cannot-be-read-is-refused ()
  (let ((service (service-with :turn (lambda (message)
                                       (declare (ignore message))
                                       (list :ok-p t :reply "unreachable")))))
    (testing "a body that is not JSON"
      (let ((condition (http-error-of
                        (lambda ()
                          (enchiridion.channel.http:handle-http-request
                           service (post-request "not json"))))))
        (ok (eql 400 (enchiridion.channel.http:http-error-status condition)))))
    (testing "a JSON body that is not an object"
      (let ((condition (http-error-of
                        (lambda ()
                          (enchiridion.channel.http:handle-http-request
                           service (post-request "[1,2]"))))))
        (ok (eql 400 (enchiridion.channel.http:http-error-status condition)))))
    (testing "an object with no text"
      (let ((condition (http-error-of
                        (lambda ()
                          (enchiridion.channel.http:handle-http-request
                           service (post-request "{\"author\":\"penny\"}"))))))
        (ok (eql 400 (enchiridion.channel.http:http-error-status condition)))))
    (testing "text that is only whitespace"
      (let ((condition (http-error-of
                        (lambda ()
                          (enchiridion.channel.http:handle-http-request
                           service (post-request "{\"text\":\"   \"}"))))))
        (ok (eql 400 (enchiridion.channel.http:http-error-status condition)))))
    (testing "a body that is not declared as JSON"
      (let ((condition (http-error-of
                        (lambda ()
                          (enchiridion.channel.http:handle-http-request
                           service (post-request "{\"text\":\"hi\"}"
                                                 :content-type "text/plain"))))))
        (ok (eql 415 (enchiridion.channel.http:http-error-status condition)))))))

(deftest a-busy-agent-and-a-failed-turn-are-different-answers ()
  (testing "busy is 503 with a retry"
    (let ((condition (http-error-of
                      (lambda ()
                        (enchiridion.channel.http:handle-http-request
                         (service-with :turn (lambda (message)
                                               (declare (ignore message))
                                               (list :ok-p nil :reply "" :error "busy"
                                                     :reason :busy :usage nil)))
                         (post-request "{\"text\":\"hi\"}"))))))
      (ok (eql 503 (enchiridion.channel.http:http-error-status condition)))
      (ok (equal "1" (enchiridion.channel.http::http-error-retry-after condition)))))
  (testing "a failed turn is 502"
    (let ((condition (http-error-of
                      (lambda ()
                        (enchiridion.channel.http:handle-http-request
                         (service-with :turn (lambda (message)
                                               (declare (ignore message))
                                               (list :ok-p nil :reply "" :error "boom"
                                                     :reason :failed :usage nil)))
                         (post-request "{\"text\":\"hi\"}"))))))
      (ok (eql 502 (enchiridion.channel.http:http-error-status condition)))
      (ok (string= "boom" (enchiridion.channel.http:http-error-message condition)))))
  (testing "a service with no turn at all says so rather than lying"
    (let ((condition (http-error-of
                      (lambda ()
                        (enchiridion.channel.http:handle-http-request
                         (service-with) (post-request "{\"text\":\"hi\"}"))))))
      (ok (eql 502 (enchiridion.channel.http:http-error-status condition))))))

(deftest a-turn-that-signals-is-the-upstream-failing ()
  ;; The caller reads one status and acts on it. A condition escaping the turn
  ;; reaches the acceptor's catch-all as a 500, which reads as a bug in the
  ;; webhook rather than a model that went away.
  (let* ((service (service-with
                   :turn (lambda (message)
                           (declare (ignore message))
                           (error "the model went away"))))
         (condition (http-error-of
                     (lambda ()
                       (enchiridion.channel.http:handle-http-request
                        service (post-request "{\"text\":\"hi\"}"))))))
    (ok (eql 502 (enchiridion.channel.http:http-error-status condition)))
    (ok (search "the model went away"
                (enchiridion.channel.http:http-error-message condition)))
    (testing "and the failed turn is not left counted as in flight"
      (ok (zerop (enchiridion.channel.http::turns-running service))))))

;;;; Follow-ups.

(deftest a-keyed-turn-accepts-drains-and-cuts-off-follow-ups ()
  (let ((key (followup-key #\a))
        (service nil)
        (pending nil)
        (events '())
        (closed nil)
        (reused nil))
    (setf service
          (service-with
           :followups-p t
           :turn
           (lambda (message steer)
             (ok (functionp steer))
             (testing "the follow-up cannot rename the sender"
               (ok (string= "penny" (enchiridion.channel:msg-author message))))
             ;; Registered but before the first checkpoint: retryable, never 202.
             (setf pending
                   (message-call service
                                 (json-body "text" "too soon"
                                            "follow_up_to" key)))
             (ok (null (funcall steer :before-request)))
             (testing "an active key cannot start a second turn"
               (let ((duplicate
                       (message-call service
                                     (json-body "text" "duplicate"
                                                "turn_key" key))))
                 (ok (typep duplicate 'enchiridion.channel.http:http-error))
                 (ok (eql 409 (enchiridion.channel.http:http-error-status duplicate)))
                 (ok (string= "turn_key_reused" (error-code duplicate)))))
             (let ((one (message-call service
                                      (json-body "text" "one"
                                                 "follow_up_to" key
                                                 "author" "mallory")))
                   (two (message-call service
                                      (json-body "text" "two"
                                                 "follow_up_to" key))))
               (ok (and (listp one) (eql 202 (first one))))
               (ok (and (listp two) (eql 202 (first two))))
               (testing "the acknowledgement says what it did"
                 (let ((ack (json-of (second one))))
                   (ok (eq t (gethash "ok" ack)))
                   (ok (eq t (gethash "accepted" ack)))))
               (testing "an acknowledgement never carries the key"
                 (ng (search key (second one)))))
             (push (funcall steer :before-request) events)
             (let ((three (message-call service
                                        (json-body "text" "three"
                                                   "follow_up_to" key))))
               (ok (and (listp three) (eql 202 (first three)))))
             (push (funcall steer :before-tools) events)
             (push (funcall steer :before-final) events)
             (setf closed
                   (message-call service
                                 (json-body "text" "after"
                                            "follow_up_to" key)))
             (list :ok-p t :reply "done" :usage nil))))
    (let ((initial (message-call service
                                 (json-body "text" "hello" "turn_key" key
                                            "author" "penny"))))
      (ok (and (listp initial) (eql 200 (first initial))))
      (testing "the initial answer does not echo the key"
        (ng (search key (second initial)))))
    (testing "before the first checkpoint the key is pending, not open"
      (ok (typep pending 'enchiridion.channel.http:http-error))
      (ok (eql 409 (enchiridion.channel.http:http-error-status pending)))
      (ok (string= "turn_pending" (error-code pending)))
      (ok (equal "1" (enchiridion.channel.http::http-error-retry-after pending))))
    (testing "the drains keep arrival order"
      (ok (equal '(("one" "two") ("three") nil) (reverse events))))
    (testing "an empty final drain closes admission for good"
      (ok (typep closed 'enchiridion.channel.http:http-error))
      (ok (eql 409 (enchiridion.channel.http:http-error-status closed)))
      (ok (string= "turn_closed" (error-code closed)))
      (testing "and the refusal does not leak the key"
        (ng (search key (enchiridion.channel.http:http-error-message closed)))))
    (testing "a closed key cannot start another turn"
      (setf reused
            (message-call service
                          (json-body "text" "reuse" "turn_key" key)))
      (ok (typep reused 'enchiridion.channel.http:http-error))
      (ok (eql 409 (enchiridion.channel.http:http-error-status reused)))
      (ok (string= "turn_key_reused" (error-code reused))))))

(deftest a-busy-keyed-turn-never-opens-admission ()
  (let ((key (followup-key #\b))
        (service nil)
        (attempts 0)
        (early nil))
    (setf service
          (service-with
           :followups-p t
           :turn
           (lambda (message steer)
             (declare (ignore message steer))
             (incf attempts)
             (if (= attempts 1)
                 (progn
                   (setf early
                         (message-call service
                                       (json-body "text" "early"
                                                  "follow_up_to" key)))
                   (list :ok-p nil :reply "" :error "busy"
                         :reason :busy :usage nil))
                 (list :ok-p t :reply "second" :usage nil)))))
    (let ((first (message-call service
                               (json-body "text" "hello" "turn_key" key))))
      (ok (typep first 'enchiridion.channel.http:http-error))
      (ok (eql 503 (enchiridion.channel.http:http-error-status first)))
      (ok (equal "1" (enchiridion.channel.http::http-error-retry-after first))))
    (testing "a busy turn refused the follow-up while it was pending"
      (ok (typep early 'enchiridion.channel.http:http-error))
      (ok (eql 409 (enchiridion.channel.http:http-error-status early)))
      (ok (string= "turn_pending" (error-code early))))
    (testing "and it forgot the key rather than leaving it open"
      (let ((late (message-call service
                                (json-body "text" "late"
                                           "follow_up_to" key))))
        (ok (typep late 'enchiridion.channel.http:http-error))
        (ok (eql 409 (enchiridion.channel.http:http-error-status late)))
        (ok (string= "unknown_turn" (error-code late)))))
    (testing "the same key can be retried after the 503"
      (let ((retry (message-call service
                                 (json-body "text" "again" "turn_key" key))))
        (ok (listp retry))
        (ok (eql 200 (first retry)))))))

(deftest a-keyed-turn-caps-follow-ups-at-four-texts ()
  (let ((key (followup-key #\c))
        (service nil)
        (fifth nil)
        (drained nil))
    (setf service
          (service-with
           :followups-p t
           :turn
           (lambda (message steer)
             (declare (ignore message))
             (ok (null (funcall steer :before-request)))
             (dotimes (index enchiridion.channel.http::+http-followup-limit+)
               (let ((accepted
                       (message-call service
                                     (json-body "text" (format nil "f~D" index)
                                                "follow_up_to" key))))
                 (ok (and (listp accepted) (eql 202 (first accepted))))))
             (setf fifth
                   (message-call service
                                 (json-body "text" "fifth"
                                            "follow_up_to" key)))
             (setf drained (funcall steer :before-request))
             (list :ok-p t :reply "done" :usage nil))))
    (let ((initial (message-call service
                                 (json-body "text" "hello" "turn_key" key))))
      (ok (and (listp initial) (eql 200 (first initial)))))
    (ok (typep fifth 'enchiridion.channel.http:http-error))
    (ok (eql 409 (enchiridion.channel.http:http-error-status fifth)))
    (ok (string= "turn_full" (error-code fifth)))
    (ok (= 4 (length drained)))))

(deftest a-keyed-turn-caps-follow-up-characters ()
  (let* ((key (followup-key #\d))
         (large (make-string enchiridion.channel.http::+http-followup-chars+
                             :initial-element #\x))
         (service nil)
         (overflow nil)
         (drained nil))
    (setf service
          (service-with
           :followups-p t
           :turn
           (lambda (message steer)
             (declare (ignore message))
             (ok (null (funcall steer :before-request)))
             (let ((accepted (message-call service
                                           (json-body "text" large
                                                      "follow_up_to" key))))
               (ok (and (listp accepted) (eql 202 (first accepted)))))
             (setf overflow
                   (message-call service
                                 (json-body "text" "x" "follow_up_to" key)))
             (setf drained (funcall steer :before-request))
             (list :ok-p t :reply "done" :usage nil))))
    (let ((initial (message-call service
                                 (json-body "text" "hello" "turn_key" key))))
      (ok (and (listp initial) (eql 200 (first initial)))))
    (ok (typep overflow 'enchiridion.channel.http:http-error))
    (ok (eql 409 (enchiridion.channel.http:http-error-status overflow)))
    (ok (string= "turn_full" (error-code overflow)))
    (testing "the one text that fits is drained untouched"
      (ok (equal (list large) drained)))))

(deftest follow-up-fields-are-validated-before-admission ()
  (let ((service (service-with
                  :followups-p t
                  :turn (lambda (message steer)
                          (declare (ignore message steer))
                          (list :ok-p t :reply "unreached" :usage nil)))))
    (testing "a malformed initial key is a coded 400"
      (dolist (candidate
                (list (make-string
                       (1- enchiridion.channel.http::+http-turn-key-length+)
                       :initial-element #\a)
                      (make-string
                       (1+ enchiridion.channel.http::+http-turn-key-length+)
                       :initial-element #\a)
                      (make-string enchiridion.channel.http::+http-turn-key-length+
                                   :initial-element #\A)
                      "not-a-key"))
        (let ((condition
                (message-call service
                              (json-body "text" "hi" "turn_key" candidate))))
          (ok (typep condition 'enchiridion.channel.http:http-error))
          (ok (eql 400 (enchiridion.channel.http:http-error-status condition)))
          (ok (string= "invalid_turn_key" (error-code condition))))))
    (testing "a malformed follow-up key is a coded 400"
      (let ((condition
              (message-call service
                            (json-body "text" "hi" "follow_up_to"
                                       (make-string
                                        enchiridion.channel.http::+http-turn-key-length+
                                        :initial-element #\G)))))
        (ok (typep condition 'enchiridion.channel.http:http-error))
        (ok (eql 400 (enchiridion.channel.http:http-error-status condition)))
        (ok (string= "invalid_turn_key" (error-code condition)))))
    (testing "a malformed reply_to is a coded 400"
      (let ((condition
              (message-call service
                            (json-body "text" "hi" "reply_to"
                                       (make-string
                                        (1- enchiridion.channel.http::+http-turn-key-length+)
                                        :initial-element #\a)))))
        (ok (typep condition 'enchiridion.channel.http:http-error))
        (ok (eql 400 (enchiridion.channel.http:http-error-status condition)))
        (ok (string= "invalid_reply_to" (error-code condition)))))
    (testing "both fields at once are a 400, not a guess"
      (let ((condition
              (message-call service
                            (json-body "text" "hi"
                                       "turn_key" (followup-key #\a)
                                       "follow_up_to" (followup-key #\b)))))
        (ok (typep condition 'enchiridion.channel.http:http-error))
        (ok (eql 400 (enchiridion.channel.http:http-error-status condition)))
        (ok (string= "turn_key_conflict" (error-code condition)))))
    (testing "reply_to cannot be combined with follow_up_to"
      (let ((condition
              (message-call service
                            (json-body "text" "hi"
                                       "reply_to" (followup-key #\c)
                                       "follow_up_to" (followup-key #\d)))))
        (ok (typep condition 'enchiridion.channel.http:http-error))
        (ok (eql 400 (enchiridion.channel.http:http-error-status condition)))
        (ok (string= "turn_key_conflict" (error-code condition)))))
    (testing "a well-formed key with no turn is a 409 unknown"
      (let ((condition
              (message-call service
                            (json-body "text" "hi" "follow_up_to"
                                       (followup-key #\9)))))
        (ok (typep condition 'enchiridion.channel.http:http-error))
        (ok (eql 409 (enchiridion.channel.http:http-error-status condition)))
        (ok (string= "unknown_turn" (error-code condition)))
        (testing "which is a different code from closed"
          (ng (string= "turn_closed" (error-code condition))))))
    (testing "a follow-up needs non-empty text"
      (let ((condition
              (message-call service
                            (json-body "text" "   " "follow_up_to"
                                       (followup-key)))))
        (ok (typep condition 'enchiridion.channel.http:http-error))
        (ok (eql 400 (enchiridion.channel.http:http-error-status condition)))))))

(deftest follow-up-fields-need-the-opt-in-flag ()
  (let ((service (service-with
                  :turn (lambda (message)
                          (declare (ignore message))
                          (list :ok-p t :reply "plain" :usage nil)))))
    (dolist (body (list (json-body "text" "hi" "turn_key" (followup-key))
                        (json-body "text" "hi" "follow_up_to" (followup-key))
                        (json-body "text" "hi" "reply_to" (followup-key))))
      (let ((condition (message-call service body)))
        (ok (typep condition 'enchiridion.channel.http:http-error))
        (ok (eql 400 (enchiridion.channel.http:http-error-status condition)))
        (ok (string= "followups_disabled" (error-code condition)))))
    (testing "the same service still runs a plain message"
      (let ((result (message-call service (json-body "text" "hi"))))
        (ok (and (listp result) (eql 200 (first result))))))))

(deftest a-service-with-followups-on-still-takes-plain-messages ()
  (let* ((seen nil)
         (service (service-with
                   :followups-p t
                   :turn (lambda (message)
                           (setf seen message)
                           (list :ok-p t :reply "plain" :usage nil))))
         (result (message-call service (json-body "text" "hello"))))
    (ok (and (listp result) (eql 200 (first result))))
    (ok (string= "hello" (enchiridion.channel:msg-text seen)))))

;;;; Reused work.

(deftest a-late-message-reuses-completed-work-once ()
  (let* ((key (followup-key #\1))
         (other (followup-key #\2))
         (seen '())
         (service nil))
    (setf service
          (service-with
           :followups-p t
           :turn
           (lambda (message &optional steer work)
             (when steer (funcall steer :before-request))
             (let ((text (enchiridion.channel:msg-text message)))
               (push (list text work) seen)
               (list :ok-p t :reply text
                     :work (if (string= "first" text) "opaque-work" nil)
                     :usage nil)))))
    (let ((initial (message-call service
                                 (json-body "text" "first" "turn_key" key))))
      (ok (and (listp initial) (eql 200 (first initial))))
      (testing "the work never reaches the answer"
        (ng (search "opaque-work" (second initial)))
        (ng (search key (second initial)))))
    (testing "a refused key does not burn the remembered work"
      (let ((refused (message-call service
                                   (json-body "text" "refused"
                                              "reply_to" key
                                              "turn_key" key))))
        (ok (typep refused 'enchiridion.channel.http:http-error))
        (ok (eql 409 (enchiridion.channel.http:http-error-status refused)))
        (ok (string= "turn_key_reused" (error-code refused)))))
    (testing "an unmatched reply_to runs a normal turn and leaves the work"
      (let ((unmatched (message-call service
                                     (json-body "text" "unmatched"
                                                "reply_to" other))))
        (ok (and (listp unmatched) (eql 200 (first unmatched))))))
    (testing "a matching reply_to gets the work once"
      (let ((reused (message-call service
                                  (json-body "text" "reused"
                                             "reply_to" key))))
        (ok (and (listp reused) (eql 200 (first reused))))
        (ng (search "opaque-work" (second reused)))
        (ng (search key (second reused)))))
    (testing "the next matching reply_to runs without work"
      (let ((again (message-call service
                                 (json-body "text" "again"
                                            "reply_to" key))))
        (ok (and (listp again) (eql 200 (first again))))))
    (testing "the calls show work only on the reuse"
      (ok (equal '(("first" nil) ("unmatched" nil)
                   ("reused" "opaque-work") ("again" nil))
                 (reverse seen))))))

(deftest work-can-ride-with-a-new-turn-key ()
  (let* ((old (followup-key #\3))
         (new (followup-key #\4))
         (seen '())
         (service nil))
    (setf service
          (service-with
           :followups-p t
           :turn
           (lambda (message &optional steer work)
             (when steer (funcall steer :before-request))
             (let ((text (enchiridion.channel:msg-text message)))
               (push (list text work (functionp steer)) seen)
               (list :ok-p t :reply text
                     :work (if (string= "first" text) "first-work" nil)
                     :usage nil)))))
    (let ((first (message-call service
                               (json-body "text" "first" "turn_key" old))))
      (ok (and (listp first) (eql 200 (first first)))))
    (let ((second (message-call service
                                (json-body "text" "second"
                                           "reply_to" old
                                           "turn_key" new))))
      (ok (and (listp second) (eql 200 (first second))))
      (testing "the prior work never reaches the answer"
        (ng (search "first-work" (second second)))
        (ng (search old (second second)))))
    (testing "the second turn ran with its own key and the prior work"
      (ok (equal '(("first" nil t) ("second" "first-work" t))
                 (reverse seen))))))

(deftest a-reply-to-probe-is-an-ordinary-turn-not-a-follow-up ()
  (let* ((key (followup-key #\8))
         (calls 0)
         (service (service-with
                   :followups-p t
                   :turn (lambda (message &optional steer work)
                           (declare (ignore steer work))
                           (incf calls)
                           (list :ok-p t
                                 :reply (enchiridion.channel:msg-text message)
                                 :usage nil)))))
    (let ((turn (enchiridion.channel.http::register-http-turn service key)))
      (setf (enchiridion.channel.http::http-turn-state turn) :accepting)
      (let ((result (message-call service
                                  (json-body "text" "ordinary"
                                             "reply_to" key))))
        (ok (and (listp result) (eql 200 (first result))))
        (ok (string= "ordinary"
                     (gethash "reply" (json-of (second result)))))
        (testing "the active turn was not handed the text"
          (ok (null (enchiridion.channel.http::http-turn-queue turn))))
        (ok (= 1 calls))))))

(deftest remembered-work-expires-and-unmatched-probes-do-not-clear-it ()
  (let* ((service (service-with :followups-p t))
         (key (followup-key #\5))
         (work (enchiridion.channel.http::%make-http-work
                :key key :work "old"
                :at (get-internal-real-time))))
    (setf (enchiridion.channel.http::http-service-last-work service) work)
    (testing "an unmatched key leaves the entry alone"
      (ok (null (enchiridion.channel.http::claim-http-work
                 service (followup-key #\6))))
      (ok (eq work (enchiridion.channel.http::http-service-last-work service))))
    (testing "expired work is refused and the entry is cleared"
      (decf (enchiridion.channel.http::http-work-at work)
            (* (1+ enchiridion.channel.http::+http-reply-reuse-seconds+)
               internal-time-units-per-second))
      (ok (null (enchiridion.channel.http::claim-http-work service key)))
      (ok (null (enchiridion.channel.http::http-service-last-work service))))))

(deftest work-is-remembered-only-for-successful-keyed-turns ()
  (testing "a failed keyed turn leaves nothing to reuse"
    (let ((service (service-with
                    :followups-p t
                    :turn (lambda (message &optional steer work)
                            (declare (ignore message work))
                            (when steer (funcall steer :before-request))
                            (list :ok-p nil :reply "" :error "boom"
                                  :reason :failed :work "failed" :usage nil)))))
      (let ((result (message-call service
                                  (json-body "text" "hi"
                                             "turn_key" (followup-key #\a)))))
        (ok (typep result 'enchiridion.channel.http:http-error))
        (ok (eql 502 (enchiridion.channel.http:http-error-status result)))
        (ok (null (enchiridion.channel.http::http-service-last-work service))))))
  (testing "a successful unkeyed turn has no key to remember work under"
    (let ((service (service-with
                    :followups-p t
                    :turn (lambda (message &optional steer work)
                            (declare (ignore message steer work))
                            (list :ok-p t :reply "plain" :work "unkeyed" :usage nil)))))
      (let ((result (message-call service (json-body "text" "hi"))))
        (ok (and (listp result) (eql 200 (first result))))
        (ok (null (enchiridion.channel.http::http-service-last-work service)))))))

(deftest a-busy-turn-keeps-the-work-for-the-retry ()
  (let* ((key (followup-key #\c))
         (seen '())
         (service nil))
    (setf service
          (service-with
           :followups-p t
           :turn
           (lambda (message &optional steer work)
             (when steer (funcall steer :before-request))
             (let ((text (enchiridion.channel:msg-text message)))
               (push (list text work) seen)
               (cond
                 ((string= "first" text)
                  (list :ok-p t :reply "first" :work "kept-work" :usage nil))
                 ((string= "busy" text)
                  (list :ok-p nil :reply "" :error "busy"
                        :reason :busy :usage nil))
                 (t
                  (list :ok-p t :reply "later" :usage nil)))))))
    (let ((first (message-call service
                               (json-body "text" "first" "turn_key" key))))
      (ok (and (listp first) (eql 200 (first first)))))
    (testing "a busy turn answers 503 without spending the work"
      (let ((busy (message-call service
                                (json-body "text" "busy" "reply_to" key))))
        (ok (typep busy 'enchiridion.channel.http:http-error))
        (ok (eql 503 (enchiridion.channel.http:http-error-status busy)))))
    (testing "the retry still gets the work"
      (let ((retry (message-call service
                                 (json-body "text" "retry" "reply_to" key))))
        (ok (and (listp retry) (eql 200 (first retry))))))
    (testing "and the next request finds it spent"
      (let ((again (message-call service
                                 (json-body "text" "again" "reply_to" key))))
        (ok (and (listp again) (eql 200 (first again))))))
    (testing "the busy attempt and the retry both saw the work"
      (ok (equal '(("first" nil) ("busy" "kept-work")
                   ("retry" "kept-work") ("again" nil))
                 (reverse seen))))))

(deftest restoring-claimed-work-never-overwrites-newer-work ()
  (let ((service (service-with :followups-p t))
        (old (followup-key #\d))
        (new (followup-key #\e)))
    (setf (enchiridion.channel.http::http-service-last-work service)
          (enchiridion.channel.http::%make-http-work
           :key old :work "old" :at (get-internal-real-time)))
    (multiple-value-bind (work claimed)
        (enchiridion.channel.http::claim-http-work service old)
      (ok (string= "old" work))
      (ok claimed)
      (enchiridion.channel.http::remember-http-work service new "new")
      (enchiridion.channel.http::restore-http-work service claimed)
      (let ((stored (enchiridion.channel.http::http-service-last-work service)))
        (testing "the newer entry survives the restore"
          (ok (string= new (enchiridion.channel.http::http-work-key stored)))
          (ok (string= "new" (enchiridion.channel.http::http-work-work stored))))))))

(deftest a-follow-up-is-authenticated-like-any-message ()
  (let ((key (followup-key #\e))
        (service nil)
        (unauthorized nil)
        (drained nil))
    (setf service
          (service-with
           :followups-p t :token "s3cret"
           :turn
           (lambda (message steer)
             (declare (ignore message))
             (ok (null (funcall steer :before-request)))
             (setf unauthorized
                   (message-call service
                                 (json-body "text" "no"
                                            "follow_up_to" key)
                                 :authorization "Bearer wrong"))
             (let ((accepted (message-call service
                                           (json-body "text" "yes"
                                                      "follow_up_to" key)
                                           :authorization "Bearer s3cret")))
               (ok (and (listp accepted) (eql 202 (first accepted)))))
             (setf drained (funcall steer :before-request))
             (list :ok-p t :reply "done" :usage nil))))
    (let ((initial (message-call service
                                 (json-body "text" "hello" "turn_key" key)
                                 :authorization "Bearer s3cret")))
      (ok (and (listp initial) (eql 200 (first initial)))))
    (testing "a wrong token is rejected before admission"
      (ok (typep unauthorized 'enchiridion.channel.http:http-error))
      (ok (eql 401 (enchiridion.channel.http:http-error-status unauthorized))))
    (testing "only the authenticated follow-up made it into the drain"
      (ok (equal '("yes") drained)))))

(deftest a-turn-that-returns-without-a-final-drain-closes-its-key ()
  (let ((key (followup-key #\f))
        (service nil)
        (accepted nil))
    (setf service
          (service-with
           :followups-p t
           :turn
           (lambda (message steer)
             (declare (ignore message))
             (ok (null (funcall steer :before-request)))
             (setf accepted
                   (message-call service
                                 (json-body "text" "queued"
                                            "follow_up_to" key)))
             (list :ok-p t :reply "done" :usage nil))))
    (let ((initial (message-call service
                                 (json-body "text" "hello" "turn_key" key))))
      (ok (and (listp initial) (eql 200 (first initial)))))
    (ok (and (listp accepted) (eql 202 (first accepted))))
    (let ((late (message-call service
                              (json-body "text" "late"
                                         "follow_up_to" key))))
      (ok (typep late 'enchiridion.channel.http:http-error))
      (ok (eql 409 (enchiridion.channel.http:http-error-status late)))
      (ok (string= "turn_closed" (error-code late))))))

(deftest an-error-code-travels-in-the-json-body ()
  (let ((coded (json-of (enchiridion.channel.http::error-body
                         "no such turn" "turn_closed")))
        (plain (json-of (enchiridion.channel.http::error-body "plain"))))
    (ok (string= "turn_closed" (gethash "code" coded)))
    (testing "an error without a code keeps its old shape"
      (ok (null (gethash "code" plain))))))

(deftest stopping-a-service-closes-open-keys ()
  (let* ((key (followup-key #\7))
         (service (service-with :followups-p t)))
    (let ((turn (enchiridion.channel.http::register-http-turn service key)))
      (setf (enchiridion.channel.http::http-turn-state turn) :accepting)
      (setf (enchiridion.channel.http::http-service-last-work service)
            (enchiridion.channel.http::%make-http-work
             :key key :work "old" :at (get-internal-real-time)))
      (enchiridion.channel.http::close-http-turns service)
      (ok (null (enchiridion.channel.http::http-service-last-work service)))
      (let ((condition
              (message-call service
                            (json-body "text" "late" "follow_up_to" key))))
        (ok (typep condition 'enchiridion.channel.http:http-error))
        (ok (eql 409 (enchiridion.channel.http:http-error-status condition)))
        (ok (string= "turn_closed" (error-code condition)))))))

(deftest an-unknown-route-and-a-wrong-method-are-refused ()
  (let ((service (service-with)))
    (testing "a known path with the wrong method is 405 and names the right one"
      (let ((condition (http-error-of
                        (lambda ()
                          (enchiridion.channel.http:handle-http-request
                           service (get-request "/message"))))))
        (ok (eql 405 (enchiridion.channel.http:http-error-status condition)))
        (ok (string= "POST" (enchiridion.channel.http::http-error-allow condition)))))
    (testing "anything else is 404"
      (let ((condition (http-error-of
                        (lambda ()
                          (enchiridion.channel.http:handle-http-request
                           service (get-request "/nope"))))))
        (ok (eql 404 (enchiridion.channel.http:http-error-status condition)))))))

(deftest a-wrong-token-never-reaches-a-route ()
  (let* ((turns 0)
         (service (service-with :token "s3cret"
                                :turn (lambda (message)
                                        (declare (ignore message))
                                        (incf turns)
                                        (list :ok-p t :reply "unreachable")))))
    (testing "no token is 401"
      (let ((condition (http-error-of
                        (lambda ()
                          (enchiridion.channel.http:dispatch-http-request
                           service (post-request "{\"text\":\"hi\"}"))))))
        (ok (eql 401 (enchiridion.channel.http:http-error-status condition)))))
    (testing "a wrong token is 401"
      (let ((condition (http-error-of
                        (lambda ()
                          (enchiridion.channel.http:dispatch-http-request
                           service (post-request "{\"text\":\"hi\"}"
                                                 :authorization "Bearer nope"))))))
        (ok (eql 401 (enchiridion.channel.http:http-error-status condition)))))
    (testing "and neither of them ran a turn"
      (ok (zerop turns)))
    (testing "the right token runs it"
      (multiple-value-bind (status body)
          (enchiridion.channel.http:dispatch-http-request
           service (post-request "{\"text\":\"hi\"}"
                                 :authorization "Bearer s3cret"))
        (ok (eql 200 status))
        (ok (string= "unreachable" (gethash "reply" (json-of body))))
        (ok (= 1 turns))))))

;;;; The socket.

(deftest the-acceptor-answers-and-stops ()
  ;; One test binds a real port, because the acceptor, the dispatch method and
  ;; the response write are the parts a pure test cannot reach. The port is 0:
  ;; the system picks a free one, so two gates running side by side and a live
  ;; serve on 8787 cannot collide.
  (let* ((channel (enchiridion.channel.http:make-http-channel
                   :service (service-with
                             :bind "127.0.0.1" :port 0
                             :health (lambda ()
                                       (list :ok-p t :uptime 1 :channels '()))
                             :turn (lambda (message)
                                     (declare (ignore message))
                                     (list :ok-p t :reply "over the wire"
                                           :error "" :reason nil
                                           :usage (list :model "fake" :input 1
                                                        :output 2 :rounds 1
                                                        :total 3))))))
         (thread nil)
         (port nil))
    (unwind-protect
         (handler-case
             (progn
               (setf thread
                     (bordeaux-threads:make-thread
                      (lambda () (enchiridion.channel:channel-start channel))
                      :name "enchiridion http test"))
               (loop repeat 100
                     until (setf port (and (enchiridion.channel:channel-live-p channel)
                                           (let ((acceptor
                                                   (enchiridion.channel.http:http-channel-acceptor
                                                    channel)))
                                             (and acceptor
                                                  (hunchentoot:acceptor-port acceptor)))))
                     do (sleep 0.05))
               (ok port "the acceptor reported the port it chose")
               (when port
                 (let ((body (dexador:post (format nil "http://127.0.0.1:~D/message" port)
                                           :content "{\"text\":\"hello\"}"
                                           :headers '(("content-type" . "application/json")))))
                   (ok (search "over the wire" body)))
                 (let ((health (dexador:get (format nil "http://127.0.0.1:~D/health" port))))
                   (ok (search "uptime" health)))))
           (error (condition)
             ;; A build whose sandbox has no loopback interface skips this one
             ;; test by name and says so; everything else in the suite runs.
             ;; The alternative, failing the whole gate on the environment, is
             ;; how a real failure gets ignored later.
             (if (enchiridion.compat:environment-value "ENCHIRIDION_NO_SOCKET_TESTS")
                 (progn
                   (format *error-output*
                           "~&enchiridion-http-test: socket test skipped: ~A~%" condition)
                   (finish-output *error-output*)
                   (ok t "skipped by ENCHIRIDION_NO_SOCKET_TESTS"))
                 (ok nil (format nil "binding a loopback port failed: ~A" condition)))))
      (enchiridion.channel:channel-stop channel)
      (when (and thread (bordeaux-threads:thread-alive-p thread))
        (bordeaux-threads:join-thread thread)))))

;;;; The connection.

;; A refused body takes its connection with it: hunchentoot reads the next
;; request from the same socket. These helpers speak HTTP/1.1 by hand, so the
;; test holds the socket and not a client library's connection pool.

(defun read-http-line (stream)
  "Return one CRLF terminated line from STREAM, or :EOF when it ends first."
  (let ((line (make-array 0 :element-type 'character :adjustable t :fill-pointer 0)))
    (loop for octet = (read-byte stream nil :eof)
          do (cond ((eq octet :eof) (return :eof))
                   ((= octet 10) (return (coerce line 'string)))
                   ((= octet 13) nil)
                   (t (vector-push-extend (code-char octet) line))))))

(defun read-http-response (stream)
  "Return one response as a plist of :STATUS, :HEADERS and :BODY, or NIL at EOF.
The body is read by its content length, so the next byte read is the first byte
of whatever comes next on the connection."
  (let ((status (read-http-line stream)))
    (when (and (stringp status) (plusp (length status)))
      (let ((headers '()))
        (loop for line = (read-http-line stream)
              until (or (eq line :eof) (zerop (length line)))
              do (let ((colon (position #\: line)))
                   (when colon
                     (push (cons (string-downcase (subseq line 0 colon))
                                 (string-trim '(#\Space) (subseq line (1+ colon))))
                           headers))))
        (let* ((size (let ((value (cdr (assoc "content-length" headers :test #'string=))))
                       (and value (parse-integer value))))
               (body (make-array 0 :element-type 'character
                                   :adjustable t :fill-pointer 0)))
          (loop repeat (or size 0)
                for octet = (read-byte stream nil :eof)
                until (eq octet :eof)
                do (vector-push-extend (code-char octet) body))
          (list :status status :headers headers :body (coerce body 'string)))))))

(defun write-http-request (stream text)
  "Write TEXT to STREAM as UTF-8 octets and flush it."
  (write-sequence (enchiridion.compat:encode-utf8 text) stream)
  (finish-output stream))

(defun request-text (method path &key content-length content-type authorization body)
  "Return one HTTP/1.1 request as text. No body is written unless one is given."
  (with-output-to-string (out)
    (format out "~A ~A HTTP/1.1~C~C" method path #\Return #\Newline)
    (format out "Host: 127.0.0.1~C~C" #\Return #\Newline)
    (when authorization
      (format out "Authorization: ~A~C~C" authorization #\Return #\Newline))
    (when content-type
      (format out "Content-Type: ~A~C~C" content-type #\Return #\Newline))
    (when content-length
      (format out "Content-Length: ~D~C~C" content-length #\Return #\Newline))
    (format out "~C~C~A" #\Return #\Newline (or body ""))))

(defun next-response (socket seconds)
  "Return the next response on SOCKET, :CLOSED at end of file, or :TIMEOUT.

The read runs on its own thread with a deadline, because the interesting failure
is a server that neither answers nor closes. The socket is closed underneath an
overrunning read, which wakes it."
  (let* ((stream (usocket:socket-stream socket))
         (outcome :timeout)
         (answered nil)
         (reader (bordeaux-threads:make-thread
                  (lambda ()
                    (setf outcome (handler-case (or (read-http-response stream) :closed)
                                    (error () :closed))
                          answered t))
                  :name "enchiridion http test reader")))
    (loop repeat (round (/ seconds 0.02))
          until answered
          do (sleep 0.02))
    (cond
      (answered (bordeaux-threads:join-thread reader) outcome)
      (t (ignore-errors (usocket:socket-close socket)) :timeout))))

(defun open-connection (port)
  "Return a socket connected to the webhook on PORT."
  (usocket:socket-connect "127.0.0.1" port :element-type '(unsigned-byte 8)))

(defun start-channel-in-thread (channel)
  "Start CHANNEL on its own thread. Return the thread and the port it bound."
  (let ((thread (bordeaux-threads:make-thread
                 (lambda () (enchiridion.channel:channel-start channel))
                 :name "enchiridion http test")))
    (loop repeat 100
          for acceptor = (enchiridion.channel.http:http-channel-acceptor channel)
          for port = (and (enchiridion.channel:channel-live-p channel)
                          acceptor
                          (hunchentoot:acceptor-port acceptor))
          do (if port
                 (return (values thread port))
                 (sleep 0.05)))))

(deftest a-keyed-follow-up-reaches-the-original-http-connection ()
  (if (enchiridion.compat:environment-value "ENCHIRIDION_NO_SOCKET_TESTS")
      (ok t "skipped by ENCHIRIDION_NO_SOCKET_TESTS")
      (let* ((ready (bordeaux-threads:make-semaphore))
             (finish (bordeaux-threads:make-semaphore))
             (key (followup-key))
             (channel (enchiridion.channel.http:make-http-channel
                       :service (service-with
                                 :port 0 :token "local-test" :followups-p t
                                 :turn (lambda (message &optional steer)
                                         (declare (ignore message))
                                         (funcall steer :before-request)
                                         (bordeaux-threads:signal-semaphore ready)
                                         (unless (bordeaux-threads:wait-on-semaphore finish :timeout 5)
                                           (error "The follow-up test did not release the turn."))
                                         (list :ok-p t :reply (car (funcall steer :before-final)))))))
             (original nil)
             (later nil)
             (thread nil))
        (flet ((post (socket body)
                 (write-http-request
                  (usocket:socket-stream socket)
                  (request-text "POST" "/message" :body body
                                :content-length (length body)
                                :authorization "Bearer local-test"
                                :content-type "application/json"))))
          (unwind-protect
               (multiple-value-bind (worker port) (start-channel-in-thread channel)
                 (setf thread worker)
                 (ok port)
                 (when port
                   (setf original (open-connection port)
                         later (open-connection port))
                   (post original (json-body "text" "first" "turn_key" key))
                   (let ((opened (bordeaux-threads:wait-on-semaphore ready :timeout 3)))
                     (ok opened)
                     (when opened
                       (post later (json-body "text" "joined" "follow_up_to" key))
                       (let ((accepted (next-response later 3)))
                         (ok (and (listp accepted) (search " 202 " (getf accepted :status)))))
                       (bordeaux-threads:signal-semaphore finish)
                       (let ((reply (next-response original 3)))
                         (ok (and (listp reply)
                                  (search "\"reply\":\"joined\"" (getf reply :body)))))))))
            (bordeaux-threads:signal-semaphore finish)
            (when original (ignore-errors (usocket:socket-close original)))
            (when later (ignore-errors (usocket:socket-close later)))
            (enchiridion.channel:channel-stop channel)
            (when (and thread (bordeaux-threads:thread-alive-p thread))
              (bordeaux-threads:join-thread thread)))))))

(deftest a-refused-body-takes-its-connection-with-it ()
  ;; Two answers depend on what happened to the body. One that read it may keep
  ;; the connection; one that refused before reading cannot, because the bytes
  ;; it never read would be read as the next request. Both requests are ordinary:
  ;; a message, and one whose size or token is refused.
  (let* ((body "{\"text\":\"hello\"}")
         (service (service-with
                   :bind "127.0.0.1" :port 0 :body-limit 64 :token "s3cret"
                   :health (lambda () (list :ok-p t :uptime 1 :channels '()))
                   :turn (lambda (message)
                           (declare (ignore message))
                           (list :ok-p t :reply "taken" :error "" :reason nil
                                 :usage (list :model "fake" :input 1 :output 1
                                              :rounds 1 :total 2)))))
         (channel (enchiridion.channel.http:make-http-channel :service service)))
    (unwind-protect
         (handler-case
             (multiple-value-bind (thread port) (start-channel-in-thread channel)
               (declare (ignore thread))
               (ok port "the acceptor reported the port it chose")
               (when port
                 (testing "a body that was read keeps the connection"
                   (let ((socket (open-connection port)))
                     (unwind-protect
                          (progn
                            (write-http-request
                             (usocket:socket-stream socket)
                             (request-text "POST" "/message"
                                           :authorization "Bearer s3cret"
                                           :content-type "application/json"
                                           :content-length (length body)
                                           :body body))
                            (let ((first (next-response socket 5)))
                              (ok (listp first) "the message was answered")
                              (when (listp first)
                                (ok (search " 200 " (getf first :status)))
                                (ok (null (assoc "connection" (getf first :headers)
                                                 :test #'string=))
                                    "and the answer does not ask for a close")))
                            (write-http-request (usocket:socket-stream socket)
                                                (request-text "GET" "/health"
                                                              :authorization "Bearer s3cret"))
                            (let ((second (next-response socket 5)))
                              (ok (listp second)
                                  "the same connection answered a second request")
                              (when (listp second)
                                (ok (search " 200 " (getf second :status))))))
                       (ignore-errors (usocket:socket-close socket)))))
                 (testing "a refusal that read no body closes it"
                   ;; A complete request whose body is never read: the token is
                   ;; missing, or the declared size is refused before a byte is
                   ;; taken. The answer has to say the connection is done, because
                   ;; those bytes are what the next read would call a request.
                   (flet ((refusal (authorization body notice)
                            (let ((socket (open-connection port)))
                              (unwind-protect
                                   (progn
                                     (write-http-request
                                      (usocket:socket-stream socket)
                                      (request-text "POST" "/message"
                                                    :authorization authorization
                                                    :content-type "application/json"
                                                    :content-length (length body)
                                                    :body body))
                                     (let ((response (next-response socket 5)))
                                       (ok (listp response)
                                           (format nil "the ~A was answered" notice))
                                       (when (listp response)
                                         (ok (search (format nil " ~A " notice)
                                                     (getf response :status)))
                                         (ok (string= "close"
                                                      (cdr (assoc "connection"
                                                                  (getf response :headers)
                                                                  :test #'string=)))
                                             "and the answer asks for the close")))
                                     (ok (eq :closed (next-response socket 2))
                                         (format nil "the ~A closed the connection" notice)))
                                (ignore-errors (usocket:socket-close socket))))))
                     (refusal nil body "401")
                     (refusal "Bearer s3cret" (make-string 200 :initial-element #\a) "413")))))
           (error (condition)
             (if (enchiridion.compat:environment-value "ENCHIRIDION_NO_SOCKET_TESTS")
                 (progn
                   (format *error-output*
                           "~&enchiridion-http-test: connection test skipped: ~A~%" condition)
                   (finish-output *error-output*)
                   (ok t "skipped by ENCHIRIDION_NO_SOCKET_TESTS"))
                 (ok nil (format nil "a loopback connection failed: ~A" condition)))))
      (enchiridion.channel:channel-stop channel))))

;;;; The stop.

;; A fake acceptor makes the budget the only thing under test: no socket, no
;; handler, only a stop that returns at once and a stop that does not.

(defclass quiet-acceptor (hunchentoot:acceptor) ())

(defmethod hunchentoot:stop ((acceptor quiet-acceptor) &key soft)
  (declare (ignore soft))
  acceptor)

(defclass sluggish-acceptor (quiet-acceptor)
  ((slowed-p :accessor sluggish-acceptor-slowed-p :initform nil :type boolean))
  (:documentation "An acceptor whose first stop outlasts any sane budget."))

(defmethod hunchentoot:stop ((acceptor sluggish-acceptor) &key soft)
  (declare (ignore soft))
  (unless (sluggish-acceptor-slowed-p acceptor)
    (setf (sluggish-acceptor-slowed-p acceptor) t)
    (sleep 1))
  acceptor)

(defun channel-over (service &key acceptor)
  "Return a channel over SERVICE whose acceptor slot holds ACCEPTOR."
  (let ((channel (enchiridion.channel.http:make-http-channel :service service)))
    (setf (enchiridion.channel.http:http-channel-acceptor channel) acceptor)
    channel))

(defun elapsed-seconds (started)
  "Return the seconds since STARTED, a GET-INTERNAL-REAL-TIME value."
  (/ (- (get-internal-real-time) started) internal-time-units-per-second))

(deftest a-stop-spends-its-budget-and-no-more ()
  (testing "nothing running is nothing waited for"
    (let* ((channel (channel-over (service-with) :acceptor (make-instance 'quiet-acceptor)))
           (started (get-internal-real-time)))
      (enchiridion.channel.http::stop-http-acceptor channel :seconds 5)
      (ok (< (elapsed-seconds started) 1.0))
      (testing "and the acceptor is released"
        (ok (null (enchiridion.channel.http:http-channel-acceptor channel))))))
  (testing "the wait ends when the turn does"
    (let* ((service (service-with))
           (channel (channel-over service :acceptor (make-instance 'quiet-acceptor))))
      (enchiridion.channel.http::enter-turn service)
      (bordeaux-threads:make-thread
       (lambda ()
         (sleep 0.1)
         (enchiridion.channel.http::leave-turn service))
       :name "enchiridion http test turn")
      (let* ((started (get-internal-real-time))
             (waited (progn (enchiridion.channel.http::stop-http-acceptor
                             channel :seconds 5)
                            (elapsed-seconds started))))
        (ok (>= waited 0.05) "the drain waited for the turn")
        (ok (< waited 1.5) "and did not spend the whole budget on it"))))
  (testing "a turn that outlasts the budget is reported and the stop returns"
    (let* ((service (service-with))
           (channel (channel-over service :acceptor (make-instance 'quiet-acceptor))))
      (enchiridion.channel.http::enter-turn service)
      (let* ((started (get-internal-real-time))
             (waited (progn (enchiridion.channel.http::stop-http-acceptor
                             channel :seconds 0.2)
                            (elapsed-seconds started))))
        (ok (>= waited 0.15) "the drain was entered")
        (ok (< waited 1.0) "and the budget ended it"))))
  (testing "an acceptor that does not stop in budget keeps its handle"
    (let* ((acceptor (make-instance 'sluggish-acceptor))
           (channel (channel-over (service-with) :acceptor acceptor))
           (started (get-internal-real-time)))
      (enchiridion.channel.http::stop-http-acceptor channel :seconds 0.2)
      (ok (< (elapsed-seconds started) 0.6)
          "HUNCHENTOOT:STOP is bounded by the same deadline")
      (testing "so a later stop can retry it"
        (ok (eq acceptor (enchiridion.channel.http:http-channel-acceptor channel)))
        (enchiridion.channel.http::stop-http-acceptor channel :seconds 5)
        (ok (null (enchiridion.channel.http:http-channel-acceptor channel)))))))
