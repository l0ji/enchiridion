;;;; fluxer-test.cl --- The Fluxer direct-message channel's rules.
;;;;
;;;; No test here opens a socket. Every protocol fact the channel depends on
;;;; is a pure function over text or data, so the tests pin the facts rather
;;;; than a server: the frames the gateway really sent, the allowlist, the
;;;; filters, the sequence arithmetic, the chunk boundaries, and the two
;;;; loops that must not spin.
;;;;
;;;; Three of these tests are the security boundary. The allowlist denies by
;;;; default, only a direct message from a person reaches a turn, and a reply
;;;; is scrubbed before it becomes a REST body. A channel that fails any of
;;;; the three is a channel that answers the wrong person or leaks the key.

(defpackage #:enchiridion-fluxer-test
  (:use #:cl)
  (:import-from #:rove #:deftest #:ok #:ng #:testing #:signals)
  (:export #:run))

(in-package #:enchiridion-fluxer-test)

;;;; Helpers.

(declaim (ftype (function (integer) (vector (unsigned-byte 8))) close-frame))

(defun close-frame (code)
  "Return a close frame as a server sends it: unmasked, header and all."
  (coerce (list 8 2 (ldb (byte 8 8) code) (ldb (byte 8 0) code))
          '(vector (unsigned-byte 8))))

(declaim (ftype (function (integer) (vector (unsigned-byte 8))) masked-close-frame))

(defun masked-close-frame (code)
  "Return a close frame as a client sends it: masked, header and all.

The server never masks, but the reader handles both, and the masked layout puts
a four byte key between the header and the payload."
  (let ((key '(1 2 3 4)))
    (coerce (list 8 130 1 2 3 4
                  (logxor (ldb (byte 8 8) code) (first key))
                  (logxor (ldb (byte 8 0) code) (second key)))
            '(vector (unsigned-byte 8)))))

(defparameter +direct-message+
  '(:id "m-1" :channel_id "d-1" :content "hello" :channel_type 1
    :author (:id "u-1" :username "penny" :bot nil))
  "One MESSAGE_CREATE payload from a person in a direct message.

A plist, because that is the shape ENCHIRIDION.LLM:PARSE-JSON hands back and
the shape every function below takes. Nothing here re-parses JSON to make a
message: the frame tests do that once, at the edge.")

;;;; The configuration the channel reads.

(deftest the-options-come-from-the-section-or-the-whole-configuration ()
  (testing "a section names the allowlist and the token variable"
    (let ((channel (enchiridion.channel.fluxer:make-fluxer-channel
                    :config '(:allowed-users ("u-7")
                              :token-env "FLUXER_TEST_TOKEN"))))
      (ok (equal '("u-7") (enchiridion.channel.fluxer::channel-allowlist channel)))
      (ok (string= "FLUXER_TEST_TOKEN"
                   (enchiridion.channel.fluxer::channel-token-env channel)))))
  (testing "a whole configuration is asked for its :CHANNELS section"
    (let ((channel (enchiridion.channel.fluxer:make-fluxer-channel
                    :config '(:channels (:fluxer (:enabled t)
                                                 (:allowed-users ("u-8")))))))
      (ok (equal '("u-8") (enchiridion.channel.fluxer::channel-allowlist channel)))))
  (testing "a section that names no allowlist admits nobody"
    (let ((channel (enchiridion.channel.fluxer:make-fluxer-channel
                    :config '(:enabled t))))
      (ok (null (enchiridion.channel.fluxer::channel-allowlist channel)))))
  (testing "an allowlist that is not a list of ids is no allowlist"
    (let ((channel (enchiridion.channel.fluxer:make-fluxer-channel
                    :config '(:allowed-users "u-7"))))
      (ok (null (enchiridion.channel.fluxer::channel-allowlist channel)))))
  (testing "the token variable falls back to the configured default"
    (let ((channel (enchiridion.channel.fluxer:make-fluxer-channel
                    :config '(:enabled t))))
      (ok (stringp (enchiridion.channel.fluxer::channel-token-env channel)))
      (ok (plusp (length (enchiridion.channel.fluxer::channel-token-env channel)))))))

;;;; The allowlist.

(deftest the-allowlist-denies-by-default ()
  (testing "an empty allowlist admits nobody"
    (ng (enchiridion.channel.fluxer:allowed-p nil "u-1"))
    (ng (enchiridion.channel.fluxer:allowed-p '() "u-1")))
  (testing "a missing, empty, or non string id is refused"
    (ng (enchiridion.channel.fluxer:allowed-p '("u-1") nil))
    (ng (enchiridion.channel.fluxer:allowed-p '("u-1") ""))
    (ng (enchiridion.channel.fluxer:allowed-p '("u-1") 7)))
  (testing "a named id is admitted"
    (ok (enchiridion.channel.fluxer:allowed-p '("u-1" "u-2") "u-2")))
  (testing "an entry that is not a string cannot match"
    (ng (enchiridion.channel.fluxer:allowed-p '(u-1) "u-1")))
  (testing "an allowlist that is not a list is no allowlist"
    (ng (enchiridion.channel.fluxer:allowed-p "u-1" "u-1"))))

(deftest a-sender-off-the-allowlist-signals-unauthorized ()
  (ok (signals (enchiridion.channel.fluxer::check-sender '("u-1") "u-9")
               'enchiridion.errors:unauthorized))
  (testing "an allowed sender comes back, so the caller has the id in hand"
    (ok (string= "u-1" (enchiridion.channel.fluxer::check-sender '("u-1") "u-1"))))
  (testing "the report names the sender rather than the protocol"
    (let ((condition (handler-case
                         (enchiridion.channel.fluxer::check-sender '("u-1") "u-9")
                       (enchiridion.errors:unauthorized (condition) condition))))
      (ok (search "u-9" (princ-to-string condition))))))

;;;; The frames that go out.

(deftest the-identify-frame-carries-exactly-the-documented-fields ()
  (let* ((frame (enchiridion.channel.fluxer::identify-frame "1234.secret"))
         (data (getf frame :d))
         (properties (getf data :properties)))
    (ok (eql 2 (getf frame :op)))
    (testing "two fields and no more, which is what proves the absent two"
      ;; GETF cannot tell a field that is NIL from one that is not there, so
      ;; the length is the assertion that matters. There is no intents field
      ;; and no shard field, and sending neither is correct.
      (ok (eql 4 (length data)))
      (ng (getf data :intents))
      (ng (getf data :shard)))
    (testing "the token and the properties object"
      (ok (string= "1234.secret" (getf data :token)))
      (ok (eql 6 (length properties)))
      (ok (string= "linux" (getf properties :os)))
      (ok (string= "enchiridion" (getf properties :browser)))
      (ok (string= "enchiridion" (getf properties :device))))))

(deftest the-heartbeat-frame-carries-the-last-processed-sequence ()
  (let ((frame (enchiridion.channel.fluxer::heartbeat-frame 5)))
    (ok (eql 1 (getf frame :op)))
    (testing "two fields and no more"
      (ok (eql 4 (length frame))))
    (ok (eql 5 (getf frame :d))))
  (testing "before the first dispatch the payload is null and not false"
    (let ((text (enchiridion.channel.fluxer::json-text
                 (enchiridion.channel.fluxer::heartbeat-frame nil))))
      (ok (search "\"d\":null" text))
      (ng (search "false" text)))))

(deftest the-resume-frame-carries-token-session-and-sequence ()
  (let* ((frame (enchiridion.channel.fluxer::resume-frame "1234.secret" "sess-1" 9))
         (data (getf frame :d)))
    (ok (eql 6 (getf frame :op)))
    (ok (eql 6 (length data)))
    (ok (string= "1234.secret" (getf data :token)))
    (ok (string= "sess-1" (getf data :session_id)))
    (ok (eql 9 (getf data :seq))))
  (testing "a session with no dispatch yet resumes from null"
    (ok (search "\"seq\":null"
                (enchiridion.channel.fluxer::json-text
                 (enchiridion.channel.fluxer::resume-frame "t" "s" nil))))))

(deftest the-message-body-carries-one-field ()
  (let ((body (enchiridion.channel.fluxer::message-body "hello")))
    (ok (eql 2 (length body)))
    (ok (string= "hello" (getf body :content)))
    (testing "and it is an object on the wire, not an array"
      (ok (string= "{\"content\":\"hello\"}"
                   (enchiridion.channel.fluxer::json-text body))))))

(deftest a-plist-becomes-an-object-and-a-list-becomes-an-array ()
  (let ((text (enchiridion.channel.fluxer::json-text (list :a 1 :b "two"))))
    (ok (char= #\{ (char text 0)))
    (ok (search "\"a\":1" text))
    (ok (search "\"b\":\"two\"" text)))
  (let ((text (enchiridion.channel.fluxer::json-text (list (list :a 1)))))
    (ok (char= #\[ (char text 0)))))

(deftest the-gateway-url-keeps-its-scheme ()
  (ok (string= "wss://gateway.fluxer.app?v=1&encoding=json"
               (enchiridion.channel.fluxer::gateway-url "wss://gateway.fluxer.app")))
  (testing "a self hosted deployment may advertise ws, and it is left alone"
    (ok (string= "ws://127.0.0.1:8080?v=1&encoding=json"
                 (enchiridion.channel.fluxer::gateway-url "ws://127.0.0.1:8080"))))
  (ng (enchiridion.channel.fluxer::gateway-url nil))
  (ng (enchiridion.channel.fluxer::gateway-url "   ")))

;;;; The frames that come in.

(deftest the-captured-frames-parse ()
  (testing "the hello the live gateway sent"
    (let ((frame (enchiridion.channel.fluxer::parse-frame
                  "{\"d\":{\"heartbeat_interval\":41250},\"op\":10}")))
      (ok (eql 10 (enchiridion.channel.fluxer::frame-op frame)))
      (ok (eql 41250 (enchiridion.channel.fluxer::hello-interval frame)))))
  (testing "a dispatch envelope"
    (let ((frame (enchiridion.channel.fluxer::parse-frame
                  "{\"op\":0,\"t\":\"MESSAGE_CREATE\",\"s\":7,\"d\":{\"id\":\"m-1\"}}")))
      (ok (eql 0 (enchiridion.channel.fluxer::frame-op frame)))
      (ok (eql 7 (enchiridion.channel.fluxer::frame-seq frame)))
      (ok (string= "MESSAGE_CREATE" (getf frame :t)))
      (ok (string= "m-1" (getf (enchiridion.channel.fluxer::frame-data frame) :id)))))
  (testing "op 9 arrives with d false"
    (let ((frame (enchiridion.channel.fluxer::parse-frame "{\"op\":9,\"d\":false}")))
      (ok (eql 9 (enchiridion.channel.fluxer::frame-op frame)))
      (ok (null (enchiridion.channel.fluxer::frame-data frame)))))
  (testing "op 11 and op 7"
    (ok (eql 11 (enchiridion.channel.fluxer::frame-op
                 (enchiridion.channel.fluxer::parse-frame "{\"op\":11,\"d\":null}"))))
    (ok (eql 7 (enchiridion.channel.fluxer::frame-op
                (enchiridion.channel.fluxer::parse-frame "{\"op\":7,\"d\":null}")))))
  (testing "a frame that is not a JSON object with an op is not a frame"
    (ng (enchiridion.channel.fluxer::parse-frame "not json"))
    (ng (enchiridion.channel.fluxer::parse-frame "[1,2,3]"))
    (ng (enchiridion.channel.fluxer::parse-frame "{}"))))

(deftest the-close-code-is-read-before-the-library-drops-it ()
  (dolist (code '(4002 4004 4009 4012))
    (testing (format nil "close code ~D" code)
      (ok (eql code (enchiridion.channel.fluxer::frame-close-code
                     (close-frame code))))))
  (testing "a masked close frame is unmasked"
    (ok (eql 4004 (enchiridion.channel.fluxer::frame-close-code
                   (masked-close-frame 4004)))))
  (testing "a close frame with an empty payload carries no code"
    (ng (enchiridion.channel.fluxer::frame-close-code
         (coerce (list 8 0) '(vector (unsigned-byte 8))))))
  (testing "a data frame carries no code"
    (ng (enchiridion.channel.fluxer::frame-close-code
         (coerce (list 129 2 104 105) '(vector (unsigned-byte 8))))))
  (testing "a truncated frame carries no code"
    (ng (enchiridion.channel.fluxer::frame-close-code
         (coerce (list 8 2 15) '(vector (unsigned-byte 8)))))))

(deftest a-refused-session-and-a-network-blip-are-told-apart ()
  (testing "a refused token is not worth another attempt"
    (ok (enchiridion.channel.fluxer::fatal-close-p 4004))
    (ok (enchiridion.channel.fluxer::fatal-close-p 4012)))
  (testing "a heartbeat timeout is"
    (ng (enchiridion.channel.fluxer::fatal-close-p 4009))
    (ng (enchiridion.channel.fluxer::fatal-close-p 1006))
    (ng (enchiridion.channel.fluxer::fatal-close-p nil)))
  (testing "and the note names the code"
    (ok (search "authentication failed"
                (enchiridion.channel.fluxer::close-code-note 4004)))))

;;;; What is a message for this agent.

(deftest only-a-direct-message-from-a-person-is-inkbound ()
  (testing "a direct message from a person"
    (ok (enchiridion.channel.fluxer::inkbound-p +direct-message+ "u-9")))
  (testing "a group channel is not a direct message"
    (ng (enchiridion.channel.fluxer::inkbound-p
         (list* :channel_type 3 +direct-message+) "u-9")))
  (testing "anything with a guild id is out, whatever its channel type"
    (ng (enchiridion.channel.fluxer::inkbound-p
         (list* :guild_id "g-1" +direct-message+) "u-9")))
  (testing "a bot is not a person"
    (ng (enchiridion.channel.fluxer::inkbound-p
         '(:id "m-2" :channel_id "d-1" :content "hi" :channel_type 1
           :author (:id "u-2" :username "helper" :bot t))
         "u-9")))
  (testing "the agent's own message is not a message to the agent"
    (ng (enchiridion.channel.fluxer::inkbound-p +direct-message+ "u-1")))
  (testing "before READY nothing is the agent's own"
    (ok (enchiridion.channel.fluxer::inkbound-p +direct-message+ nil))))

(deftest the-allowlist-reads-the-user-id-and-never-the-username ()
  (testing "the id is what is compared"
    (ok (string= "u-1" (enchiridion.channel.fluxer::author-id +direct-message+)))
    (ok (enchiridion.channel.fluxer:allowed-p
         '("u-1") (enchiridion.channel.fluxer::author-id +direct-message+))))
  (testing "a username that is on the list does not admit its owner"
    (let ((data '(:id "m-3" :channel_id "d-1" :content "hi" :channel_type 1
                  :author (:id "u-9" :username "u-1"))))
      (ng (enchiridion.channel.fluxer:allowed-p
           '("u-1") (enchiridion.channel.fluxer::author-id data)))))
  (testing "an author with no id at all is refused"
    (ng (enchiridion.channel.fluxer:allowed-p
         '("u-1") (enchiridion.channel.fluxer::author-id '(:author (:bot nil)))))))

(deftest only-a-message-create-dispatch-is-a-message ()
  (ok (enchiridion.channel.fluxer::message-create-p
       (enchiridion.channel.fluxer::parse-frame
        "{\"op\":0,\"t\":\"MESSAGE_CREATE\",\"s\":3,\"d\":{}}")))
  (testing "another event is not"
    (ng (enchiridion.channel.fluxer::message-create-p
         (enchiridion.channel.fluxer::parse-frame
          "{\"op\":0,\"t\":\"TYPING_START\",\"s\":4,\"d\":{}}"))))
  (testing "and neither is a dispatch that carries no name"
    (ng (enchiridion.channel.fluxer::message-create-p
         (enchiridion.channel.fluxer::parse-frame "{\"op\":0,\"s\":5,\"d\":{}}"))))
  (testing "READY is its own dispatch"
    (ok (enchiridion.channel.fluxer::ready-p
         (enchiridion.channel.fluxer::parse-frame
          "{\"op\":0,\"t\":\"READY\",\"s\":1,\"d\":{\"session_id\":\"s-1\"}}")))))

(deftest ready-names-the-agent-so-the-echo-guard-can-arm ()
  (testing "the id under :USER"
    (ok (string= "u-9"
                 (enchiridion.channel.fluxer::ready-user-id
                  '(:user (:id "u-9" :username "enchiridion") :session_id "s-1")))))
  (testing "and a flat user id, so a deployment that flattens it still arms the guard"
    (ok (string= "u-9"
                 (enchiridion.channel.fluxer::ready-user-id
                  '(:user_id "u-9" :session_id "s-1")))))
  (testing "a READY that names nobody names nobody"
    (ng (enchiridion.channel.fluxer::ready-user-id '(:session_id "s-1")))
    (ng (enchiridion.channel.fluxer::ready-user-id nil))))

(deftest a-message-create-becomes-the-one-message-shape ()
  (let ((message (enchiridion.channel.fluxer::message-create->msg +direct-message+)))
    (ok (eq :fluxer (enchiridion.channel:msg-channel message)))
    (ok (string= "m-1" (enchiridion.channel:msg-id message)))
    (ok (string= "u-1" (enchiridion.channel:msg-author message)))
    (ok (string= "d-1" (enchiridion.channel:msg-target message)))
    (ok (string= "hello" (enchiridion.channel:msg-text message)))
    (ok (plusp (enchiridion.channel:msg-ts message))))
  (testing "an empty payload still makes a message that can be answered"
    (let ((message (enchiridion.channel.fluxer::message-create->msg '())))
      (ok (plusp (length (enchiridion.channel:msg-id message))))
      (ok (string= "" (enchiridion.channel:msg-text message))))))

;;;; The sequence.

(deftest the-sequence-only-moves-forward ()
  (testing "5, 5, 4, 6"
    (let ((last nil)
          (fresh '()))
      (dolist (incoming '(5 5 4 6))
        (multiple-value-bind (new new-p)
            (enchiridion.channel.fluxer::advance-sequence last incoming)
          (setf last new)
          (push new-p fresh)))
      (ok (eql 6 last))
      (testing "the replay and the older frame are dropped, the newer one is not"
        (ok (equal '(t nil nil t) (nreverse fresh))))))
  (testing "the first dispatch is new work"
    (multiple-value-bind (last fresh)
        (enchiridion.channel.fluxer::advance-sequence nil 1)
      (ok (eql 1 last))
      (ok fresh)))
  (testing "a frame with no sequence is accepted and moves nothing"
    (multiple-value-bind (last fresh)
        (enchiridion.channel.fluxer::advance-sequence 5 nil)
      (ok (eql 5 last))
      (ok fresh))))

;;;; The chunking.

(deftest chunk-text-cuts-on-whitespace ()
  (testing "a body of exactly the limit is one message"
    (let ((text (make-string 2000 :initial-element #\a)))
      (ok (equal (list text)
                 (enchiridion.channel.fluxer::chunk-text text 2000)))))
  (testing "one character over is two messages, and neither is too long"
    (let* ((text (make-string 2001 :initial-element #\a))
           (pieces (enchiridion.channel.fluxer::chunk-text text 2000)))
      (ok (eql 2 (length pieces)))
      (ok (every (lambda (piece) (<= (length piece) 2000)) pieces))
      (testing "and nothing is lost"
        (ok (string= text (apply #'concatenate 'string pieces))))))
  (testing "a multi byte character counts as one character"
    (let* ((text (concatenate 'string (make-string 1999 :initial-element #\a) "λ"))
           (pieces (enchiridion.channel.fluxer::chunk-text text 2000)))
      (ok (eql 1 (length pieces)))
      (ok (string= text (first pieces)))))
  (testing "ten thousand characters come back in pieces that fit"
    (let* ((text (make-string 10000 :initial-element #\x))
           (pieces nil))
      (loop for index from 0 below 10000 by 50
            do (setf (char text index) #\Space))
      (setf pieces (enchiridion.channel.fluxer::chunk-text text 2000))
      (ok (>= (length pieces) 5))
      (ok (every (lambda (piece) (<= (length piece) 2000)) pieces))
      (testing "no piece begins with the whitespace the cut consumed"
        (ok (every (lambda (piece)
                     (not (member (char piece 0) '(#\Space #\Newline #\Tab))))
                   pieces)))))
  (testing "nothing but whitespace gives no pieces"
    (ng (enchiridion.channel.fluxer::chunk-text "" 2000))
    (ng (enchiridion.channel.fluxer::chunk-text "   " 2000))
    (ng (enchiridion.channel.fluxer::chunk-text (format nil "~% ~%") 2000))))

(deftest a-reply-is-scrubbed-before-it-becomes-a-rest-body ()
  (let ((key "correcthorsebatterystaple"))
    (unwind-protect
         (progn
           (enchiridion.llm.secrets:clear-secrets)
           (enchiridion.llm.secrets:register-secret "FLUXER_TEST_KEY" key)
           (let ((pieces (enchiridion.channel.fluxer::outbound-chunks
                          (format nil "the key is ~A." key) 2000)))
             (ok (eql 1 (length pieces)))
             (ng (search key (first pieces)))
             (ok (search enchiridion.llm.secrets:+redaction-marker+
                         (first pieces)))))
      (enchiridion.llm.secrets:clear-secrets)))
  (testing "a reply the scrubber empties is not sent"
    (ok (null (enchiridion.channel.fluxer::outbound-chunks "" 2000)))
    (ok (null (enchiridion.channel.fluxer::outbound-chunks "   " 2000))))
  (testing "a long reply is scrubbed and then cut"
    (let ((pieces (enchiridion.channel.fluxer::outbound-chunks
                   (make-string 5000 :initial-element #\b) 2000)))
      (ok (eql 3 (length pieces)))
      (ok (every (lambda (piece) (<= (length piece) 2000)) pieces)))))

;;;; The waits.

(deftest the-backoff-grows-and-stops ()
  (ok (= 1 (enchiridion.channel.fluxer::next-backoff 1)))
  (ok (= 2 (enchiridion.channel.fluxer::next-backoff 2)))
  (ok (= 4 (enchiridion.channel.fluxer::next-backoff 3)))
  (testing "it never waits longer than the cap"
    (ok (every (lambda (attempt)
                 (<= (enchiridion.channel.fluxer::next-backoff attempt) 60))
               '(1 2 3 4 5 6 7 8 9 10 50))))
  (testing "and it never goes backwards"
    (ok (loop for attempt from 1 below 12
              always (<= (enchiridion.channel.fluxer::next-backoff attempt)
                         (enchiridion.channel.fluxer::next-backoff (1+ attempt)))))))

(deftest the-first-heartbeat-waits-a-random-part-of-one-interval ()
  (testing "every later heartbeat waits one whole interval"
    (ok (= 5 (enchiridion.channel.fluxer::heartbeat-delay 0 5000 5000)))
    (ok (= 165/4 (enchiridion.channel.fluxer::heartbeat-delay 3 41250))))
  (testing "and the first one is somewhere inside one interval"
    (let ((delay (enchiridion.channel.fluxer::heartbeat-delay 0 41250)))
      (ok (realp delay))
      (ok (<= 0 delay))
      (ok (< delay 41.25)))))

(deftest retry-after-is-read-from-the-body-and-not-the-headers ()
  (ok (= 1/2 (enchiridion.channel.fluxer::retry-after-seconds
              "{\"retry_after\":0.5}")))
  (ok (= 2 (enchiridion.channel.fluxer::retry-after-seconds
            "{\"retry_after\":2}")))
  (testing "an answer without the field lets the caller use its own backoff"
    (ng (enchiridion.channel.fluxer::retry-after-seconds
         "{\"message\":\"slow down\"}"))
    (ng (enchiridion.channel.fluxer::retry-after-seconds "not json"))))

(deftest the-resume-window-is-the-sixty-seconds-the-gateway-keeps ()
  (ok (enchiridion.channel.fluxer::resume-window-open-p 100 100))
  (ok (enchiridion.channel.fluxer::resume-window-open-p 100 160))
  (ng (enchiridion.channel.fluxer::resume-window-open-p 100 161))
  (ng (enchiridion.channel.fluxer::resume-window-open-p nil 100)))

;;;; The token.

(deftest the-token-comes-from-the-secrets-and-then-the-environment ()
  (let ((name "ENCHIRIDION_FLUXER_TEST_TOKEN")
        (value "1234567890.abcdefghijklmnop"))
    (unwind-protect
         (progn
           (enchiridion.llm.secrets:clear-secrets)
           (enchiridion.compat:unset-environment-variable name)
           (testing "an unset name is no token"
             (ng (enchiridion.channel.fluxer::resolve-token :name name)))
           (testing "an empty value is no token"
             (enchiridion.compat:set-environment-variable name "")
             (ng (enchiridion.channel.fluxer::resolve-token :name name)))
           (testing "a whitespace only value is no token"
             (enchiridion.compat:set-environment-variable name "   ")
             (ng (enchiridion.channel.fluxer::resolve-token :name name)))
           (testing "the environment is a fallback, and it registers itself"
             (enchiridion.compat:set-environment-variable name value)
             (ok (string= value
                          (enchiridion.channel.fluxer::resolve-token :name name)))
             (ok (enchiridion.llm.secrets:secret-present-p name)))
           (testing "a loaded secret wins over the environment"
             (enchiridion.llm.secrets:register-secret name "registered.token.value")
             (ok (string= "registered.token.value"
                          (enchiridion.channel.fluxer::resolve-token :name name))))
           (testing "a registered whitespace value is still no token"
             (enchiridion.compat:unset-environment-variable name)
             (enchiridion.llm.secrets:clear-secrets)
             (enchiridion.llm.secrets:register-secret name "   ")
             (ng (enchiridion.channel.fluxer::resolve-token :name name))))
      (enchiridion.compat:unset-environment-variable name)
      (enchiridion.llm.secrets:clear-secrets))))
