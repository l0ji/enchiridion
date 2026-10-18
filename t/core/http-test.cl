;;;; http-test.cl --- The webhook: its routes, its token, and its limits.
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

(defun service-with (&key turn health usage token (bind "127.0.0.1") (port 8787))
  "Return a service whose routes are the given functions."
  (enchiridion.channel.http:make-http-service
   :turn turn :health health :usage usage :token token :bind bind :port port))

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

;;;; Binding.

(deftest only-the-loopback-names-count-as-loopback ()
  (dolist (bind '("" nil "127.0.0.1" "127.0.0.2" "127.1.2.3" "localhost"
                  "LOCALHOST" "::1" "::ffff:127.0.0.1" " 127.0.0.1 "))
    (testing (format nil "~S is loopback" bind)
      (ok (enchiridion.channel.http:loopback-bind-p bind))))
  (dolist (bind '("0.0.0.0" "::" "*" "example.test" "10.0.0.1" "128.0.0.1"
                  "127.0.0.1.example.test" "127.0.0" "1270.0.1"))
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
