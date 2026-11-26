;;;; fluxer-test.lsp --- The Fluxer direct-message channel's rules.
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
  (let ((body (enchiridion.channel.fluxer::message-body "hello" nil)))
    (ok (eql 2 (length body)))
    (ok (string= "hello" (getf body :content)))
    (testing "and it is an object on the wire, not an array"
      (ok (string= "{\"content\":\"hello\"}"
                   (enchiridion.channel.fluxer::json-text body))))))

(deftest only-a-default-or-reply-message-can-be-a-reply-anchor ()
  (dolist (type '(0 19))
    (ok (equal "m-1"
               (enchiridion.channel.fluxer::reply-anchor (list :type type :id "m-1")))))
  (ng (enchiridion.channel.fluxer::reply-anchor '(:type 3 :id "m-1")))
  (ng (enchiridion.channel.fluxer::reply-anchor '(:type 0))))

(deftest a-plist-becomes-an-object-and-a-list-becomes-an-array ()
  (let ((text (enchiridion.channel.fluxer::json-text (list :a 1 :b "two"))))
    (ok (char= #\{ (char text 0)))
    (ok (search "\"a\":1" text))
    (ok (search "\"b\":\"two\"" text)))
  (let ((text (enchiridion.channel.fluxer::json-text (list (list :a 1)))))
    (ok (char= #\[ (char text 0)))))

;;;; The agent's custom status.

(defun status-socket ()
  "Return an offline socket, whose send queue is where frames are inspected."
  (make-instance 'enchiridion.channel.fluxer::fluxer-socket
                 :url "ws://offline.invalid/status"))

(defun status-channel (&key (custom-status t) (ttl 300) (cooldown 60)
                            (allowed-users '("u-1")) status-user socket)
  "Return a channel with a status configuration and a socket when one is given."
  (let ((channel (enchiridion.channel.fluxer:make-fluxer-channel
                  :config (list :allowed-users allowed-users
                                :custom-status custom-status
                                :custom-status-user status-user
                                :custom-status-ttl-seconds ttl
                                :custom-status-cooldown-seconds cooldown))))
    (when socket
      (setf (enchiridion.channel.fluxer::fluxer-channel-socket channel) socket))
    channel))

(defun queued-frames (socket)
  "Return the text of every frame handed to SOCKET."
  (loop for entry across (websocket-driver.ws.base::queue socket)
        collect (car entry)))

(deftest the-presence-frame-sets-and-clears-the-documented-fields ()
  (let* ((frame (enchiridion.channel.fluxer::presence-frame "Working on retries"))
         (data (getf frame :d)))
    (ok (eql 3 (getf frame :op)))
    (ok (eql 4 (length frame)))
    (testing "the base presence is named because the gateway requires it"
      (ok (string= "online" (getf data :status))))
    (testing "the status is the one field the custom status carries"
      (ok (equal '(:text "Working on retries") (getf data :custom_status)))
      (ok (string= "{\"op\":3,\"d\":{\"status\":\"online\",\"custom_status\":{\"text\":\"Working on retries\"}}}"
                   (enchiridion.channel.fluxer::json-text frame)))))
  (testing "clearing sends a null custom status, never an empty text"
    (let* ((frame (enchiridion.channel.fluxer::presence-frame nil))
           (data (getf frame :d))
           (text (enchiridion.channel.fluxer::json-text frame)))
      (ok (eql enchiridion.channel.fluxer::+json-null+
               (getf data :custom_status)))
      (ok (search "\"custom_status\":null" text))
      (ng (search "false" text)))))

(deftest a-custom-status-is-one-clean-line-of-bounded-length ()
  (testing "a string is trimmed and returned"
    (multiple-value-bind (text reason)
        (enchiridion.channel.fluxer::validate-custom-status "  Working  ")
      (ok (string= "Working" text))
      (ng reason)))
  (testing "a non string, a blank, and a whitespace only value are refused"
    (dolist (proposal '(7 nil "   " ""))
      (multiple-value-bind (text reason)
          (enchiridion.channel.fluxer::validate-custom-status proposal)
        (ng text)
        (ok (stringp reason)))))
  (testing "the length limit is 128 characters and is counted after trimming"
    (let ((text (make-string 128 :initial-element #\a)))
      (multiple-value-bind (clean reason)
          (enchiridion.channel.fluxer::validate-custom-status text)
        (ok (string= text clean))
        (ng reason)))
    (multiple-value-bind (clean reason)
        (enchiridion.channel.fluxer::validate-custom-status
         (make-string 129 :initial-element #\a))
      (ng clean)
      (ok (search "128" reason))))
  (testing "a line break, a tab, and a control character are refused"
    (dolist (proposal (list (format nil "one~%two")
                            (format nil "one~Ctwo" #\Tab)
                            (format nil "one~Ctwo" (code-char 7))))
      (multiple-value-bind (text reason)
          (enchiridion.channel.fluxer::validate-custom-status proposal)
        (ng text)
        (ok (search "one line" reason)))))
  (testing "text the scrubber would redact is refused rather than published"
    (unwind-protect
         (progn
           (enchiridion.llm.secrets:register-secret
            "ENCHIRIDION_STATUS_TEST_SECRET" "abcdefghijklmnop")
           (multiple-value-bind (text reason)
               (enchiridion.channel.fluxer::validate-custom-status
                "the key is abcdefghijklmnop")
             (ng text)
             (ok (search "redacts" reason))))
      (enchiridion.llm.secrets:clear-secrets))))

(deftest the-custom-status-is-off-until-the-operator-opts-in ()
  (let* ((socket (status-socket))
         (channel (status-channel :custom-status nil :socket socket)))
    (ok (equal '(:outcome :disabled :reason "the Fluxer channel is not opted in to a custom status." :sent nil)
               (enchiridion.channel.fluxer:propose-custom-status
                channel "Working" :now 1000)))
    (ok (null (getf (enchiridion.channel.fluxer:custom-status channel :now 1000)
                    :text)))
    (ok (null (queued-frames socket))))
  (testing "the default is off, not on"
    (let ((channel (enchiridion.channel.fluxer:make-fluxer-channel
                    :config '(:allowed-users ("u-1")))))
      (ng (enchiridion.channel.fluxer::channel-custom-status-p channel)))))

(deftest only-the-operator-may-steer-the-status ()
  (testing "one allowed user is the operator when no id is named"
    (let* ((socket (status-socket))
           (channel (status-channel :socket socket)))
      (ok (string= "u-1" (enchiridion.channel.fluxer::custom-status-operator channel)))
      (ok (eq :applied
              (getf (enchiridion.channel.fluxer:propose-custom-status
                     channel "Working" :author "u-1" :now 1000)
                    :outcome)))
      (ok (eql 1 (length (queued-frames socket))))))
  (testing "several allowed users and no explicit id is ambiguous"
    (let* ((socket (status-socket))
           (channel (status-channel :allowed-users '("u-1" "u-2")
                                    :socket socket)))
      (ok (null (enchiridion.channel.fluxer::custom-status-operator channel)))
      (dolist (author '("u-1" "u-2"))
        (let ((decision (enchiridion.channel.fluxer:propose-custom-status
                         channel "Working" :author author :now 1000)))
          (ok (eq :refused (getf decision :outcome)))
          (ok (search "may not set" (getf decision :reason)))))
      (ok (null (queued-frames socket)))))
  (testing "an explicit id resolves the ambiguity"
    (let* ((socket (status-socket))
           (channel (status-channel :allowed-users '("u-1" "u-2")
                                    :status-user "u-2" :socket socket)))
      (ok (string= "u-2" (enchiridion.channel.fluxer::custom-status-operator channel)))
      (ok (eq :refused
              (getf (enchiridion.channel.fluxer:propose-custom-status
                     channel "Working" :author "u-1" :now 1000)
                    :outcome)))
      (ok (eq :applied
              (getf (enchiridion.channel.fluxer:propose-custom-status
                     channel "Working" :author "u-2" :now 1000)
                    :outcome)))
      (ok (eql 1 (length (queued-frames socket))))))
  (testing "an explicit id must itself be on the allowlist"
    (let* ((socket (status-socket))
           (channel (status-channel :allowed-users '("u-1")
                                    :status-user "u-9" :socket socket)))
      (ok (null (enchiridion.channel.fluxer::custom-status-operator channel)))
      (ok (eq :refused
              (getf (enchiridion.channel.fluxer:propose-custom-status
                     channel "Working" :author "u-9" :now 1000)
                    :outcome)))
      (ok (null (queued-frames socket)))))
  (testing "the same id listed twice is still one user"
    (let ((channel (status-channel :allowed-users '("u-1" "u-1"))))
      (ok (string= "u-1"
                   (enchiridion.channel.fluxer::custom-status-operator channel)))))
  (testing "an in-process caller omits the author and is the operator"
    (let ((channel (status-channel)))
      (ok (eq :applied
              (getf (enchiridion.channel.fluxer:propose-custom-status
                     channel "Working" :now 1000)
                    :outcome))))))

(deftest a-live-status-is-not-resent-and-a-change-waits-for-the-cooldown ()
  (let* ((socket (status-socket))
         (channel (status-channel :socket socket)))
    (testing "the first proposal is applied and sent"
      (ok (eq :applied
              (getf (enchiridion.channel.fluxer:propose-custom-status
                     channel "Working on retries" :now 1000)
                    :outcome)))
      (ok (eql 1 (length (queued-frames socket)))))
    (testing "the same live text is deduplicated, not sent again"
      (ok (eq :unchanged
              (getf (enchiridion.channel.fluxer:propose-custom-status
                     channel "Working on retries" :now 1010)
                    :outcome)))
      (ok (eql 1 (length (queued-frames socket)))))
    (testing "a different text inside the cooldown is refused"
      (let ((decision (enchiridion.channel.fluxer:propose-custom-status
                       channel "Reviewing code" :now 1010)))
        (ok (eq :refused (getf decision :outcome)))
        (ok (search "50 seconds left" (getf decision :reason)))
        (ok (eql 1 (length (queued-frames socket))))))
    (testing "the cooldown ends exactly at its configured number of seconds"
      (ok (eq :refused
              (getf (enchiridion.channel.fluxer:propose-custom-status
                     channel "Reviewing code" :now 1059)
                    :outcome)))
      (ok (eq :applied
              (getf (enchiridion.channel.fluxer:propose-custom-status
                     channel "Reviewing code" :now 1060)
                    :outcome)))
      (ok (eql 2 (length (queued-frames socket)))))
    (testing "clearing is a change too, and an empty clear is a no-op"
      (ok (eq :cleared
              (getf (enchiridion.channel.fluxer:propose-custom-status
                     channel :clear :now 1120)
                    :outcome)))
      (ok (eql 3 (length (queued-frames socket))))
      (ok (eq :unchanged
              (getf (enchiridion.channel.fluxer:propose-custom-status
                     channel :clear :now 1130)
                    :outcome)))
      (ok (eql 3 (length (queued-frames socket)))))))

(deftest a-custom-status-expires-and-is-cleared-once ()
  (let* ((socket (status-socket))
         (channel (status-channel :socket socket)))
    (enchiridion.channel.fluxer:propose-custom-status
     channel "Working on retries" :now 1000)
    (ok (eql 1300 (getf (enchiridion.channel.fluxer:custom-status channel :now 1000)
                        :expires)))
    (testing "one second before the deadline nothing happens"
      (ok (eq :unchanged
              (getf (enchiridion.channel.fluxer::expire-custom-status
                     channel :now 1299)
                    :outcome)))
      (ok (eql 1 (length (queued-frames socket)))))
    (testing "at the deadline the clear goes out once and the text is forgotten"
      (ok (eq :expired
              (getf (enchiridion.channel.fluxer::expire-custom-status
                     channel :now 1300)
                    :outcome)))
      (ok (eql 2 (length (queued-frames socket))))
      (ok (string= "{\"op\":3,\"d\":{\"status\":\"online\",\"custom_status\":null}}"
                   (second (queued-frames socket))))
      (ok (null (getf (enchiridion.channel.fluxer:custom-status channel :now 1301)
                      :text))))
    (testing "a second expiry pass sends nothing"
      (ok (eq :unchanged
              (getf (enchiridion.channel.fluxer::expire-custom-status
                     channel :now 1301)
                    :outcome)))
      (ok (eql 2 (length (queued-frames socket)))))))

(deftest a-reconnect-reapplies-a-live-status-without-restarting-the-cooldown ()
  (let* ((socket (status-socket))
         (channel (status-channel :socket socket)))
    (enchiridion.channel.fluxer:propose-custom-status
     channel "Working on retries" :now 1000)
    (testing "a live status goes out again on the new session"
      (ok (eq :reapplied
              (getf (enchiridion.channel.fluxer::reapply-custom-status
                     channel :now 1001)
                    :outcome)))
      (ok (eql 2 (length (queued-frames socket)))))
    (testing "a reconnect is not a proposal, so the cooldown still counts from 1000"
      (let ((decision (enchiridion.channel.fluxer:propose-custom-status
                       channel "Reviewing code" :now 1030)))
        (ok (eq :refused (getf decision :outcome)))
        (ok (search "30 seconds left" (getf decision :reason)))))
    (testing "a status that ended while disconnected is forgotten, not republished"
      (let* ((stale (status-channel :socket (status-socket))))
        (enchiridion.channel.fluxer:propose-custom-status
         stale "Old news" :now 1000)
        (ok (eq :expired
                (getf (enchiridion.channel.fluxer::reapply-custom-status
                       stale :now 1300)
                      :outcome)))
        (ok (null (getf (enchiridion.channel.fluxer:custom-status stale :now 1300)
                        :text)))
        (ok (eql 1 (length (queued-frames
                            (enchiridion.channel.fluxer::fluxer-channel-socket
                             stale)))))))))

(deftest a-disabled-channel-drops-a-stored-status-on-reconnect ()
  (let* ((socket (status-socket))
         (channel (status-channel :socket socket)))
    (enchiridion.channel.fluxer:propose-custom-status channel "Working" :now 1000)
    (ok (eql 1 (length (queued-frames socket))))
    (setf (enchiridion.channel.fluxer::fluxer-channel-config channel)
          (list :allowed-users '("u-1") :custom-status nil))
    (testing "a direct reapply sends nothing and forgets the text"
      (ok (eq :disabled
              (getf (enchiridion.channel.fluxer::reapply-custom-status
                     channel :now 1001)
                    :outcome)))
      (ok (eql 1 (length (queued-frames socket))))
      (ok (null (getf (enchiridion.channel.fluxer:custom-status channel :now 1001)
                      :text)))))
  (testing "READY on the real path sends nothing either"
    (let* ((socket (status-socket))
           (channel (status-channel)))
      (enchiridion.channel.fluxer:propose-custom-status
       channel "Working" :now (get-universal-time))
      (setf (enchiridion.channel.fluxer::fluxer-channel-config channel)
            (list :allowed-users '("u-1") :custom-status nil)
            (enchiridion.channel.fluxer::fluxer-channel-socket channel) socket)
      (enchiridion.channel.fluxer::handle-text
       channel socket
       (enchiridion.channel.fluxer::json-text
        (list :op 0 :s 1 :t "READY"
              :d (list :user (list :id "bot-1") :session_id "s-1"))))
      (ok (null (queued-frames socket)))
      (ok (null (getf (enchiridion.channel.fluxer:custom-status channel) :text))))))

(deftest a-non-operator-turn-cannot-publish-a-status ()
  (let* ((status (status-socket))
         (channel (status-channel :allowed-users '("u-1" "u-2")
                                  :status-user "u-1" :socket status))
         (sent '())
         (enchiridion.llm::*http-request-function*
           (lambda (url &rest options)
             (declare (ignore options))
             (push url sent)
             "{\"id\":\"r-1\"}")))
    (setf (enchiridion.channel.fluxer::fluxer-channel-token channel) "fake"
          (enchiridion.channel.fluxer::fluxer-channel-turn channel)
          (lambda (message)
            (declare (ignore message))
            (list :ok-p t :reply "answer" :status "Working")))
    (enchiridion.channel.fluxer::handle-inkbound
     channel
     (list :id "m-2" :channel_id "d-1" :content "hi" :channel_type 1
           :author (list :id "u-2" :bot nil)))
    (ok (null (queued-frames status)))
    (ok (equal (list "https://api.fluxer.app/v1/channels/d-1/messages") sent))))

(deftest a-ready-reapplies-the-status-and-the-worker-publishes-a-proposal ()
  (testing "READY on a new session reapplies the live status"
    (let* ((socket (status-socket))
           (channel (status-channel)))
      (enchiridion.channel.fluxer:propose-custom-status
       channel "Reading the diff" :now (get-universal-time))
      (setf (enchiridion.channel.fluxer::fluxer-channel-socket channel) socket)
      (enchiridion.channel.fluxer::handle-text
       channel socket
       (enchiridion.channel.fluxer::json-text
        (list :op 0 :s 1 :t "READY"
              :d (list :user (list :id "bot-1") :session_id "s-1"))))
      (ok (equal (list "{\"op\":3,\"d\":{\"status\":\"online\",\"custom_status\":{\"text\":\"Reading the diff\"}}}")
                 (queued-frames socket)))))
  (testing "a successful turn publishes the proposal beside its reply"
    (let* ((status (status-socket))
           (channel (status-channel :socket status))
           (sent '())
           (enchiridion.llm::*http-request-function*
             (lambda (url &rest options)
               (declare (ignore options))
               (push url sent)
               "{\"id\":\"r-1\"}")))
      (setf (enchiridion.channel.fluxer::fluxer-channel-token channel) "fake")
      (setf (enchiridion.channel.fluxer::fluxer-channel-turn channel)
            (lambda (message)
              (declare (ignore message))
              (list :ok-p t :reply "answer" :status "Working on retries")))
      (enchiridion.channel.fluxer::handle-inkbound channel +direct-message+)
      (ok (eql 1 (length (queued-frames status))))
      (ok (search "Working on retries" (first (queued-frames status))))
      (ok (equal (list "https://api.fluxer.app/v1/channels/d-1/messages") sent))))
  (testing "a failed turn's proposal is not published"
    (let* ((status (status-socket))
           (channel (status-channel :socket status)))
      (setf (enchiridion.channel.fluxer::fluxer-channel-turn channel)
            (lambda (message)
              (declare (ignore message))
              (list :ok-p nil :error "no" :status "Working on retries")))
      (enchiridion.channel.fluxer::handle-inkbound channel +direct-message+)
      (ok (null (queued-frames status)))))
  (testing "a refused proposal costs the reply nothing"
    (let* ((status (status-socket))
           (channel (status-channel :socket status))
           (sent '())
           (enchiridion.llm::*http-request-function*
             (lambda (url &rest options)
               (declare (ignore options))
               (push url sent)
               "{\"id\":\"r-1\"}")))
      (setf (enchiridion.channel.fluxer::fluxer-channel-token channel) "fake")
      (enchiridion.channel.fluxer:propose-custom-status
       channel "First" :now (get-universal-time))
      (setf (enchiridion.channel.fluxer::fluxer-channel-turn channel)
            (lambda (message)
              (declare (ignore message))
              (list :ok-p t :reply "answer" :status "Second")))
      (enchiridion.channel.fluxer::handle-inkbound channel +direct-message+)
      (ok (eql 1 (length (queued-frames status))))
      (ok (equal (list "https://api.fluxer.app/v1/channels/d-1/messages") sent)))))

(deftest the-status-ttl-and-cooldown-options-are-bounded ()
  (let ((channel (enchiridion.channel.fluxer:make-fluxer-channel
                  :config '(:custom-status t))))
    (ok (= 300 (enchiridion.channel.fluxer::channel-custom-status-ttl channel)))
    (ok (= 60 (enchiridion.channel.fluxer::channel-custom-status-cooldown channel))))
  (testing "an out of range or non integer value falls back to the shipped default"
    (let ((channel (enchiridion.channel.fluxer:make-fluxer-channel
                    :config '(:custom-status t
                              :custom-status-ttl-seconds 0
                              :custom-status-cooldown-seconds "60"))))
      (ok (= 300 (enchiridion.channel.fluxer::channel-custom-status-ttl channel)))
      (ok (= 60 (enchiridion.channel.fluxer::channel-custom-status-cooldown channel)))))
  (testing "the bounds are inclusive"
    (let ((channel (enchiridion.channel.fluxer:make-fluxer-channel
                    :config '(:custom-status t
                              :custom-status-ttl-seconds 1
                              :custom-status-cooldown-seconds 0))))
      (ok (= 1 (enchiridion.channel.fluxer::channel-custom-status-ttl channel)))
      (ok (= 0 (enchiridion.channel.fluxer::channel-custom-status-cooldown channel))))
    (let ((channel (enchiridion.channel.fluxer:make-fluxer-channel
                    :config (list :custom-status t
                                  :custom-status-ttl-seconds
                                  enchiridion.channel.fluxer::+custom-status-max-ttl-seconds+
                                  :custom-status-cooldown-seconds
                                  enchiridion.channel.fluxer::+custom-status-max-cooldown-seconds+))))
      (ok (= enchiridion.channel.fluxer::+custom-status-max-ttl-seconds+
             (enchiridion.channel.fluxer::channel-custom-status-ttl channel)))
      (ok (= enchiridion.channel.fluxer::+custom-status-max-cooldown-seconds+
             (enchiridion.channel.fluxer::channel-custom-status-cooldown channel))))))

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

(deftest websocket-parse-accepts-a-whole-frame-without-offsets ()
  (let ((socket (make-instance 'enchiridion.channel.fluxer::fluxer-socket
                               :url "ws://offline.invalid/"))
        (message nil)
        (frame (make-array 4 :element-type '(unsigned-byte 8)
                             :initial-contents '(129 2 104 105))))
    (websocket-driver:on :message socket (lambda (text) (setf message text)))
    (websocket-driver.ws.base:parse socket frame)
    (ok (equal message "hi"))))

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

(deftest markdown-splits-at-structural-boundaries ()
  (flet ((chunks (text limit)
           (enchiridion.channel.fluxer::chunk-text text limit)))
    (testing "A short Markdown reply is unchanged"
      (let ((text (format nil "## Details~%~%  - nested~%~%```lisp~%  (+ 1 2)~%```")))
        (ok (equal (chunks text 2000) (list text)))))
    (testing "A paragraph break takes precedence over a line or word break"
      (ok (equal (chunks (format nil "first paragraph~%~%second line~%third line") 30)
                 (list (format nil "first paragraph~%~%")
                       (format nil "second line~%third line")))))
    (testing "A new message retains nesting at the start of a list line"
      (ok (equal (chunks (format nil "- list item~%  - nested item") 16)
                 (list (format nil "- list item~%") "  - nested item"))))
    (testing "Inline formatting and links that fit move whole to the next message"
      (dolist (span '("`an inline code span`" "**two bold words**"
                      "*two italic words*" "__two underlined words__"
                      "~~two removed words~~" "||two spoiler words||"
                      "[link label](https://e.test/a(b))" "<https://e.test/example>"))
        (ok (equal (chunks (concatenate 'string "Before the " span) (length span))
                   (list "Before the" span)))))
    (testing "An oversized spoiler stays hidden in every continuation"
      (ok (equal (chunks "||keep these words hidden||" 15)
                 '("||keep these||" "||words||" "||hidden||"))))
    (testing "A supplementary character costs two UTF-16 code units"
      (ok (equal (chunks "ab😀" 3) '("ab" "😀"))))))

(deftest fenced-code-stays-fenced-across-messages ()
  (flet ((chunks (text limit)
           (enchiridion.channel.fluxer::chunk-text text limit)))
    (testing "A fence that fits moves whole to the next message"
      (let ((block (format nil "```sh~%  echo hi~%```")))
        (ok (equal (chunks (format nil "Run this:~%~%~A" block) (length block))
                   (list (format nil "Run this:~%~%") block)))))
    (testing "Each continuation keeps the language, indentation, and blank lines"
      (let* ((text (format nil "```lisp~%  first line~%~%  second line~%  third line~%```"))
             (pieces (chunks text 27)))
        (ok (equal pieces (list (format nil "```lisp~%  first line~%~%```")
                                (format nil "```lisp~%  second line~%```")
                                (format nil "```lisp~%  third line~%```"))))
        (ok (every (lambda (piece) (<= (length piece) 27)) pieces))))
    (testing "A code line longer than the budget can be split without losing text"
      (let* ((text (format nil "````text~%  one very long line with ``` inside~%````"))
             (pieces (chunks text 25)))
        (ok (every (lambda (piece) (<= (length piece) 25)) pieces))
        (ok (every (lambda (piece) (and (eql 0 (search (format nil "````text~%") piece))
                                       (string= (format nil "~%````") piece
                                                :start2 (- (length piece) 5))))
                   pieces))
        (ok (string= "  one very long line with ``` inside"
                     (apply #'concatenate 'string
                            (mapcar (lambda (piece) (subseq piece 9 (- (length piece) 5)))
                                    pieces))))))))

(deftest oversized-markdown-preserves-literal-content ()
  (flet ((chunks (text limit)
           (enchiridion.channel.fluxer::chunk-text text limit)))
    (testing "Runs of Markdown punctuation do not produce synthetic formatting"
      (dolist (marker '(#\* #\_ #\| #\~))
        (let* ((text (make-string 2500 :initial-element marker))
               (pieces (chunks text 2000)))
          (ok (equal '(2000 500) (mapcar #'length pieces)))
          (ok (string= text (apply #'concatenate 'string pieces))))))
    (testing "Oversized inline code keeps significant spaces"
      (ok (equal '("` foo`" "` `") (chunks "` foo `" 6)))
      (ok (equal '("`  `" "` `") (chunks "`   `" 4))))
    (testing "Text following a closing fence is not code"
      (let* ((code (format nil "```lisp~%abcdefghij~%klmnopqrst~%```"))
             (pieces (chunks (concatenate 'string code " after the code") 24)))
        (ok (equal pieces (list (format nil "```lisp~%abcdefghij~%```")
                                (format nil "```lisp~%klmnopqrst~%```")
                                "after the code")))))
    (testing "Fences preceded by prose stay fenced across messages"
      (let ((text (format nil "Example: ```lisp~%abcdefghij~%klmnopqrst~%```")))
        (ok (equal (chunks text 24) (list "Example:"
                                         (format nil "```lisp~%abcdefghij~%```")
                                         (format nil "```lisp~%klmnopqrst~%```"))))))
    (testing "Multiline spoilers close and reopen at message boundaries"
      (let* ((text (format nil "||~%first hidden line~%second hidden line~%||"))
             (pieces (chunks text 26)))
        (ok (= 2 (length pieces)))
        (ok (every (lambda (piece)
                     (and (<= (length piece) 26)
                          (string= (format nil "||~%") piece :end2 3)
                          (string= (format nil "~%||") piece :start2 (- (length piece) 3))))
                   pieces))
        (ok (search "first hidden line" (first pieces)))
        (ok (search "second hidden line" (second pieces)))))))

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

(deftest authorized-dispatch-reaches-worker-and-reply ()
  (let* ((seen nil)
         (sent nil)
         (done (bordeaux-threads:make-semaphore))
         (channel (enchiridion.channel.fluxer:make-fluxer-channel
                   :config '(:allowed-users ("u-1"))
                   :turn (lambda (message)
                           (push (enchiridion.channel:msg-text message) seen)
                           (list :ok-p t :reply "answer")))))
    (unwind-protect
         (progn
           (setf (enchiridion.channel.fluxer::fluxer-channel-token channel) "fake-token"
                 (enchiridion.channel.fluxer::fluxer-channel-worker channel)
                 (bordeaux-threads:make-thread
                  (lambda ()
                    (let ((enchiridion.llm::*http-request-function*
                            (lambda (url &rest options)
                              (push (list url (getf options :method)
                                          (getf options :content)) sent)
                              (bordeaux-threads:signal-semaphore done)
                              "{\"id\":\"reply-1\"}")))
                      (enchiridion.channel.fluxer::run-worker channel)))))
           (flet ((dispatch (sequence data)
                    (enchiridion.channel.fluxer::handle-text
                     channel (make-instance 'enchiridion.channel.fluxer::fluxer-socket
                                            :url "ws://offline.invalid/")
                     (enchiridion.channel.fluxer::json-text
                      (list :op 0 :s sequence :t "MESSAGE_CREATE" :d data)))))
             (dispatch 1 (list :channel_type 1 :author '(:id "denied") :content "no"))
             (dispatch 2 +direct-message+)
             (ok (bordeaux-threads:wait-on-semaphore done :timeout 2))
             (dispatch 2 +direct-message+)
             (dispatch 1 +direct-message+)
             (ok (equal '("hello") seen))
             (ok (= 1 (length sent)))
             (destructuring-bind (url method body) (first sent)
               (let ((data (enchiridion.llm:parse-json body)))
                 (ok (equal "https://api.fluxer.app/v1/channels/d-1/messages" url))
                 (ok (eq :post method))
                 (ok (equal "answer" (getf data :content)))
                 (ok (equal '(:message_id "m-1") (getf data :message_reference)))
                 (ok (equal '(:replied_user nil) (getf data :allowed_mentions)))
                 (ok (search "\"replied_user\":false" body))))
             (ok (= 2 (enchiridion.channel.fluxer::fluxer-channel-sequence channel)))
             (ok (null (enchiridion.channel.fluxer::fluxer-channel-pending channel)))))
      (enchiridion.channel.fluxer::stop-worker channel))))

(deftest retry-wait-honors-stop-and-deadline ()
  (let* ((channel (enchiridion.channel.fluxer:make-fluxer-channel))
         (enchiridion.channel.fluxer::*send-channel* channel)
         (enchiridion.channel.fluxer::*send-deadline*
           (enchiridion.channel.fluxer::real-seconds)))
    (ok (signals (enchiridion.channel.fluxer::wait-to-retry 100000)
                 'enchiridion.errors:transport-error))
    (let ((enchiridion.channel.fluxer::*send-deadline* nil))
      (setf (enchiridion.channel.fluxer::fluxer-channel-stopping-p channel) t)
      (ok (signals (enchiridion.channel.fluxer::wait-to-retry 100000)
                   'enchiridion.errors:transport-error)))))

(deftest fake-rest-retries-and-bounds-discovery-and-sends ()
  (let* ((calls 0)
         (channel (enchiridion.channel.fluxer:make-fluxer-channel))
         (enchiridion.llm::*http-request-function*
           (lambda (url &rest options)
             (declare (ignore url options))
             (incf calls)
             (if (= calls 1)
                 (error 'dexador.error:http-request-failed :status 429
                        :body "{\"retry_after\":0}" :headers nil :uri nil :method :post)
                 "{\"id\":\"sent\"}"))))
    (setf (enchiridion.channel.fluxer::fluxer-channel-token channel) "fake")
    (ok (equal '("sent") (enchiridion.channel.fluxer::send-reply channel "target" "reply")))
    (ok (= 2 calls))
    (let ((enchiridion.llm::*http-request-function*
            (lambda (url &rest options)
              (declare (ignore url options))
              (make-string 65537 :initial-element #\a))))
      (ng (enchiridion.channel.fluxer::discover-gateway "fake"))
      (ok (signals (enchiridion.channel.fluxer::send-reply channel "target" "reply")
                   'enchiridion.errors:transport-error)))
    (let ((enchiridion.channel.fluxer::+reply-deadline-seconds+ 0.05)
          (enchiridion.llm::*http-request-function*
            (lambda (url &rest options)
              (declare (ignore url options))
              (sleep 2)
              "late")))
      (ok (signals (enchiridion.channel.fluxer::send-reply channel "target" "reply")
                   'enchiridion.errors:transport-error)))))

(deftest channel-reply-retries-its-reference-until-the-message-is-gone ()
  (let* ((sent '())
         (channel (enchiridion.channel.fluxer:make-fluxer-channel))
         (enchiridion.llm::*http-request-function*
           (lambda (url &rest options)
             (declare (ignore url))
             (push (enchiridion.llm:parse-json (getf options :content)) sent)
             (case (length sent)
               (1 (error 'dexador.error:http-request-failed :status 429
                         :body "{\"retry_after\":0}" :headers nil :uri nil :method :post))
               (2 (error 'dexador.error:http-request-failed :status 404
                         :body "{\"code\":\"UNKNOWN_MESSAGE\"}"
                         :headers nil :uri nil :method :post))
               (otherwise "{\"id\":\"reply\"}")))))
    (setf (enchiridion.channel.fluxer::fluxer-channel-token channel) "fake")
    (ok (equal '("reply")
               (enchiridion.channel:deliver channel "d-1" "answer" :reply-to "m-1")))
    (destructuring-bind (original rate-retry fallback) (reverse sent)
      (ok (equal '(:message_id "m-1") (getf original :message_reference)))
      (ok (equal original rate-retry))
      (ok (equal '(:content "answer") fallback)))))

(deftest a-reply-keeps-its-retry-budget-when-it-loses-its-reference ()
  (let ((channel (enchiridion.channel.fluxer:make-fluxer-channel)))
    (setf (enchiridion.channel.fluxer::fluxer-channel-token channel) "fake")
    (dolist (failures '((404 404) (429 429 429 404 429)))
      (let* ((remaining failures)
             (references '())
             (enchiridion.llm::*http-request-function*
               (lambda (url &rest options)
                 (declare (ignore url))
                 (push (getf (enchiridion.llm:parse-json (getf options :content))
                             :message_reference)
                       references)
                 (let ((status (pop remaining)))
                   (if status
                       (error 'dexador.error:http-request-failed
                              :status status
                              :body (if (= status 404)
                                        "{\"code\":\"UNKNOWN_MESSAGE\"}"
                                        "{\"retry_after\":0}")
                              :headers nil :uri nil :method :post)
                       "{\"id\":\"unexpected-extra-post\"}")))))
        (ok (signals (enchiridion.channel:deliver channel "d-1" "answer" :reply-to "m-1")
                     'enchiridion.errors:transport-error))
        (ok (equal references
                   (cons nil (make-list (1- (length failures))
                                        :initial-element '(:message_id "m-1")))))))))

(deftest unrelated-send-errors-do-not-drop-the-reference-and-retry ()
  (let ((channel (enchiridion.channel.fluxer:make-fluxer-channel)))
    (setf (enchiridion.channel.fluxer::fluxer-channel-token channel) "fake")
    (dolist (failure '((404 . "{\"code\":\"UNKNOWN_CHANNEL\"}")
                       (500 . "{\"message\":\"unavailable\"}")))
      (let* ((posts 0)
             (enchiridion.llm::*http-request-function*
               (lambda (url &rest options)
                 (declare (ignore url options))
                 (incf posts)
                 (error 'dexador.error:http-request-failed :status (car failure)
                        :body (cdr failure) :headers nil :uri nil :method :post))))
        (ok (signals (enchiridion.channel:deliver channel "d-1" "answer" :reply-to "m-1")
                     'enchiridion.errors:transport-error))
        (ok (= 1 posts))))))

;;;; The reaction lifecycle.
;;;;
;;;; A message carries one marker at a time: an hourglass while it waits, a
;;;; wrench while its turn runs, a warning when the turn or its reply fails, and
;;;; nothing once the reply is delivered. The queue coalesces per message, so
;;;; the tests read the queue directly where the thread is not the subject, and
;;;; start the thread where it is.

(deftest a-reaction-key-names-the-channel-and-the-message ()
  (ok (string= "d-1/m-1"
               (enchiridion.channel.fluxer::message-reaction-key
                +direct-message+)))
  (testing "a payload without both ids has no message to mark"
    (ng (enchiridion.channel.fluxer::message-reaction-key '(:id "m-1")))
    (ng (enchiridion.channel.fluxer::message-reaction-key '(:channel_id "d-1")))
    (ng (enchiridion.channel.fluxer::message-reaction-key nil))))

(deftest the-three-markers-are-the-documented-emoji ()
  (ok (string= "⏳" enchiridion.channel.fluxer::+queued-reaction+))
  (ok (string= "🔧" enchiridion.channel.fluxer::+processing-reaction+))
  (ok (string= "⚠️" enchiridion.channel.fluxer::+failed-reaction+)))

(deftest the-emoji-is-utf-8-percent-encoded-in-the-own-reaction-route ()
  (testing "an emoji is its UTF-8 octets, not its code point"
    (ok (string= "%E2%8F%B3"
                 (enchiridion.channel.fluxer::percent-encode-segment
                  enchiridion.channel.fluxer::+queued-reaction+)))
    (ok (string= "%F0%9F%94%A7"
                 (enchiridion.channel.fluxer::percent-encode-segment
                  enchiridion.channel.fluxer::+processing-reaction+)))
    ;; The warning is a base character and a variation selector, so this is
    ;; also the test that both code points reach the path.
    (ok (string= "%E2%9A%A0%EF%B8%8F"
                 (enchiridion.channel.fluxer::percent-encode-segment
                  enchiridion.channel.fluxer::+failed-reaction+))))
  (testing "the route is the bot's own reaction on the message"
    (ok (string= (concatenate 'string
                              "https://api.fluxer.app/v1/channels/d-1"
                              "/messages/m-1/reactions/%E2%8F%B3/@me")
                 (enchiridion.channel.fluxer::reaction-url
                  "d-1/m-1" enchiridion.channel.fluxer::+queued-reaction+)))))

(deftest a-marker-follows-a-message-and-a-delivery-clears-it ()
  (let* ((calls '())
         (channel (enchiridion.channel.fluxer:make-fluxer-channel))
         (enchiridion.llm::*http-request-function*
           (lambda (url &rest options)
             (push (list url (getf options :method)) calls)
             "")))
    (setf (enchiridion.channel.fluxer::fluxer-channel-token channel) "fake")
    (labels ((url (emoji)
               (enchiridion.channel.fluxer::reaction-url "d-1/m-1" emoji))
             (applied ()
               (enchiridion.channel.fluxer::applied-reaction channel "d-1/m-1"))
             (apply-state (state)
               (enchiridion.channel.fluxer::apply-reaction-state
                channel "d-1/m-1" state)))
      (testing "acceptance puts the hourglass with one PUT"
        (apply-state :queued)
        (ok (equal (list (list (url enchiridion.channel.fluxer::+queued-reaction+)
                               :put))
                   (reverse calls)))
        (ok (string= enchiridion.channel.fluxer::+queued-reaction+ (applied))))
      (testing "processing replaces it with the wrench"
        (apply-state :processing)
        (ok (equal (list (list (url enchiridion.channel.fluxer::+queued-reaction+)
                               :delete)
                         (list (url enchiridion.channel.fluxer::+processing-reaction+)
                               :put))
                   (reverse (subseq calls 0 2))))
        (ok (string= enchiridion.channel.fluxer::+processing-reaction+
                     (applied))))
      (testing "a delivered reply removes the wrench and remembers nothing"
        (apply-state :delivered)
        (ok (equal (list (url enchiridion.channel.fluxer::+processing-reaction+)
                         :delete)
                   (first calls)))
        (ok (null (applied))))
      (testing "a failure puts the warning over the wrench"
        (apply-state :processing)
        (apply-state :failed)
        (ok (equal (list (list (url enchiridion.channel.fluxer::+processing-reaction+)
                               :delete)
                         (list (url enchiridion.channel.fluxer::+failed-reaction+)
                               :put))
                   (reverse (subseq calls 0 2))))
        (ok (string= enchiridion.channel.fluxer::+failed-reaction+ (applied))))
      (testing "a state for a marker that was never put issues no delete"
        (setf calls '())
        (enchiridion.channel.fluxer::apply-reaction-state
         channel "d-2/m-2" :processing)
        (ok (equal (list (list (enchiridion.channel.fluxer::reaction-url
                                "d-2/m-2"
                                enchiridion.channel.fluxer::+processing-reaction+)
                               :put))
                   (reverse calls))))
      (testing "and a message delivered before the worker started costs nothing"
        (setf calls '())
        (enchiridion.channel.fluxer::apply-reaction-state
         channel "d-3/m-3" :delivered)
        (ok (null calls))))))

(deftest a-gone-message-is-not-a-reaction-failure ()
  (let ((channel (enchiridion.channel.fluxer:make-fluxer-channel)))
    (setf (enchiridion.channel.fluxer::fluxer-channel-token channel) "fake")
    (testing "a 404 says the message or the reaction is already gone"
      (let ((enchiridion.llm::*http-request-function*
              (lambda (url &rest options)
                (declare (ignore url options))
                (error 'dexador.error:http-request-failed
                       :status 404 :body "{\"message\":\"Unknown Message\"}"
                       :headers nil :uri nil :method :delete))))
        (ok (enchiridion.channel.fluxer::reaction-call
             channel "d-9/gone"
             enchiridion.channel.fluxer::+failed-reaction+ nil))))
    (testing "and a 500 is"
      (let ((enchiridion.llm::*http-request-function*
              (lambda (url &rest options)
                (declare (ignore url options))
                (error 'dexador.error:http-request-failed
                       :status 500 :body "{\"message\":\"boom\"}"
                       :headers nil :uri nil :method :put))))
        (ng (enchiridion.channel.fluxer::reaction-call
             channel "d-9/m-9"
             enchiridion.channel.fluxer::+queued-reaction+ t))))))

(deftest a-429-on-a-reaction-is-retried ()
  (let ((calls 0)
        (channel (enchiridion.channel.fluxer:make-fluxer-channel)))
    (setf (enchiridion.channel.fluxer::fluxer-channel-token channel) "fake")
    (let ((enchiridion.llm::*http-request-function*
            (lambda (url &rest options)
              (declare (ignore url options))
              (incf calls)
              (if (= calls 1)
                  (error 'dexador.error:http-request-failed
                         :status 429 :body "{\"retry_after\":0}"
                         :headers nil :uri nil :method :put)
                  ""))))
      (ok (enchiridion.channel.fluxer::reaction-call
           channel "d-1/m-1"
           enchiridion.channel.fluxer::+queued-reaction+ t)))
    (ok (= 2 calls))))

(deftest the-reaction-queue-coalesces-one-message-to-one-state ()
  (let ((channel (enchiridion.channel.fluxer:make-fluxer-channel)))
    (enchiridion.channel.fluxer::enqueue-reaction channel "d-1/m-1" :queued)
    (enchiridion.channel.fluxer::enqueue-reaction channel "d-2/m-2" :queued)
    (enchiridion.channel.fluxer::enqueue-reaction channel "d-1/m-1" :processing)
    (testing "two messages are two entries and the newer state wins"
      (ok (= 2 (length (enchiridion.channel.fluxer::fluxer-channel-reaction-order
                        channel))))
      (ok (eq :processing
              (gethash "d-1/m-1"
                       (enchiridion.channel.fluxer::fluxer-channel-reaction-pending
                        channel)))))
    (testing "and the queue is oldest first"
      (let ((first (enchiridion.channel.fluxer::dequeue-reaction channel)))
        (ok (string= "d-1/m-1" (car first)))
        (ok (eq :processing (cdr first))))
      (let ((second (enchiridion.channel.fluxer::dequeue-reaction channel)))
        (ok (string= "d-2/m-2" (car second)))
        (ok (eq :queued (cdr second))))
      (ok (null (enchiridion.channel.fluxer::dequeue-reaction channel))))))

(deftest a-message-delivered-before-the-worker-started-never-flickers ()
  (let* ((calls 0)
         (channel (enchiridion.channel.fluxer:make-fluxer-channel))
         (enchiridion.llm::*http-request-function*
           (lambda (url &rest options)
             (declare (ignore url options))
             (incf calls)
             "")))
    (setf (enchiridion.channel.fluxer::fluxer-channel-token channel) "fake")
    (enchiridion.channel.fluxer::enqueue-reaction channel "d-1/m-1" :queued)
    (enchiridion.channel.fluxer::enqueue-reaction channel "d-1/m-1" :processing)
    (enchiridion.channel.fluxer::enqueue-reaction channel "d-1/m-1" :delivered)
    (let ((entry (enchiridion.channel.fluxer::dequeue-reaction channel)))
      (ok (eq :delivered (cdr entry))))
    (enchiridion.channel.fluxer::apply-reaction-state
     channel "d-1/m-1" :delivered)
    (testing "the coalesced history costs no request at all"
      (ok (zerop calls)))))

(deftest the-reaction-worker-applies-the-states-in-order ()
  (let* ((calls '())
         (done (bordeaux-threads:make-semaphore))
         (channel (enchiridion.channel.fluxer:make-fluxer-channel)))
    (setf (enchiridion.channel.fluxer::fluxer-channel-token channel) "fake")
    (unwind-protect
         (progn
           (setf (enchiridion.channel.fluxer::fluxer-channel-reaction-worker channel)
                 (bordeaux-threads:make-thread
                  (lambda ()
                    (let ((enchiridion.llm::*http-request-function*
                            (lambda (url &rest options)
                              (push (list url (getf options :method)) calls)
                              (bordeaux-threads:signal-semaphore done)
                              "")))
                      (enchiridion.channel.fluxer::run-reaction-worker channel)))))
           (enchiridion.channel.fluxer::enqueue-reaction
            channel "d-1/m-1" :queued)
           (ok (bordeaux-threads:wait-on-semaphore done :timeout 2))
           (enchiridion.channel.fluxer::enqueue-reaction
            channel "d-1/m-1" :processing)
           (ok (bordeaux-threads:wait-on-semaphore done :timeout 2))
           (ok (bordeaux-threads:wait-on-semaphore done :timeout 2))
           (enchiridion.channel.fluxer::enqueue-reaction
            channel "d-1/m-1" :delivered)
           (ok (bordeaux-threads:wait-on-semaphore done :timeout 2))
           (labels ((url (emoji)
                      (enchiridion.channel.fluxer::reaction-url "d-1/m-1" emoji)))
             (ok (equal (list
                         (list (url enchiridion.channel.fluxer::+queued-reaction+)
                               :put)
                         (list (url enchiridion.channel.fluxer::+queued-reaction+)
                               :delete)
                         (list (url enchiridion.channel.fluxer::+processing-reaction+)
                               :put)
                         (list (url enchiridion.channel.fluxer::+processing-reaction+)
                               :delete))
                        (reverse calls)))))
      (enchiridion.channel.fluxer::stop-reaction-worker channel))
    (ok (null (enchiridion.channel.fluxer::fluxer-channel-reaction-worker channel)))))

(deftest an-accepted-message-is-marked-before-it-can-run ()
  (let* ((channel (enchiridion.channel.fluxer:make-fluxer-channel
                   :config '(:allowed-users ("u-1"))
                   :turn (lambda (message)
                           (declare (ignore message))
                           (list :ok-p t :reply "answer")))))
    (setf (enchiridion.channel.fluxer::fluxer-channel-token channel) "fake")
    (enchiridion.channel.fluxer::offer-message channel +direct-message+)
    (testing "the worker has it and the marker says it is waiting"
      (ok (= 1 (length (enchiridion.channel.fluxer::fluxer-channel-pending channel))))
      (ok (eq :queued
              (gethash "d-1/m-1"
                       (enchiridion.channel.fluxer::fluxer-channel-reaction-pending
                        channel)))))
    (let ((enchiridion.llm::*http-request-function*
            (lambda (url &rest options)
              (declare (ignore url options))
              "{\"id\":\"reply-1\"}")))
      (enchiridion.channel.fluxer::handle-inkbound
       channel
       (enchiridion.channel.fluxer::claim-inkbound channel)))
    (testing "and a delivered reply is the terminal state"
      (ok (eq :delivered
              (gethash "d-1/m-1"
                       (enchiridion.channel.fluxer::fluxer-channel-reaction-pending
                        channel)))))))

(deftest follow-ups-fold-only-the-same-sender-and-dm-before-publication ()
  (let ((channel nil) (posted '()) (folded nil))
    (setf channel
          (enchiridion.channel.fluxer:make-fluxer-channel
           :config '(:allowed-users ("u-1" "u-2")) :followups-p t
           :turn (lambda (message steer)
                   (declare (ignore message))
                   (dolist (data (list (list* :id "m-other-dm" :channel_id "d-2" +direct-message+)
                                       (list* :id "m-other-user" :author '(:id "u-2") +direct-message+)
                                       (list* :id "m-attachment" :content "" +direct-message+)
                                       (list* :id "m-folded" :content "a follow-up" +direct-message+)))
                     (enchiridion.channel.fluxer::offer-message channel data))
                   (setf folded (funcall steer :before-final))
                   (enchiridion.channel.fluxer::offer-message
                    channel (list* :id "m-later" :content "next turn" +direct-message+))
                   (list :ok-p t :reply "one reply"))))
    (let ((enchiridion.llm::*http-request-function*
            (lambda (url &rest options)
              (declare (ignore url))
              (push (enchiridion.llm:parse-json (getf options :content)) posted)
              "{\"id\":\"reply\"}")))
      (setf (enchiridion.channel.fluxer::fluxer-channel-token channel) "fake")
      (enchiridion.channel.fluxer::handle-inkbound channel +direct-message+))
    (ok (equal '("a follow-up") folded))
    (ok (= 1 (length posted)))
    (ok (equal '(:message_id "m-1") (getf (first posted) :message_reference)))
    (let ((reactions (enchiridion.channel.fluxer::fluxer-channel-reaction-pending channel))
          (pending (enchiridion.channel.fluxer::fluxer-channel-pending channel)))
      (ok (eq :delivered (gethash "d-1/m-1" reactions)))
      (ok (eq :delivered (gethash "d-1/m-folded" reactions)))
      (ok (equal '("m-other-dm" "m-other-user" "m-attachment" "m-later")
                 (mapcar (lambda (data) (getf data :id)) pending))))))

(deftest intentional-silence-clears-the-reaction-without-posting ()
  (let* ((posts 0)
         (*error-output* (make-string-output-stream))
         (enchiridion.llm::*http-request-function*
           (lambda (url &rest options)
             (declare (ignore url options))
             (incf posts)
             "{\"id\":\"unexpected-message\"}")))
    (dolist (silent-p '(t nil))
      (let ((channel (enchiridion.channel.fluxer:make-fluxer-channel
                      :turn (lambda (message)
                              (declare (ignore message))
                              (list :ok-p t :silent-p silent-p :reply "")))))
        (setf (enchiridion.channel.fluxer::fluxer-channel-token channel) "fake")
        (enchiridion.channel.fluxer::handle-inkbound
         channel (list* :content "private disclosure" +direct-message+))
        (ok (eq (if silent-p :delivered :failed)
                (gethash "d-1/m-1"
                         (enchiridion.channel.fluxer::fluxer-channel-reaction-pending channel))))))
    (ok (zerop posts))
    (let ((log (get-output-stream-string *error-output*)))
      (ok (search "chose not to reply to message m-1" log))
      (ok (search "returned no reply for message m-1" log))
      (ng (search "private disclosure" log)))))

(deftest a-failed-turn-marks-the-message-failed ()
  (dolist (turn (list (lambda (message)
                        (declare (ignore message))
                        (list :ok-p nil :error "boom"))
                      (lambda (message)
                        (declare (ignore message))
                        (error "kaboom"))))
    (let ((channel (enchiridion.channel.fluxer:make-fluxer-channel
                    :config '(:allowed-users ("u-1"))
                    :turn turn)))
      (enchiridion.channel.fluxer::handle-inkbound channel +direct-message+)
      (ok (eq :failed
              (gethash "d-1/m-1"
                       (enchiridion.channel.fluxer::fluxer-channel-reaction-pending
                        channel))))))
  (testing "and a channel with no turn function has nothing to deliver"
    (let ((channel (enchiridion.channel.fluxer:make-fluxer-channel)))
      (enchiridion.channel.fluxer::handle-inkbound channel +direct-message+)
      (ok (eq :failed
              (gethash "d-1/m-1"
                       (enchiridion.channel.fluxer::fluxer-channel-reaction-pending
                        channel)))))))

(deftest a-failed-marker-removal-keeps-the-old-marker ()
  (let* ((delete-fails nil)
         (calls '())
         (channel (enchiridion.channel.fluxer:make-fluxer-channel))
         (enchiridion.llm::*http-request-function*
           (lambda (url &rest options)
             (let ((method (getf options :method)))
               (push (list url method) calls)
               (if (and delete-fails (eq method :delete))
                   (error 'dexador.error:http-request-failed
                          :status 500 :body "{\"message\":\"boom\"}"
                          :headers nil :uri nil :method :delete)
                   "")))))
    (setf (enchiridion.channel.fluxer::fluxer-channel-token channel) "fake")
    (labels ((url (emoji)
               (enchiridion.channel.fluxer::reaction-url "d-1/m-1" emoji))
             (applied ()
               (enchiridion.channel.fluxer::applied-reaction channel "d-1/m-1"))
             (apply-state (state)
               (enchiridion.channel.fluxer::apply-reaction-state
                channel "d-1/m-1" state)))
      (apply-state :queued)
      (setf calls '()
            delete-fails t)
      (testing "a delete that fails stops the transition"
        (apply-state :processing)
        (ok (equal (list (list (url enchiridion.channel.fluxer::+queued-reaction+)
                               :delete))
                   (reverse calls)))
        (ok (string= enchiridion.channel.fluxer::+queued-reaction+ (applied))))
      (testing "and a later attempt that can delete still moves it"
        (setf calls '()
              delete-fails nil)
        (apply-state :processing)
        (ok (equal (list (list (url enchiridion.channel.fluxer::+queued-reaction+)
                               :delete)
                         (list (url enchiridion.channel.fluxer::+processing-reaction+)
                               :put))
                   (reverse calls)))
        (ok (string= enchiridion.channel.fluxer::+processing-reaction+
                     (applied)))))))

(deftest a-stop-rechecks-before-claiming-waiting-work ()
  (let ((channel (enchiridion.channel.fluxer:make-fluxer-channel)))
    (enchiridion.channel.fluxer::enqueue-inkbound
     channel '(:id "m-1" :channel_id "d-1"))
    (bordeaux-threads:with-lock-held
        ((enchiridion.channel.fluxer::fluxer-channel-pending-lock channel))
      (setf (enchiridion.channel.fluxer::fluxer-channel-stopping-p channel) t))
    (testing "the worker cannot claim after the stop flag is set"
      (ok (null (enchiridion.channel.fluxer::claim-inkbound channel)))
      (ok (= 1 (length (enchiridion.channel.fluxer::fluxer-channel-pending
                        channel)))))
    (testing "and the stop drains it as failed rather than losing it"
      (enchiridion.channel.fluxer::stop-worker channel)
      (ok (null (enchiridion.channel.fluxer::fluxer-channel-pending channel)))
      (ok (eq :failed
              (gethash "d-1/m-1"
                       (enchiridion.channel.fluxer::fluxer-channel-reaction-pending
                        channel)))))))

(deftest a-message-that-arrives-after-the-stop-is-not-queued ()
  (let ((channel (enchiridion.channel.fluxer:make-fluxer-channel)))
    (bordeaux-threads:with-lock-held
        ((enchiridion.channel.fluxer::fluxer-channel-pending-lock channel))
      (setf (enchiridion.channel.fluxer::fluxer-channel-stopping-p channel) t))
    (enchiridion.channel.fluxer::enqueue-inkbound
     channel '(:id "m-late" :channel_id "d-1"))
    (testing "nothing is left for a worker that has gone"
      (ok (null (enchiridion.channel.fluxer::fluxer-channel-pending channel))))
    (testing "and the message that was not queued is marked failed"
      (ok (eq :failed
              (gethash "d-1/m-late"
                       (enchiridion.channel.fluxer::fluxer-channel-reaction-pending
                        channel)))))))

(deftest a-markdown-reply-is-posted-as-complete-code-blocks ()
  (let* ((line (make-string 1200 :initial-element #\λ))
         (reply (format nil "```lisp~%~A~%~A~%```" line line))
         (channel (enchiridion.channel.fluxer:make-fluxer-channel
                   :config '(:allowed-users ("u-1"))
                   :turn (lambda (message)
                           (declare (ignore message))
                           (list :ok-p t :reply reply))))
         (sent '())
         (enchiridion.llm::*http-request-function*
           (lambda (url &rest options)
             (declare (ignore url))
             (push (enchiridion.llm:parse-json (getf options :content)) sent)
             "{\"id\":\"reply\"}")))
    (setf (enchiridion.channel.fluxer::fluxer-channel-token channel) "fake")
    (enchiridion.channel.fluxer::handle-inkbound channel +direct-message+)
    (let ((expected (format nil "```lisp~%~A~%```" line)))
      (destructuring-bind (first second) (reverse sent)
        (ok (equal expected (getf first :content)))
        (ok (equal '(:message_id "m-1") (getf first :message_reference)))
        (ok (equal (list :content expected) second))))))

(deftest a-reply-that-fails-mid-chunk-is-not-delivered ()
  (let* ((posts 0)
         (channel (enchiridion.channel.fluxer:make-fluxer-channel
                   :config '(:allowed-users ("u-1"))
                   :turn (lambda (message)
                           (declare (ignore message))
                           (list :ok-p t
                                 :reply (make-string 2500 :initial-element #\a)))))
         (enchiridion.llm::*http-request-function*
           (lambda (url &rest options)
             (declare (ignore url options))
             (incf posts)
             (if (= posts 1)
                 "{\"id\":\"first\"}"
                 (error 'dexador.error:http-request-failed
                        :status 500 :body "{\"message\":\"boom\"}"
                        :headers nil :uri nil :method :post)))))
    (setf (enchiridion.channel.fluxer::fluxer-channel-token channel) "fake")
    (enchiridion.channel.fluxer::handle-inkbound channel +direct-message+)
    (testing "both pieces were attempted and the second failed"
      (ok (= 2 posts)))
    (testing "so the marker is the warning and not a clear"
      (ok (eq :failed
              (gethash "d-1/m-1"
                       (enchiridion.channel.fluxer::fluxer-channel-reaction-pending
                        channel)))))))

(deftest a-message-evicted-from-the-turn-queue-is-marked-failed ()
  (let ((channel (enchiridion.channel.fluxer:make-fluxer-channel)))
    (dotimes (index enchiridion.channel.fluxer::+max-pending-messages+)
      (enchiridion.channel.fluxer::enqueue-inkbound
       channel (list :id (format nil "m-~D" index) :channel_id "d-1")))
    (enchiridion.channel.fluxer::enqueue-inkbound
     channel '(:id "m-new" :channel_id "d-1"))
    (testing "the queue stayed bounded and counted the drop"
      (ok (= enchiridion.channel.fluxer::+max-pending-messages+
             (length (enchiridion.channel.fluxer::fluxer-channel-pending channel))))
      (ok (= 1 (enchiridion.channel.fluxer::fluxer-channel-dropped channel))))
    (testing "the oldest waiting message carries the warning"
      (ok (eq :failed
              (gethash "d-1/m-0"
                       (enchiridion.channel.fluxer::fluxer-channel-reaction-pending
                        channel)))))
    (testing "and the message that was admitted does not"
      (ng (gethash "d-1/m-new"
                   (enchiridion.channel.fluxer::fluxer-channel-reaction-pending
                    channel))))))

(deftest the-reaction-queue-is-bounded ()
  (let ((channel (enchiridion.channel.fluxer:make-fluxer-channel)))
    (dotimes (index (1+ enchiridion.channel.fluxer::+max-pending-reactions+))
      (enchiridion.channel.fluxer::enqueue-reaction
       channel (format nil "d-1/m-~D" index) :queued))
    (ok (= enchiridion.channel.fluxer::+max-pending-reactions+
           (length (enchiridion.channel.fluxer::fluxer-channel-reaction-order
                    channel))))))

(deftest a-stop-marks-an-abandoned-turn-and-leaves-the-warning ()
  (let* ((channel (enchiridion.channel.fluxer:make-fluxer-channel
                   :config '(:allowed-users ("u-1"))
                   :turn (lambda (message)
                           (declare (ignore message))
                           (sleep 5)
                           (list :ok-p t :reply "late"))))
         (enchiridion.channel.fluxer::+stop-join-seconds+ 0.05))
    (setf (enchiridion.channel.fluxer::fluxer-channel-token channel) "fake")
    (unwind-protect
         (progn
           (setf (enchiridion.channel.fluxer::fluxer-channel-reaction-worker channel)
                 (bordeaux-threads:make-thread
                  (lambda ()
                    (let ((enchiridion.llm::*http-request-function*
                            (lambda (url &rest options)
                              (declare (ignore url options))
                              "")))
                      (enchiridion.channel.fluxer::run-reaction-worker channel)))
                  :name "fluxer test reactions"))
           (setf (enchiridion.channel.fluxer::fluxer-channel-worker channel)
                 (bordeaux-threads:make-thread
                  (lambda () (enchiridion.channel.fluxer::run-worker channel))
                  :name "fluxer test worker"))
           (enchiridion.channel.fluxer::enqueue-reaction
            channel "d-1/m-1" :queued)
           (enchiridion.channel.fluxer::enqueue-inkbound
            channel '(:id "m-1" :channel_id "d-1" :channel_type 1
                      :author (:id "u-1")))
           ;; Wait for the worker to be inside the turn, so the stop has a turn
           ;; to abandon rather than a message to dequeue and mark normally.
           (loop repeat 200
                 until (member "d-1/m-1"
                                (bordeaux-threads:with-lock-held
                                    ((enchiridion.channel.fluxer::fluxer-channel-pending-lock
                                      channel))
                                  (enchiridion.channel.fluxer::fluxer-channel-active-reactions
                                   channel))
                                :test #'equal)
                 do (sleep 0.01))
           ;; A second message waits behind the abandoned turn and must be
           ;; marked failed by the drain, not left for a worker that is gone.
           (enchiridion.channel.fluxer::enqueue-inkbound
            channel '(:id "m-2" :channel_id "d-1" :channel_type 1
                      :author (:id "u-1")))
           (enchiridion.channel.fluxer::shutdown channel)
           (testing "the abandoned turn ends on the warning marker"
             (ok (string= enchiridion.channel.fluxer::+failed-reaction+
                          (enchiridion.channel.fluxer::applied-reaction
                           channel "d-1/m-1"))))
           (testing "and the waiting message behind it is marked failed too"
             (ok (string= enchiridion.channel.fluxer::+failed-reaction+
                          (enchiridion.channel.fluxer::applied-reaction
                           channel "d-1/m-2"))))
           (testing "and the reaction thread is gone"
             (ok (null (enchiridion.channel.fluxer::fluxer-channel-reaction-worker
                        channel)))))
      (ignore-errors (enchiridion.channel.fluxer::shutdown channel)))))

;;;; The session cursor, the reconnect budget, and a socket that goes quiet.
;;;;
;;;; A session and its dispatch sequence are one object: the gateway numbers
;;;; from one again in every new session, so a cursor kept across an Identify
;;;; leaves a channel connected and silent.

(deftest an-identify-forgets-the-session-and-its-cursor ()
  (let ((channel (enchiridion.channel.fluxer:make-fluxer-channel
                  :config '(:allowed-users ("u-1"))))
        (socket (make-instance 'enchiridion.channel.fluxer::fluxer-socket
                               :url "ws://offline.invalid/")))
    (setf (enchiridion.channel.fluxer::fluxer-channel-sequence channel) 500
          (enchiridion.channel.fluxer::fluxer-channel-session-id channel) "s-a"
          (enchiridion.channel.fluxer::fluxer-channel-token channel) "1234.secret")
    (enchiridion.channel.fluxer::send-identify channel socket)
    (testing "the id and the cursor of the session it leaves are gone"
      (ok (null (enchiridion.channel.fluxer::fluxer-channel-sequence channel)))
      (ok (null (enchiridion.channel.fluxer::fluxer-channel-session-id channel))))
    (testing "and an Identify is what went on the wire"
      (let ((sent (car (aref (websocket-driver.ws.base::queue socket) 0))))
        (ok (search "\"op\":2" sent))))
    (testing "so the READY of the new session is new work and arms the echo guard"
      (enchiridion.channel.fluxer::handle-dispatch
       channel
       (enchiridion.channel.fluxer::parse-frame
        "{\"op\":0,\"t\":\"READY\",\"s\":1,\"d\":{\"session_id\":\"s-b\",\"user\":{\"id\":\"u-9\"}}}"))
      (ok (eql 1 (enchiridion.channel.fluxer::fluxer-channel-sequence channel)))
      (ok (string= "s-b"
                   (enchiridion.channel.fluxer::fluxer-channel-session-id channel)))
      (ok (string= "u-9"
                   (enchiridion.channel.fluxer::fluxer-channel-self-id channel))))
    (testing "and a message in that session is delivered rather than dropped as a replay"
      (enchiridion.channel.fluxer::handle-dispatch
       channel
       (enchiridion.channel.fluxer::parse-frame
        (enchiridion.channel.fluxer::json-text
         (list :op 0 :s 2 :t "MESSAGE_CREATE" :d +direct-message+))))
      (ok (eql 2 (enchiridion.channel.fluxer::fluxer-channel-sequence channel)))
      (ok (eql 1 (length (enchiridion.channel.fluxer::fluxer-channel-pending channel)))))))

(deftest an-invalid-session-identifies-again-on-the-same-socket ()
  (let ((channel (enchiridion.channel.fluxer:make-fluxer-channel
                  :config '(:allowed-users ("u-1"))))
        (socket (make-instance 'enchiridion.channel.fluxer::fluxer-socket
                               :url "ws://offline.invalid/")))
    (setf (enchiridion.channel.fluxer::fluxer-channel-sequence channel) 500
          (enchiridion.channel.fluxer::fluxer-channel-session-id channel) "s-a"
          (enchiridion.channel.fluxer::fluxer-channel-token channel) "1234.secret")
    (enchiridion.channel.fluxer::note-invalid-session channel socket)
    (testing "the session is abandoned, cursor and all"
      (ok (null (enchiridion.channel.fluxer::fluxer-channel-sequence channel)))
      (ok (null (enchiridion.channel.fluxer::fluxer-channel-session-id channel))))
    (testing "and op 2 is what went out, because op 9 says a resume cannot work"
      (let ((sent (car (aref (websocket-driver.ws.base::queue socket) 0))))
        (ok (search "\"op\":2" sent))))))

(deftest a-ready-for-another-session-recovers-a-stale-cursor ()
  (testing "a numbering that restarted is recognised from the READY alone"
    (let ((channel (enchiridion.channel.fluxer:make-fluxer-channel
                    :config '(:allowed-users ("u-1")))))
      (setf (enchiridion.channel.fluxer::fluxer-channel-sequence channel) 500
            (enchiridion.channel.fluxer::fluxer-channel-session-id channel) "s-a")
      (enchiridion.channel.fluxer::handle-dispatch
       channel
       (enchiridion.channel.fluxer::parse-frame
        "{\"op\":0,\"t\":\"READY\",\"s\":1,\"d\":{\"session_id\":\"s-b\",\"user\":{\"id\":\"u-9\"}}}"))
      (ok (eql 1 (enchiridion.channel.fluxer::fluxer-channel-sequence channel)))
      (ok (string= "s-b"
                   (enchiridion.channel.fluxer::fluxer-channel-session-id channel)))
      (ok (string= "u-9"
                   (enchiridion.channel.fluxer::fluxer-channel-self-id channel)))))
  (testing "a resumed session keeps the cursor it already had"
    (let ((channel (enchiridion.channel.fluxer:make-fluxer-channel
                    :config '(:allowed-users ("u-1")))))
      (setf (enchiridion.channel.fluxer::fluxer-channel-sequence channel) 500
            (enchiridion.channel.fluxer::fluxer-channel-session-id channel) "s-a")
      (enchiridion.channel.fluxer::handle-dispatch
       channel
       (enchiridion.channel.fluxer::parse-frame
        "{\"op\":0,\"t\":\"READY\",\"s\":501,\"d\":{\"session_id\":\"s-a\",\"user\":{\"id\":\"u-9\"}}}"))
      (ok (eql 501 (enchiridion.channel.fluxer::fluxer-channel-sequence channel)))
      (ok (string= "s-a"
                   (enchiridion.channel.fluxer::fluxer-channel-session-id channel))))))

;;;; The reconnect budget.

(deftest a-gateway-that-closes-after-ready-does-not-reset-the-budget ()
  (testing "a connection shorter than the stable window is one more attempt"
    (ok (eql 1 (enchiridion.channel.fluxer::next-attempt 0 0)))
    (ok (eql 2 (enchiridion.channel.fluxer::next-attempt 1 0)))
    (testing "so a gateway that flaps is given up on, and not retried forever"
      (ok (eql 6 (enchiridion.channel.fluxer::next-attempt 5 29)))))
  (testing "a connection that stayed up earns a fresh budget"
    (ok (eql 1 (enchiridion.channel.fluxer::next-attempt 5 30)))
    (ok (eql 1 (enchiridion.channel.fluxer::next-attempt 4 3600))))
  (testing "READY is not what resets the count"
    (let ((channel (enchiridion.channel.fluxer:make-fluxer-channel
                    :config '(:allowed-users ("u-1")))))
      (setf (enchiridion.channel.fluxer::fluxer-channel-attempt channel) 3)
      (enchiridion.channel.fluxer::handle-dispatch
       channel
       (enchiridion.channel.fluxer::parse-frame
        "{\"op\":0,\"t\":\"READY\",\"s\":1,\"d\":{\"session_id\":\"s-1\"}}"))
      (ok (eql 3 (enchiridion.channel.fluxer::fluxer-channel-attempt channel))))))

;;;; A socket that goes quiet without closing.

(deftest a-socket-that-stops-answering-heartbeats-is-replaced ()
  (testing "a beat is overdue once the window passes without an answer"
    (ok (enchiridion.channel.fluxer::heartbeat-ack-overdue-p 100 nil 146))
    (ok (enchiridion.channel.fluxer::heartbeat-ack-overdue-p 100 99 146)))
  (testing "an answered beat is not overdue"
    (ng (enchiridion.channel.fluxer::heartbeat-ack-overdue-p 100 100 146))
    (ng (enchiridion.channel.fluxer::heartbeat-ack-overdue-p 100 130 146)))
  (testing "an answer to an earlier beat does not answer this one"
    (ng (enchiridion.channel.fluxer::heartbeat-ack-overdue-p 140 130 146))
    (ok (enchiridion.channel.fluxer::heartbeat-ack-overdue-p 140 130 186)))
  (testing "nothing is overdue before the first beat"
    (ng (enchiridion.channel.fluxer::heartbeat-ack-overdue-p nil nil 100000)))
  (testing "and the loop closes the socket rather than waiting on a dead transport"
    (let* ((channel (enchiridion.channel.fluxer:make-fluxer-channel))
           (socket (make-instance 'enchiridion.channel.fluxer::fluxer-socket
                                  :url "ws://offline.invalid/"))
           ;; A closed window: the test is about the close, not about the wait
           (enchiridion.channel.fluxer::+heartbeat-ack-timeout-seconds+ -1))
      (setf (enchiridion.channel.fluxer::fluxer-socket-heartbeat-interval socket) 1)
      (enchiridion.channel.fluxer::run-heartbeats channel socket)
      (ok (eq :closed (websocket-driver.ws.base:ready-state socket))))))

;;;; A frame from a socket the channel has already left.

(deftest a-frame-from-a-socket-the-channel-has-left-is-dropped ()
  (labels ((channel-with-socket (socket)
             (let ((channel (enchiridion.channel.fluxer:make-fluxer-channel
                             :config '(:allowed-users ("u-1")))))
               (setf (enchiridion.channel.fluxer::fluxer-channel-socket channel) socket)
               channel))
           (dispatch (channel socket sequence)
             (enchiridion.channel.fluxer::handle-text
              channel socket
              (enchiridion.channel.fluxer::json-text
               (list :op 0 :s sequence :t "MESSAGE_CREATE" :d +direct-message+)))))
    (let* ((live (make-instance 'enchiridion.channel.fluxer::fluxer-socket
                                :url "ws://offline.invalid/live"))
           (stale (make-instance 'enchiridion.channel.fluxer::fluxer-socket
                                 :url "ws://offline.invalid/stale"))
           (channel (channel-with-socket live)))
      (testing "a frame from the socket the channel has left moves nothing"
        (dispatch channel stale 900)
        (ok (null (enchiridion.channel.fluxer::fluxer-channel-sequence channel)))
        (ok (null (enchiridion.channel.fluxer::fluxer-channel-pending channel))))
      (testing "a frame from the live socket is delivered"
        (dispatch channel live 901)
        (ok (eql 901 (enchiridion.channel.fluxer::fluxer-channel-sequence channel)))
        (ok (eql 1 (length (enchiridion.channel.fluxer::fluxer-channel-pending channel)))))
      (testing "and a channel that has recorded no socket yet accepts the first one"
        (let ((channel (channel-with-socket nil)))
          (dispatch channel stale 1)
          (ok (eql 1 (enchiridion.channel.fluxer::fluxer-channel-sequence channel))))))))

;;;; The loop that uses all of the above.

(deftest the-reconnect-loop-gives-up-after-the-budget ()
  (let* ((channel (enchiridion.channel.fluxer:make-fluxer-channel
                   :config '(:allowed-users ("u-1")
                             :token-env "ENCHIRIDION_FLUXER_BUDGET_TOKEN")
                   :turn (lambda (message)
                           (declare (ignore message))
                           (list :ok-p t :reply "answer"))))
         (enchiridion.channel.fluxer::+reconnect-base-seconds+ 0.01)
         (enchiridion.llm::*http-request-function*
           (lambda (url &rest options)
             (declare (ignore options))
             (if (search "/gateway/bot" url)
                 ;; A gateway that cannot be reached fails before READY, the
                 ;; fastest way to exercise the count
                 "{\"url\":\"ws://127.0.0.1:1/\"}"
                 "{\"id\":\"x\"}"))))
    (unwind-protect
         (progn
           (enchiridion.llm.secrets:register-secret
            "ENCHIRIDION_FLUXER_BUDGET_TOKEN" "1234.secret")
           (enchiridion.channel:channel-start channel)
           (testing "the channel stops rather than retrying forever"
             (ok (eql (1+ enchiridion.channel.fluxer::+max-reconnect-attempts+)
                      (enchiridion.channel.fluxer::fluxer-channel-attempt channel)))
             (ok (eq :failed (enchiridion.channel:channel-status channel)))
             (ok (null (enchiridion.channel:channel-live-p channel)))))
      (enchiridion.llm.secrets:clear-secrets)
      (ignore-errors (enchiridion.channel:channel-stop channel)))))
