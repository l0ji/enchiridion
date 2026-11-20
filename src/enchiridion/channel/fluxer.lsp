;;;; fluxer.lsp --- The Fluxer direct-message channel.
;;;;
;;;; The gateway is the inbound half and REST is the outbound half: events
;;;; arrive on a websocket, replies leave as one POST per message. Both halves
;;;; live in one file because they share one token and one allowlist, and a
;;;; channel whose authorisation is read in two files is a channel whose two
;;;; files drift apart.
;;;;
;;;; Three rules are load bearing and each one has a test that pins it. The
;;;; allowlist denies by default, so an empty list admits nobody. Only direct
;;;; messages are answered, so a guild event, a group channel, a bot, and the
;;;; agent's own echo never reach a turn. The reply is scrubbed before it
;;;; becomes a REST body, because this is the one path that ends at a person.
;;;;
;;;; Everything that can spin is bounded. Reconnects are counted and backed
;;;; off. The heartbeat waits in slices and stops on the same flag a close
;;;; sets. The worker is the only thread that runs a turn, so the library's
;;;; read thread never holds a turn while the socket backs up behind it. The
;;;; reaction thread is a third thread with a bounded, coalescing queue, so a
;;;; cosmetic marker never sits in front of a socket or a turn.
;;;;
;;;; The protocol is facts and pure functions at the top of the file. The
;;;; socket, the threads, and the HTTP calls below them use those facts, so
;;;; every one of them is testable without a network and the tests need no
;;;; server. Nothing here reaches the kernel: a turn arrives as an injected
;;;; function, which is what lets the whole channel be tested with a closure.

(in-package #:enchiridion.channel.fluxer)

;;;; The protocol facts.
;;;;
;;;; Taken from the Fluxer REST and gateway documentation and from a live
;;;; gateway, so they are recorded rather than derived. None of them is
;;;; written twice: the tests read the same numbers the code does.

(defparameter +rest-base+ "https://api.fluxer.app/v1"
  "The REST base every Fluxer call is made under.")

(defparameter +gateway-path+ "/gateway/bot"
  "The discovery path, under +REST-BASE+, that answers with the websocket url.")

(defparameter +gateway-query+ "?v=1&encoding=json"
  "What the advertised gateway url is missing. Ask for version 1 and JSON
frames explicitly, because the url /gateway/bot answers carries no query
string of its own.")

(defparameter +default-heartbeat-interval+ 41250
  "The heartbeat interval in milliseconds to assume before Hello arrives. It is
the number the live gateway sent, and it is only a fallback: Hello decides.")

(defparameter +heartbeat-ack-timeout-seconds+ 45
  "How long a heartbeat may stay unacknowledged before the socket is treated as
closed.

The gateway closes 4009 after 45 seconds without an acknowledgement, so a socket
that stopped acknowledging is already dropped. A half open transport never says
so: writes still succeed and nothing arrives, which is why the check is here and
not a close code.")

(defparameter +identify-wait-seconds+ 10
  "How long to wait for Hello after the handshake. A gateway that accepts the
socket and then says nothing is not a gateway to sit and wait on.")

(defparameter +message-limit+ 2000
  "How many characters one message may carry. The resolved default for a bot.")

(defparameter +custom-status-max-characters+ 128
  "The longest custom status text the gateway accepts, in characters.")

(defparameter +custom-status-max-ttl-seconds+ 86400
  "The longest configurable custom status lifetime, in seconds.")

(defparameter +custom-status-max-cooldown-seconds+ 3600
  "The longest configurable custom status cooldown, in seconds.")

(defparameter +presence-online+ "online"
  "The base presence every custom status update carries.

The gateway requires d.status even when only custom_status changes, so the
channel names the one state it wants rather than leaving the field to default.")

(defparameter +http-timeout-seconds+ 15
  "Seconds to wait for one REST call. A send that has not answered by then is a
send the operator has already given up on.")

(defparameter +max-reconnect-attempts+ 5
  "How many reconnects in a row to try before the channel gives up and returns
to its supervisor. A counted loop is what stops a dead gateway from becoming a
busy loop, and the supervisor restarts the channel a second later anyway.")

(defparameter +reconnect-base-seconds+ 1
  "The first reconnect wait, in seconds. Each later wait doubles it.")

(defparameter +reconnect-max-seconds+ 60
  "The longest reconnect wait, in seconds, so a gateway that is down is not
hammered once a minute forever.")

(defparameter +reconnect-stable-seconds+ 30
  "How long one connection must last before it earns a fresh reconnect budget.

A gateway that completes the handshake and closes again reaches READY too, so a
reset on READY alone would retry it once a second for the life of the process.
Thirty seconds is most of one heartbeat interval, long enough that a connection
which lasted it has shown the transport works.")

(defparameter +resume-window-seconds+ 60
  "How long the gateway keeps a session after a transport ends, in seconds. A
reconnect inside the window resumes; a later one identifies again.")

(defparameter +rate-limit-attempts+ 3
  "How many times one message is retried after a 429. The route bucket is 20
requests in 10 seconds per user per channel, so a batched reply can cross it.")

(defparameter +max-pending-messages+ 32
  "How many inkbound messages may wait for the worker. A turn can take minutes,
and an unbounded queue in front of it is an unbounded amount of memory.")

(defparameter +worker-wait-seconds+ 0.2
  "How long the worker waits for work before looking at the stop flag again.
The wait is signalled as well as timed, so this is the worst case for a lost
wake-up and never the case for a message.")

(defparameter +stop-join-seconds+ 5
  "How long a stop waits for the worker. A turn already in flight is given
this long and is then destroyed: a stop that waits for a model call is a stop
that never finishes.")

(defparameter +op-dispatch+ 0
  "The dispatch opcode. Every event arrives as one of these.")

(defparameter +op-heartbeat+ 1
  "The heartbeat opcode. The payload is the last processed dispatch sequence,
or null before the first one, and the gateway answers with op 11.")

(defparameter +op-identify+ 2
  "The identify opcode. It authenticates a fresh session on an open socket.")

(defparameter +op-presence+ 3
  "The presence opcode. It sets the displayed status and custom status. The
gateway sends no acknowledgement for it, so a frame that left the socket is all
this channel can know.")

(defparameter +op-resume+ 6
  "The resume opcode. It reattaches to a session the gateway still holds.")

(defparameter +op-reconnect+ 7
  "The reconnect opcode. The gateway is asking for a new socket.")

(defparameter +op-invalid-session+ 9
  "The invalid session opcode. The socket stays open and unauthenticated, so
the answer is another Identify on the same socket, never a Resume.")

(defparameter +op-hello+ 10
  "The hello opcode. It carries the heartbeat interval and is the first frame
after the handshake.")

(defparameter +op-heartbeat-ack+ 11
  "The heartbeat acknowledgement opcode. The gateway closes 4009 when 45
seconds pass without one.")

(defparameter +direct-message-channel-type+ 1
  "The channel_type a one-on-one direct message carries. Every other number is
a group channel or a guild channel, and this channel answers neither.")

(defparameter +fatal-close-codes+ '(4002 4004 4012)
  "The close codes that say trying again cannot work: 4002 an Identify the
gateway could not decode, 4004 a token it refused, 4012 an API version it does
not speak. The other codes in the range are worth a reconnect.")

(defparameter +close-code-notes+
  '((1000 . "normal closure")
    (1001 . "going away")
    (1006 . "abnormal closure")
    (4000 . "unknown error")
    (4001 . "unknown opcode")
    (4002 . "decode error")
    (4003 . "not authenticated")
    (4004 . "authentication failed")
    (4005 . "already authenticated")
    (4007 . "invalid sequence")
    (4008 . "rate limited")
    (4009 . "heartbeat timeout")
    (4010 . "invalid shard")
    (4011 . "sharding required")
    (4012 . "invalid API version")
    (4013 . "invalid intents")
    (4014 . "disallowed intents"))
  "A short note per close code, so a log line names what happened instead of
printing a number the operator has to look up.")

(defparameter +token-env-default+ "FLUXER_BOT_TOKEN"
  "The environment variable name used when the configuration names none.")

;; jzon writes NIL as false and spells JSON null as an unexported symbol, and
;; the heartbeat payload is null before the first dispatch. This is the one
;; place this file names a dependency's internals, and the test that reads the
;; frame's text is what keeps the name honest. The alternative, building the
;; frame with a format string, puts the JSON escaping of every other frame in
;; this file's hands for the sake of one word.
(defconstant +json-null+ 'com.inuoe.jzon::null
  "The value STRINGIFY writes as JSON null rather than as false.")

;;;; Reading a frame.

(declaim (ftype (function (string) t) parse-frame))

(defun parse-frame (text)
  "Return TEXT, one gateway frame, as a plist with keyword keys, or NIL.

NIL is the answer for anything that is not a JSON object with a numeric op:
the gateway sends text frames only, but a proxy in front of it answers HTML,
and a frame this channel cannot read is a frame to drop rather than a
condition thrown on the library's read thread."
  (handler-case
      (let ((frame (enchiridion.llm:parse-json text)))
        (when (and (consp frame) (integerp (getf frame :op)))
          frame))
    (error () nil)))

(declaim (ftype (function (t) t) frame-op))

(defun frame-op (frame)
  "Return the opcode of FRAME, or NIL."
  (getf frame :op))

(declaim (ftype (function (t) t) frame-seq))

(defun frame-seq (frame)
  "Return the dispatch sequence number of FRAME, or NIL.

A replayed dispatch keeps its old number, which makes this the one place a
redelivery is visible. Ready is 1 and the count starts at 0."
  (getf frame :s))

(declaim (ftype (function (t) t) frame-data))

(defun frame-data (frame)
  "Return the payload of FRAME, or NIL."
  (getf frame :d))

(declaim (ftype (function (t) (or null integer)) hello-interval))

(defun hello-interval (frame)
  "Return the heartbeat interval in milliseconds FRAME, an op 10 Hello, names,
or NIL when it names none."
  (let ((data (frame-data frame)))
    (when (consp data)
      (let ((interval (getf data :heartbeat_interval)))
        (and (integerp interval) (plusp interval) interval)))))

(declaim (ftype (function (t &optional t t) (or null integer)) frame-close-code))

(defun frame-close-code (data &optional start end)
  "Return the close code in DATA, one whole websocket frame, or NIL.

DATA is a frame as it came off the socket: a flags byte with the opcode in its
low nibble, a length byte with the mask bit above it, an extended length when
the payload is long, a masking key when the sender masked it, and then the
payload. A close frame with fewer than two payload bytes carries no code, a
frame that is not a close frame has none, and a masked code is unmasked here.

This exists because the library loses the code. Its close callback answers the
peer's close frame and the transport then ends, so the :close event that fires
afterwards has NIL where the code was. While the frame is still bytes it is the
only place left to read it, and the code is what tells a refused token from a
network blip."
  (let ((start (or start 0))
        (end (or end (length data))))
    (when (>= (- end start) 2)
      (let* ((opcode (logand #x0f (aref data start)))
             (masked (logand #x80 (aref data (1+ start))))
             (length (logand #x7f (aref data (1+ start))))
             (extended (cond ((= length 126) 2)
                             ((= length 127) 8)
                             (t 0)))
             (key-start (+ start 2 extended))
             (payload-start (if (plusp masked) (+ key-start 4) key-start)))
        (when (and (= opcode 8) (<= (+ payload-start 2) end))
          (let ((high (aref data payload-start))
                (low (aref data (1+ payload-start))))
            (when (plusp masked)
              (setf high (logxor high (aref data key-start))
                    low (logxor low (aref data (1+ key-start)))))
            (+ (ash high 8) low)))))))

(declaim (ftype (function (t) string) close-code-note))

(defun close-code-note (code)
  "Return a short phrase for CODE, a websocket close code, for one log line."
  (or (cdr (assoc code +close-code-notes+))
      (and (integerp code) (format nil "close code ~D" code))
      "no close code"))

;;;; Building a frame.

(declaim (ftype (function (t) t) json-shape))

(defun json-shape (value)
  "Return VALUE in the shape STRINGIFY writes as JSON.

A plist becomes an object and a list becomes an array. A plist handed straight
to STRINGIFY writes as an array of alternating elements, so an Identify frame
would go on the wire as [\"op\",2,...] and the gateway would answer with a
decode error. Keys are the downcased keyword names, which is what a JSON object
conventionally looks like; the reading side upcases whatever it gets."
  (cond
    ((and (consp value) (keywordp (first value)))
     (let ((table (make-hash-table :test #'equal)))
       (loop for (key item) on value by #'cddr
             do (setf (gethash (string-downcase (symbol-name key)) table)
                      (json-shape item)))
       table))
    ((consp value) (coerce (mapcar #'json-shape value) 'vector))
    ((and (vectorp value) (not (stringp value))) (map 'vector #'json-shape value))
    (t value)))

(declaim (ftype (function (t) string) json-text))

(defun json-text (value)
  "Return VALUE as the JSON text one frame or one REST body is sent as."
  (enchiridion.llm:stringify (json-shape value)))

(declaim (ftype (function (t) (or null string)) non-blank-string))

(defun non-blank-string (value)
  "Return VALUE as a string without surrounding whitespace, or NIL.

NIL is the answer for a non string, for the empty string, and for a string that
holds nothing but whitespace. A value that came from a shell or a file is
allowed to have a newline on it, and a name that is only whitespace is not a
name."
  (let ((trimmed (and (stringp value)
                      (string-trim '(#\Space #\Tab #\Newline #\Return) value))))
    (and trimmed (plusp (length trimmed)) trimmed)))

(declaim (ftype (function (t) (or null string)) gateway-url))

(defun gateway-url (advertised)
  "Return ADVERTISED, the url GET /gateway/bot answers, or NIL.

The scheme is left exactly as advertised, because a self-hosted deployment may
advertise ws:// and rewriting it to wss:// would break the one deployment that
is not the public one. The version and the encoding are asked for explicitly,
because the advertised url carries no query string of its own."
  (let ((url (non-blank-string advertised)))
    (when url
      (concatenate 'string url (if (find #\? url) "&v=1&encoding=json"
                                   +gateway-query+)))))

(declaim (ftype (function (string) list) identify-frame))

(defun identify-frame (token)
  "Return the op 2 Identify frame for TOKEN.

There is no intents field and no shard field, and sending neither is correct:
direct messages are account scoped, so they arrive without asking for a
gateway intent, and this client is one shard. The properties object is not
optional: an Identify without it closes the socket with 4002."
  (list :op +op-identify+
        :d (list :token token
                 :properties (list :os "linux"
                                   :browser "enchiridion"
                                   :device "enchiridion"))))

(declaim (ftype (function (t) list) heartbeat-frame))

(defun heartbeat-frame (sequence)
  "Return the op 1 heartbeat frame for SEQUENCE, or for NIL before the first
dispatch.

SEQUENCE is the last PROCESSED dispatch sequence and not the last seen one.
NIL goes on the wire as null and not as false: the gateway reads one as no
sequence yet and the other as a sequence that is not a number."
  (list :op +op-heartbeat+
        :d (if (integerp sequence) sequence +json-null+)))

(declaim (ftype (function (string string t) list) resume-frame))

(defun resume-frame (token session-id sequence)
  "Return the op 6 resume frame for TOKEN, SESSION-ID, and SEQUENCE.

A resume is only worth sending inside the 60 seconds the gateway keeps a
session, and only with a session id it gave us. It replays whatever was
missed, which the sequence filter then drops where it was already answered."
  (list :op +op-resume+
        :d (list :token token
                 :session_id session-id
                 :seq (if (integerp sequence) sequence +json-null+))))

(declaim (ftype (function (string) list) message-body))

(defun message-body (text)
  "Return the REST body that posts TEXT as one message.

One field, because that is what the endpoint takes, and the test pins that
there is no second one: an unknown field is ignored by one gateway version and
refused by the next."
  (list :content text))

;;;; The agent's custom status.
;;;;
;;;; A status is public the moment it leaves this process, so the adapter and
;;;; not the agent owns the last word: the text is one line of bounded length,
;;;; it carries no secret the scrubber would redact, and it is the agent's
;;;; deliberate proposal rather than anything read out of its reasoning. The
;;;; channel also owns the lifetime and the spacing between changes, because a
;;;; model that can publish on every turn is a model that can flood a profile.

(declaim (ftype (function (character) boolean) control-character-p))

(defun control-character-p (character)
  "Return T when CHARACTER cannot appear in a one line status."
  (let ((code (char-code character)))
    (or (< code 32) (= code 127))))

(declaim (ftype (function (t) (values (or null string) (or null string)))
                validate-custom-status))

(defun validate-custom-status (proposal)
  "Return PROPOSAL as custom status text and NIL, or NIL and the refusal.

The text is trimmed, must be non-empty and at most
+CUSTOM-STATUS-MAX-CHARACTERS+ characters, must not contain a line break or any
other control character, and must survive the scrubber unchanged. A value the
scrubber would redact is refused rather than published redacted: the marker is
noise on a profile and the text that produced it was never meant to be public."
  (unless (stringp proposal)
    (return-from validate-custom-status
      (values nil "a custom status is a string.")))
  (let ((text (string-trim '(#\Space #\Tab #\Newline #\Return) proposal)))
    (cond
      ((zerop (length text))
       (values nil "the custom status is blank."))
      ((> (length text) +custom-status-max-characters+)
       (values nil (format nil "the custom status is longer than ~D characters."
                           +custom-status-max-characters+)))
      ((find-if #'control-character-p text)
       (values nil "the custom status must be one line."))
      (t
       (let ((clean (enchiridion.llm.secrets:scrub text)))
         (if (string= clean text)
             (values text nil)
             (values nil "the scrubber redacts this status.")))))))

(declaim (ftype (function ((or null string)) list) presence-frame))

(defun presence-frame (text)
  "Return the op 3 frame that sets TEXT, or clears the custom status when TEXT
is NIL.

The documented clear is a null custom_status and not an empty text, because a
text must be 1 to 128 characters. d.status is required even when only the
custom status changes, and this channel does not play with idle or do not
disturb."
  (list :op +op-presence+
        :d (list :status +presence-online+
                 :custom_status (if text
                                    (list :text text)
                                    +json-null+))))

;;;; Who may talk, and what counts as a message.

(declaim (ftype (function (t t) boolean) allowed-p))

(defun allowed-p (allowlist id)
  "Return T when ID, a sender's user id, is on ALLOWLIST.

Deny by default, in four ways at once: a NIL or empty allowlist admits nobody,
a missing or non string id is refused, a non string entry cannot make itself
match, and a non list allowlist is no allowlist. The comparison is against the
user id and never against a username, because a username is a string its owner
can change and an allowlist keyed on one is an allowlist a stranger can join."
  (and (stringp id)
       (plusp (length id))
       (consp allowlist)
       (not (null (member id (remove-if-not #'stringp allowlist)
                          :test #'string=)))))

(declaim (ftype (function (t) (or null string)) author-id))

(defun author-id (data)
  "Return the sender's user id in DATA, a message object, or NIL."
  (let ((author (and (consp data) (getf data :author))))
    (when (consp author)
      (non-blank-string (getf author :id)))))

(declaim (ftype (function (t t) string) text-field))

(defun text-field (data key)
  "Return KEY of DATA as a string, or the empty string.

Every slot of the one message shape is typed STRING, so a field the gateway
sent as a number, or did not send at all, becomes the empty string here
instead of a type error three calls later."
  (let ((value (and (consp data) (getf data key))))
    (if (stringp value) value "")))

(declaim (ftype (function (t) boolean) direct-message-p))

(defun direct-message-p (data)
  "Return T when DATA describes a one-on-one direct message."
  (and (consp data)
       (eql +direct-message-channel-type+ (getf data :channel_type))))

(declaim (ftype (function (t) boolean) guild-event-p))

(defun guild-event-p (data)
  "Return T when DATA carries a guild id, so it did not come from a direct
message whatever its channel type says."
  (let ((guild (and (consp data) (getf data :guild_id))))
    (and guild (not (null guild)))))

(declaim (ftype (function (t) boolean) bot-author-p))

(defun bot-author-p (data)
  "Return T when the author of DATA is a bot. Two bots answering each other is
a loop that costs tokens and never ends."
  (let ((author (and (consp data) (getf data :author))))
    (and (consp author) (not (null (getf author :bot))))))

(declaim (ftype (function (t t) boolean) own-author-p))

(defun own-author-p (data self-id)
  "Return T when DATA was sent by SELF-ID, the agent's own user id.

SELF-ID is NIL before Ready says who the agent is, and nothing is the agent's
own before then."
  (let ((author (author-id data)))
    (and (non-blank-string self-id)
         (non-blank-string author)
         (string= author self-id))))

(declaim (ftype (function (t t) boolean) inkbound-p))

(defun inkbound-p (data self-id)
  "Return T when DATA is a direct message from someone other than the agent.

The four rules are separate functions because each one is a sentence the
operator can read, and this is the sentence they make together. This is the
whole authorisation story for a channel that only answers direct messages."
  (and (direct-message-p data)
       (not (guild-event-p data))
       (not (bot-author-p data))
       (not (own-author-p data self-id))))

(declaim (ftype (function (t) boolean) message-create-p))

(defun message-create-p (frame)
  "Return T when FRAME is a MESSAGE_CREATE dispatch. Every other event is
dropped: MESSAGE_CREATE is the only one a direct message channel has."
  (and (eql +op-dispatch+ (frame-op frame))
       (let ((type (getf frame :t)))
         (and (stringp type) (string= "MESSAGE_CREATE" type)))))

(declaim (ftype (function (t) boolean) ready-p))

(defun ready-p (frame)
  "Return T when FRAME is the READY dispatch, which says who the agent is and
which session this socket belongs to."
  (and (eql +op-dispatch+ (frame-op frame))
       (let ((type (getf frame :t)))
         (and (stringp type) (string= "READY" type)))))

(declaim (ftype (function (t) list) message-fields))

(defun message-fields (data)
  "Return DATA, a MESSAGE_CREATE payload, as the plist NORMALIZE takes.

TARGET is the event's channel id, which is where a reply goes: a direct
message's channel is the conversation, so there is nothing else to look up.
The timestamp is left to NORMALIZE, because the gateway's is an ISO 8601
string and the message shape carries a number."
  (list :channel :fluxer
        :id (text-field data :id)
        :author (or (author-id data) "")
        :target (text-field data :channel_id)
        :text (text-field data :content)))

(declaim (ftype (function (t) t) message-create->msg))

(defun message-create->msg (data)
  "Return DATA, a MESSAGE_CREATE payload, as the one message shape every
channel normalizes into. The id is the gateway's own message id, so a
transcript line and the message it names are the same object."
  (enchiridion.channel:normalize (message-fields data)))

(declaim (ftype (function (t t) t) advance-sequence))

(defun advance-sequence (last incoming)
  "Return the new last-processed sequence and whether INCOMING is new work.

A dispatch is dropped when its sequence is not greater than the last one
processed, because a replay keeps its old number and a resume replays what was
already answered. A frame with no sequence number is accepted and leaves the
count alone: it carries no evidence that it is a replay, and the sequence is
the only place a replay is visible."
  (cond
    ((not (integerp incoming)) (values last t))
    ((and (integerp last) (<= incoming last)) (values last nil))
    (t (values incoming t))))

;;;; Cutting a reply into messages.

(declaim (ftype (function (character) boolean) whitespace-character-p))

(defun whitespace-character-p (character)
  "Return T when CHARACTER is whitespace a message can be cut at."
  (not (null (member character '(#\Space #\Tab #\Newline #\Return #\Page)
                      :test #'char=))))

(declaim (ftype (function (string integer) list) chunk-text))

(defun chunk-text (text limit)
  "Return TEXT as pieces of at most LIMIT characters, cutting on whitespace.

Each piece is a slice of TEXT rather than a reflow of it, so a reply keeps its
line breaks and its indentation. The cut consumes the run of whitespace at the
seam, so no piece begins with whitespace, and text that is only whitespace
gives no pieces at all. A single word longer than LIMIT is the one thing cut
mid word, because there is nowhere else to cut it."
  (let ((length (length text))
        (limit (max 1 limit))
        (start 0)
        (pieces '()))
    (loop
      (loop while (and (< start length)
                       (whitespace-character-p (char text start)))
            do (incf start))
      (when (>= start length)
        (return))
      (let ((end (min length (+ start limit))))
        (if (>= end length)
            (progn (push (subseq text start end) pieces)
                   (setf start length))
            (let ((cut (position-if #'whitespace-character-p text
                                    :start start :end end :from-end t)))
              (if (and cut (> cut start))
                  (progn (push (subseq text start cut) pieces)
                         (setf start cut))
                  ;; No whitespace in the window, so the word itself is longer
                  ;; than one message and has to be cut.
                  (progn (push (subseq text start end) pieces)
                         (setf start end)))))))
    (nreverse pieces)))

(declaim (ftype (function (t integer) list) outbound-chunks))

(defun outbound-chunks (text limit)
  "Return TEXT scrubbed, as the pieces a reply is sent in, or NIL.

This is the last place a reply is ours before it becomes a REST body, so it is
where the scrubber runs. A reply that is empty after scrubbing is not sent: the
operator reads an empty message as being ignored, and the gateway refuses it
anyway."
  (let ((clean (enchiridion.llm.secrets:scrub text)))
    (if (stringp clean)
        (chunk-text clean limit)
        nil)))

;;;; Waiting between attempts.

(declaim (ftype (function (integer) real) next-backoff))

(defun next-backoff (attempt)
  "Return how many seconds to wait before reconnect attempt number ATTEMPT.

The wait doubles from +RECONNECT-BASE-SECONDS+ and stops at
+RECONNECT-MAX-SECONDS+, so a gateway that is down is retried without a busy
loop and a gateway that is up is rejoined quickly."
  (min +reconnect-max-seconds+
       (* +reconnect-base-seconds+ (expt 2 (max 0 (1- attempt))))))

(declaim (ftype (function (integer integer) integer) next-attempt))

(defun next-attempt (attempt connection-seconds)
  "Return the reconnect attempt number after a connection that lasted
CONNECTION-SECONDS, where ATTEMPT is the number that connection was tried on.

A connection that lasted +RECONNECT-STABLE-SECONDS+ proved the transport works,
so the count starts again at one. Anything shorter is one more attempt on the
same budget, which stops a gateway that accepts a socket and closes it at once
from being retried once a second forever."
  (if (>= connection-seconds +reconnect-stable-seconds+)
      1
      (1+ attempt)))

(declaim (ftype (function (t) (or null real)) retry-after-seconds))

(defun retry-after-seconds (body)
  "Return the wait a 429 body asks for, in seconds, or NIL.

The gateway puts retry_after in the body and not in a header, and it is a
fractional number of seconds. A body that is not JSON, or JSON without the
field, is NIL: the caller then waits its own backoff instead of guessing."
  (handler-case
      (let ((data (enchiridion.llm:parse-json body)))
        (when (consp data)
          (let ((value (getf data :retry_after)))
            (when (and (realp value) (not (minusp value)))
              value))))
    (error () nil)))

(declaim (ftype (function (t t) boolean) resume-window-open-p))

(defun resume-window-open-p (ended now)
  "Return T when a session that ended at ENDED can still be resumed at NOW.
Both are universal times, and the gateway keeps a session for
+RESUME-WINDOW-SECONDS+ after a transport ends."
  (and (integerp ended)
       (integerp now)
       (<= (- now ended) +resume-window-seconds+)))

;;;; Finding the token.

(declaim (ftype (function () string) configured-token-env))

(defun configured-token-env ()
  "Return the environment variable name the :FLUXER configuration names."
  (or (non-blank-string (enchiridion:channel-value :fluxer :token-env))
      +token-env-default+))

(declaim (ftype (function (string) (or null string)) environment-token))

(defun environment-token (name)
  "Return the environment variable NAME as a token, registering it first, or
NIL.

The loader registers what it reads and then unsets the variable, so this is the
fallback for a process that exported it after the loader ran. It registers with
the scrubber before it returns, because a token the scrubber has never seen is
a token that can reach a transcript."
  (let ((token (non-blank-string (enchiridion.compat:environment-value name))))
    (when token
      (enchiridion.llm.secrets:register-secret name token :env)
      token)))

(declaim (ftype (function (&key (:name t)) (or null string)) resolve-token))

(defun resolve-token (&key name)
  "Return the Fluxer bot token, or NIL.

NAME defaults to the name the :FLUXER configuration carries in :TOKEN-ENV. The
loaded secret is asked first, because the loader registers the token and unsets
the environment variable, and a token that is still in the environment is a
token a child process would inherit.

A value that is missing, empty, or only whitespace is no token at all. The
caller says so in one line before any socket opens rather than signalling: a
mis-set variable is a fact the operator can see in the log, and a channel that
signals it takes a supervisor down over a typo."
  (let ((name (or (non-blank-string name) (configured-token-env))))
    (or (non-blank-string (enchiridion.llm.secrets:secret-value name))
        (environment-token name))))

;;;; The socket.

(defclass fluxer-socket (websocket-driver.ws.client:client)
  ((close-code :accessor fluxer-socket-close-code :initform nil :type t
               :documentation "The code the peer closed with, captured while
the close frame was still bytes rather than after the library dropped it.")
   (closed-p :accessor fluxer-socket-closed-p :initform nil :type boolean
             :documentation "True once the close event has been noted. The
library can fire :close twice for one close, so this is what makes the handler
idempotent.")
   (hello :accessor fluxer-socket-hello
          :initform (bordeaux-threads:make-semaphore :name "fluxer hello")
          :type t
          :documentation "Signalled when Hello arrives, so the thread that
waits for it is not a poll loop.")
   (done :accessor fluxer-socket-done
         :initform (bordeaux-threads:make-semaphore :name "fluxer done")
         :type t
         :documentation "Signalled when the socket is finished, so the
heartbeat loop wakes on a close instead of on its next slice.")
   (heartbeat-interval :accessor fluxer-socket-heartbeat-interval :initform nil
                       :type t
                       :documentation "The interval Hello named, in
milliseconds.")
   (last-ack :accessor fluxer-socket-last-ack :initform nil :type t
             :documentation "A universal time, for the last heartbeat the
gateway acknowledged.")
   (state-lock :accessor fluxer-socket-state-lock
               :initform (bordeaux-threads:make-lock "fluxer socket")
               :type t
               :documentation "Guards the two facts the read thread writes and
another thread reads."))
  (:documentation
   "The gateway socket, with the facts this channel needs and one method the
library leaves out. The subclass exists for the close code: the library's close
callback consumes the code and the :close event that follows carries NIL, so
the frame has to be read while it is still a frame."))

(defmethod websocket-driver.ws.base:parse :around ((socket fluxer-socket)
                                                   data &key start end)
  "Note the close code in DATA before the library discards it.

The next method runs either way: this one only looks at the frame first."
  (let ((code (frame-close-code data start end)))
    (when code
      (bordeaux-threads:with-lock-held ((fluxer-socket-state-lock socket))
        (setf (fluxer-socket-close-code socket) code))))
  (call-next-method))

;;;; The channel.

(defclass fluxer-channel (enchiridion.channel:channel)
  ((turn :accessor fluxer-channel-turn :initarg :turn :initform nil :type t
         :documentation "The function one inkbound message is handed to. It is
injected and never reached through the kernel, which is what lets the whole
channel be tested with a closure.")
   (config :accessor fluxer-channel-config :initarg :config :initform nil
           :type t
           :documentation "The :FLUXER options, or a whole configuration that
carries them. NIL means the active configuration.")
   (token :accessor fluxer-channel-token :initform nil :type t
          :documentation "The bot token, resolved once at start. It is never
printed and never logged.")
   (socket :accessor fluxer-channel-socket :initform nil :type t
           :documentation "The live gateway socket, or NIL.")
   (send-lock :accessor fluxer-channel-send-lock
              :initform (bordeaux-threads:make-lock "fluxer send")
              :type t
              :documentation "Serialises websocket writes. The library's send
is not locked, and two interleaved frames on one socket are one corrupt frame
that closes 4002.")
   (pending :accessor fluxer-channel-pending :initform nil :type list
            :documentation "Inkbound payloads waiting for the worker, oldest
first.")
   (pending-lock :accessor fluxer-channel-pending-lock
                 :initform (bordeaux-threads:make-lock "fluxer pending")
                 :type t
                 :documentation "Guards the queue, which the read thread
writes and the worker drains.")
   (pending-ready :accessor fluxer-channel-pending-ready
                  :initform (bordeaux-threads:make-semaphore
                             :name "fluxer pending")
                  :type t
                  :documentation "Counts the payloads waiting, so the worker
sleeps rather than polls.")
   (worker :accessor fluxer-channel-worker :initform nil :type t
           :documentation "The one thread that runs turns.")
   (stopping-p :accessor fluxer-channel-stopping-p :initform nil :type boolean
               :documentation "True once a stop has been asked for. Every loop
in this file reads it.")
   (sequence :accessor fluxer-channel-sequence :initform nil :type t
             :documentation "The last processed dispatch sequence, or NIL
before the first dispatch. A heartbeat reports it.")
   (self-id :accessor fluxer-channel-self-id :initform nil :type t
            :documentation "The agent's own user id, from READY. What the echo
guard compares against.")
   (session-id :accessor fluxer-channel-session-id :initform nil :type t
               :documentation "The session id READY named, for a resume.")
   (session-ended :accessor fluxer-channel-session-ended :initform nil :type t
                  :documentation "When the last transport ended, as a
universal time. The resume window is counted from it.")
   (attempt :accessor fluxer-channel-attempt :initform 0 :type integer
            :documentation "Reconnects since the last connection that stayed
up. NEXT-ATTEMPT decides which connections earn a fresh budget.")
   (status-text :accessor fluxer-channel-status-text :initform nil :type t
                :documentation "The live custom status text, or NIL. It is
never read from a reply or from reasoning: only an explicit proposal sets it.")
   (status-expires :accessor fluxer-channel-status-expires :initform nil :type t
                   :documentation "When the live custom status stops being
current, as a universal time, or NIL.")
   (status-changed :accessor fluxer-channel-status-changed :initform nil :type t
                   :documentation "When the last accepted status change was
proposed, as a universal time. The cooldown is counted from it.")
   (status-lock :accessor fluxer-channel-status-lock
                :initform (bordeaux-threads:make-lock "fluxer status")
                :type t
                :documentation "Guards the status state. The worker proposes,
the read thread reapplies on READY, and the heartbeat thread expires it.")
   (dropped :accessor fluxer-channel-dropped :initform 0 :type integer
            :documentation "How many messages a full queue has dropped.")
   (reaction-pending :accessor fluxer-channel-reaction-pending
                     :initform (make-hash-table :test #'equal) :type hash-table
                     :documentation "The newest reaction state waiting for each
message, keyed by \"channel/message\". A newer state for a message already here
replaces it.")
   (reaction-order :accessor fluxer-channel-reaction-order :initform nil :type list
                   :documentation "The keys in REACTION-PENDING, oldest first.
The queue is bounded by +MAX-PENDING-REACTIONS+.")
   (reaction-lock :accessor fluxer-channel-reaction-lock
                  :initform (bordeaux-threads:make-lock "fluxer reactions")
                  :type t
                  :documentation "Guards the reaction queue, which the socket's
read thread and the turn worker write and the reaction thread drains.")
   (reaction-ready :accessor fluxer-channel-reaction-ready
                   :initform (bordeaux-threads:make-semaphore
                              :name "fluxer reactions")
                   :type t
                   :documentation "Counts the messages waiting, so the reaction
thread sleeps rather than polls.")
   (reaction-worker :accessor fluxer-channel-reaction-worker :initform nil :type t
                    :documentation "The one thread that sends reactions, or NIL.")
   (reaction-stopping-p :accessor fluxer-channel-reaction-stopping-p
                        :initform nil :type boolean
                        :documentation "True once the reaction thread has been
asked to drain and finish. Separate from STOPPING-P, because the reaction thread
outlives the socket and the worker by one drain.")
   (reaction-deadline :accessor fluxer-channel-reaction-deadline :initform nil
                      :type t
                      :documentation "When a stop's drain gives up, as a real
time from REAL-SECONDS, or NIL outside a stop.")
   (reaction-applied :accessor fluxer-channel-reaction-applied
                     :initform (make-hash-table :test #'equal) :type hash-table
                     :documentation "The marker the bot last put on each
message, so a state that was coalesced away never causes a delete.")
   (reaction-applied-order :accessor fluxer-channel-reaction-applied-order
                           :initform nil :type list
                           :documentation "The keys in REACTION-APPLIED, oldest
first, so the table can evict at +REACTION-TRACKED-LIMIT+.")
   (active-reaction :accessor fluxer-channel-active-reaction :initform nil
                    :type t
                    :documentation "The message key the turn worker is inside,
so a stop that has to destroy the thread can mark it failed."))
  (:documentation
   "The Fluxer direct-message channel. One worker thread runs every turn, so a
slow turn queues instead of starving the socket, and the library's read thread
only ever parses a frame and hands it on."))

(declaim (ftype (function (&key (:turn t) (:config t))
                           (values fluxer-channel &rest t))
                make-fluxer-channel))

(defun make-fluxer-channel (&key turn config)
  "Return a stopped Fluxer channel that calls TURN for every inkbound message.

TURN is (lambda (msg) ...) and returns a plist (:ok-p BOOL :reply STRING :error
STRING :usage PLIST-OR-NIL :status PROPOSAL). STATUS is the agent's deliberate
custom status proposal, a string or :CLEAR, and is ignored unless the :FLUXER
options set :CUSTOM-STATUS. It travels beside the reply, not inside it: the
channel validates, rate limits, and expires it, and a refusal never costs the
reply. It is the only way this channel reaches an agent: the channel never
calls the kernel, so a test hands it a closure and a supervisor hands it the
agent's turn. CONFIG is the :FLUXER options, or a whole configuration that
carries them; NIL means whatever is active."
  (make-instance 'fluxer-channel :name "fluxer" :turn turn :config config))

;;;; What the configuration says.

(declaim (ftype (function (fluxer-channel) list) channel-options))

(defun channel-options (channel)
  "Return the :FLUXER options CHANNEL was made with.

The channel's own CONFIG wins when it has one: a section plist is merged over
the active configuration key by key, and a whole configuration is asked for
its :CHANNELS section. NIL means the active configuration, which is what a
supervisor passes.

The merge matters: a section that names only :ENABLED must keep the operator's
allowlist rather than replacing it with nothing, because a channel that
silently denies everybody looks exactly like a channel with no traffic."
  (let ((config (fluxer-channel-config channel)))
    (cond
      ((null config) (enchiridion:channel-config :fluxer))
      ((getf config :channels) (enchiridion:channel-config :fluxer config))
      (t (let ((options (enchiridion:channel-config :fluxer)))
           (loop for (key value) on config by #'cddr
                 do (setf (getf options key) value))
           options)))))

(declaim (ftype (function (fluxer-channel) list) channel-allowlist))

(defun channel-allowlist (channel)
  "Return the user ids the :FLUXER options allow. NIL means nobody.

Anything that is not a list of ids is no allowlist: a single id written as a
string, or a symbol where a string was meant, denies everybody rather than
admitting somebody the operator did not name."
  (let ((allowlist (getf (channel-options channel) :allowed-users)))
    (if (listp allowlist) allowlist nil)))

(declaim (ftype (function (fluxer-channel) string) channel-token-env))

(defun channel-token-env (channel)
  "Return the environment variable name the :FLUXER options name for the
token, or the default when they name none."
  (or (non-blank-string (getf (channel-options channel) :token-env))
      +token-env-default+))

(declaim (ftype (function (fluxer-channel) boolean) channel-custom-status-p))

(defun channel-custom-status-p (channel)
  "Return T when the :FLUXER options opt in to an agent-authored custom status.

The default is off. A public status is a new way for the agent to be seen, and
an operator who did not ask for one should never discover it is on."
  (not (null (getf (channel-options channel) :custom-status))))

(declaim (ftype (function (fluxer-channel) (or null string))
                custom-status-operator))

(defun custom-status-operator (channel)
  "Return the user id whose turns may set CHANNEL's public status, or NIL.

An explicit :CUSTOM-STATUS-USER wins, but only when that id is one the
allowlist admits. Without one, a single allowed user is the operator, because
that is the one person the channel was set up to talk to. Several allowed users
and no explicit id is ambiguous, so nobody may steer the public status: being
allowed to send the agent a direct message is not permission to speak for it."
  (let ((configured (non-blank-string
                     (getf (channel-options channel) :custom-status-user)))
        (allowed (channel-allowlist channel)))
    (if configured
        (and (allowed-p allowed configured) configured)
        (let ((ids (remove-duplicates (remove-if-not #'stringp allowed)
                                      :test #'string=)))
          (and (= 1 (length ids)) (first ids))))))

(declaim (ftype (function (fluxer-channel t) boolean) custom-status-author-p))

(defun custom-status-author-p (channel author)
  "Return T when AUTHOR's turn may set CHANNEL's public status."
  (let ((operator (custom-status-operator channel)))
    (and operator
         (non-blank-string author)
         (string= operator author))))

(declaim (ftype (function (keyword) (or null integer)) shipped-status-seconds))

(defun shipped-status-seconds (key)
  "Return KEY from the shipped :FLUXER entry, or NIL when it names none."
  (getf (enchiridion:channel-config :fluxer (enchiridion:default-config)) key))

(declaim (ftype (function (fluxer-channel keyword integer integer) integer)
                status-seconds))

(defun status-seconds (channel key minimum maximum)
  "Return KEY from CHANNEL's options as seconds, or the shipped value.

A value that is not an integer, or that falls outside MINIMUM..MAXIMUM, is the
shipped default. The bounds are what keep one typo from pinning a status for a
day or letting the cooldown disappear without the operator saying so."
  (let ((value (getf (channel-options channel) key)))
    (if (and (integerp value) (<= minimum value maximum))
        value
        (shipped-status-seconds key))))

(declaim (ftype (function (fluxer-channel) integer) channel-custom-status-ttl))

(defun channel-custom-status-ttl (channel)
  "Return how many seconds a custom status stays live on CHANNEL."
  (status-seconds channel :custom-status-ttl-seconds
                  1 +custom-status-max-ttl-seconds+))

(declaim (ftype (function (fluxer-channel) integer)
                channel-custom-status-cooldown))

(defun channel-custom-status-cooldown (channel)
  "Return the cooldown between accepted custom status changes on CHANNEL."
  (status-seconds channel :custom-status-cooldown-seconds
                  0 +custom-status-max-cooldown-seconds+))

;;;; Saying what happened.

(defparameter *log-lock* (bordeaux-threads:make-lock "fluxer log")
  "Serialises the one line this channel writes at a time. Three threads write
here, and two lines interleaved on one stream are two lines nobody can read.")

(declaim (ftype (function (t integer) string) short-text))

(defun short-text (text limit)
  "Return TEXT as one line of at most LIMIT characters, for a log line.

A frame that is not JSON, and a service's error body, can both be any length.
A log line longer than a screen buries the line that matters, so it is cut
here rather than left to the terminal to wrap."
  (let* ((line (if (stringp text) text (format nil "~S" text)))
         (end (or (position #\Newline line) (length line))))
    (if (< end limit)
        (if (= end (length line))
            line
            (subseq line 0 end))
        (concatenate 'string (subseq line 0 limit) "..."))))

(declaim (ftype (function (string &rest t) null) note))

(defun note (control &rest arguments)
  "Write one scrubbed line about this channel to the error stream and return
NIL.

Scrubbed, because the things worth logging here are the things that came from
the other end of a socket: a gateway's reason string and a condition a turn
signalled are both text this process did not write."
  (let* ((text (apply #'format nil control arguments))
         ;; One line, whatever arrived: a gateway's reason string and a
         ;; service's error body both reach this function, and a newline in
         ;; either one would let the far end write a second log line.
         (flat (substitute #\Space #\Newline
                           (substitute #\Space #\Return
                                       (substitute #\Space #\Tab text))))
         (line (enchiridion.llm.secrets:scrub flat)))
    (bordeaux-threads:with-lock-held (*log-lock*)
      (format *error-output* "~&enchiridion fluxer: ~A~%" line)
      (finish-output *error-output*)))
  nil)

(declaim (ftype (function (t) string) error-note))

(defun error-note (payload)
  "Return a short, scrubbed note from PAYLOAD, a service error body."
  (let ((text (handler-case
                  (let ((data (enchiridion.llm:parse-json payload)))
                    (or (and (consp data) (non-blank-string (getf data :message)))
                        (and (consp data) (non-blank-string (getf data :error)))))
                (error () nil))))
    (let* ((line (or text (and (stringp payload) payload) ""))
           (end (or (position #\Newline line) (length line)))
           (cut (min end 200))
           (flat (subseq line 0 cut)))
      (enchiridion.llm.secrets:scrub
       (if (< cut end)
           (concatenate 'string flat "...")
           flat)))))

;;;; Clocks and threads.

(declaim (ftype (function () real) real-seconds))

(defun real-seconds ()
  "Return a monotonic clock in seconds, for the heartbeat and the backoff.

GET-UNIVERSAL-TIME has one second resolution, which is too coarse to send a
heartbeat on time or to measure a backoff that starts at one second."
  (/ (get-internal-real-time) internal-time-units-per-second))

(declaim (ftype (function (t t integer) boolean) heartbeat-ack-overdue-p))

(defun heartbeat-ack-overdue-p (sent acked now)
  "Return T when the heartbeat sent at SENT was still unacknowledged at NOW.

SENT and NOW are universal times, and ACKED is the last acknowledgement the
gateway sent, or NIL when it has sent none; an ACKED older than SENT answers for
an earlier beat. The gateway answers every beat it receives, so a window with no
answer means the frames are not arriving."
  (and (integerp sent)
       (integerp now)
       (> (- now sent) +heartbeat-ack-timeout-seconds+)
       (or (not (integerp acked))
           (< acked sent))))

(declaim (ftype (function (integer integer &optional t) real) heartbeat-delay))

(defun heartbeat-delay (beat interval &optional jitter)
  "Return the seconds to wait before heartbeat number BEAT, where INTERVAL is
the gateway's interval in milliseconds and BEAT counts the beats sent.

The first heartbeat waits a random part of one interval, so a fleet of clients
that reconnected together does not arrive together; every later heartbeat waits
one whole interval. JITTER replaces the random choice, so a test names the
number instead of accepting whatever the dice said."
  (let ((interval (max 1 interval)))
    (if (plusp beat)
        (/ interval 1000)
        (/ (or jitter (random interval)) 1000))))

(declaim (ftype (function (t real) boolean) join-thread-bounded))

(defun join-thread-bounded (thread seconds)
  "Wait up to SECONDS for THREAD to finish, then destroy it.

Return T when the thread had to be destroyed and NIL when it ended on its own.
A plain join on a worker that is inside a model call is a stop that never
finishes, and the deadline is what makes a stop a stop. The answer matters to
the caller because a destroyed turn reached no terminal state."
  (let ((destroyed nil))
    (when (and thread (bordeaux-threads:thread-alive-p thread))
      (let ((deadline (+ (real-seconds) seconds)))
        (loop while (and (bordeaux-threads:thread-alive-p thread)
                         (< (real-seconds) deadline))
              do (sleep 0.05))
        (when (bordeaux-threads:thread-alive-p thread)
          (ignore-errors (bordeaux-threads:destroy-thread thread))
          (setf destroyed t))))
    destroyed))

;;;; The socket's own small operations.

(declaim (ftype (function (t) null) close-socket))

(defun close-socket (socket)
  "Close SOCKET and return NIL. An already closed socket is left alone.

CLOSE-CONNECTION emits :close, and the handler below is idempotent, so a close
from here and a close from the read thread settle to one state and one log
line."
  (when socket
    (ignore-errors (websocket-driver:close-connection socket)))
  nil)

(declaim (ftype (function (fluxer-socket t) null) note-socket-closed))

(defun note-socket-closed (socket code)
  "Note that SOCKET is finished, once, and wake everyone waiting on it.

The library can fire :close twice for one close, so a second call does nothing:
the code is kept, and the semaphores keep one wake-up per socket. Hello is
signalled too, because a socket that closed will never send one and the thread
waiting for it would otherwise wait out its whole timeout."
  (bordeaux-threads:with-lock-held ((fluxer-socket-state-lock socket))
    (unless (fluxer-socket-closed-p socket)
      (setf (fluxer-socket-closed-p socket) t)
      (when (and code (null (fluxer-socket-close-code socket)))
        (setf (fluxer-socket-close-code socket) code))))
  (bordeaux-threads:signal-semaphore (fluxer-socket-done socket))
  (bordeaux-threads:signal-semaphore (fluxer-socket-hello socket))
  nil)

(declaim (ftype (function (fluxer-socket integer) boolean) wait-for-hello))

(defun wait-for-hello (socket seconds)
  "Wait up to SECONDS for the gateway's Hello. Return T when it arrived, or
when the socket closed, which the caller tells apart with CLOSED-P."
  (and (bordeaux-threads:wait-on-semaphore (fluxer-socket-hello socket)
                                           :timeout seconds)
       t))

(declaim (ftype (function (fluxer-socket real) null) wait-for-close))

(defun wait-for-close (socket seconds)
  "Wait up to SECONDS for SOCKET to close, or for the wait to time out."
  (bordeaux-threads:wait-on-semaphore (fluxer-socket-done socket)
                                      :timeout (max 0.05 seconds))
  nil)

(declaim (ftype (function (fluxer-channel fluxer-socket t) string) send-frame))

(defun send-frame (channel socket frame)
  "Write FRAME, a plist, to SOCKET as one JSON text frame and return the text.

The lock is not decoration. The library's send is unlocked, so a heartbeat from
this thread racing a reply from the worker interleaves two frames on one socket,
and the gateway reads that as one corrupt frame and closes 4002."
  (let ((text (json-text frame)))
    (bordeaux-threads:with-lock-held ((fluxer-channel-send-lock channel))
      (websocket-driver:send socket text))
    text))

;;;; The custom status, from proposal to frame.
;;;;
;;;; The state is three facts and a lock. A proposal is either applied or
;;;; refused, and the reason is part of the answer so a caller can log one line
;;;; and a test can name the rule. Nothing here signals: a refused status must
;;;; never cost the reply that was proposed beside it.

(declaim (ftype (function (fluxer-channel &optional integer) boolean)
                custom-status-live-p))

(defun custom-status-live-p (channel &optional (now (get-universal-time)))
  "Return T when CHANNEL holds a custom status that has not expired at NOW.

The caller holds the status lock, or accepts a snapshot. Expiry is strict: a
status that ends at NOW is over, not one second more."
  (let ((text (fluxer-channel-status-text channel))
        (expires (fluxer-channel-status-expires channel)))
    (and (stringp text)
         (plusp (length text))
         (integerp expires)
         (< now expires))))

(declaim (ftype (function (fluxer-channel (or null string)) (or null string))
                send-presence))

(defun send-presence (channel text)
  "Send one op 3 frame setting TEXT, or clearing when TEXT is NIL.

Return the frame text, or NIL when the channel has no socket to write to. A
status proposed between connections is kept and reapplied on the next READY,
so a missing socket is not a lost status."
  (let ((socket (fluxer-channel-socket channel)))
    (when socket
      (send-frame channel socket (presence-frame text)))))

(declaim (ftype (function (fluxer-channel t integer) list)
                apply-status-proposal))

(defun apply-status-proposal (channel proposal now)
  "Apply PROPOSAL, a validated text or :CLEAR, at NOW under the status lock.
Return the decision plist.

The lock is held across the write so two proposals cannot invert their frames
on the wire. The frame write itself is short; a socket that blocks is the same
socket the heartbeat is already writing to."
  (let ((outcome nil) (reason nil) (frame-p nil) (frame-text nil))
    (bordeaux-threads:with-lock-held ((fluxer-channel-status-lock channel))
      (let ((cooldown (channel-custom-status-cooldown channel))
            (live (custom-status-live-p channel now))
            (changed (fluxer-channel-status-changed channel)))
        ;; An expired status is already over. Forget it before the decision so
        ;; a clear after the deadline is a no-op and a new text does not
        ;; deduplicate against one nobody is showing.
        (when (and (fluxer-channel-status-text channel) (not live))
          (setf (fluxer-channel-status-text channel) nil
                (fluxer-channel-status-expires channel) nil))
        (cond
          ((eq proposal :clear)
           (cond
             ((not live)
              (setf outcome :unchanged))
             ((and (integerp changed)
                   (< (- now changed) cooldown))
              (setf outcome :refused
                    reason (format nil "the cooldown has ~D seconds left."
                                   (- cooldown (- now changed)))))
             (t
              (setf (fluxer-channel-status-text channel) nil
                    (fluxer-channel-status-expires channel) nil
                    (fluxer-channel-status-changed channel) now
                    outcome :cleared
                    frame-p t
                    frame-text nil))))
          ((and live
                (string= proposal (fluxer-channel-status-text channel)))
           (setf outcome :unchanged))
          ((and (integerp changed)
                (< (- now changed) cooldown))
           (setf outcome :refused
                 reason (format nil "the cooldown has ~D seconds left."
                                (- cooldown (- now changed)))))
          (t
           (setf (fluxer-channel-status-text channel) proposal
                 (fluxer-channel-status-expires channel)
                 (+ now (channel-custom-status-ttl channel))
                 (fluxer-channel-status-changed channel) now
                 outcome :applied
                 frame-p t
                 frame-text proposal))))
      ;; The lock covers the write as well as the decision, so two proposals
      ;; cannot invert their frames and an expiry cannot clear one that this
      ;; frame is about to republish.
      (when frame-p
        (handler-case
            (let ((sent (send-presence channel frame-text)))
              (unless sent
                (setf reason
                      (if frame-text
                          "no live socket; the status waits for READY."
                          "no live socket; a new session has no status."))))
          (error (condition)
            (setf reason
                  (format nil "the status frame was not sent: ~A" condition))))))
    (cond
      ((eq outcome :applied)
       (note "custom status set: ~A" (short-text frame-text 64)))
      ((eq outcome :cleared)
       (note "custom status cleared."))
      ((eq outcome :refused)
       (note "refused a custom status change: ~A" reason)))
    (list :outcome outcome
          :reason reason
          :sent (and frame-p (null reason)))))

(declaim (ftype (function (fluxer-channel t &key (:now integer)
                                             (:author (or null string)))
                            list)
                propose-custom-status))

(defun propose-custom-status (channel proposal &key (now (get-universal-time))
                                                author)
  "Propose PROPOSAL as the agent's temporary public custom status.

PROPOSAL is a string to set, :CLEAR to remove it, or NIL for no proposal.
AUTHOR names the sender whose turn made the proposal. When it is supplied, only
the operator may set or clear the status, so one allowlisted friend cannot
speak for the agent. An in-process caller omits AUTHOR and is the operator.

Return a decision plist (:outcome OUTCOME :reason TEXT-OR-NIL :sent BOOL).
OUTCOME is :disabled, :unchanged, :refused, :applied, or :cleared. A frame
error leaves the outcome and reports the error in :reason: the status is
recorded and a later READY can apply it.

The proposal is the agent's own deliberate text. This function never reads a
reply, a transcript, or reasoning, so nothing private becomes public by
accident. Validation, the cooldown, deduplication, and expiry all live here
rather than in the agent, because the channel is the last place before a frame
leaves the process."
  (cond
    ((null proposal)
     (list :outcome :unchanged :reason nil :sent nil))
    ((not (channel-custom-status-p channel))
     (list :outcome :disabled
           :reason "the Fluxer channel is not opted in to a custom status."
           :sent nil))
    ((and author (not (custom-status-author-p channel author)))
     (let ((reason (format nil "~A may not set the custom status." author)))
       (note "refused a custom status from ~A: not the operator." author)
       (list :outcome :refused :reason reason :sent nil)))
    ((eq proposal :clear)
     (apply-status-proposal channel :clear now))
    (t
     (multiple-value-bind (text reason)
         (validate-custom-status proposal)
       (if text
           (apply-status-proposal channel text now)
           (progn
             (note "refused a custom status proposal: ~A" reason)
             (list :outcome :refused :reason reason :sent nil)))))))

(declaim (ftype (function (fluxer-channel &key (:now integer)) list)
                expire-custom-status))

(defun expire-custom-status (channel &key (now (get-universal-time)))
  "Clear CHANNEL's custom status when it has expired at NOW, and return the
decision.

The clear goes out on the socket this connection recorded. A status that
expires while the channel is disconnected is simply forgotten: a new session
starts with no custom status, and REAPPLY-CUSTOM-STATUS does not send one that
is already over."
  (let ((expired nil) (sent nil) (reason nil))
    (bordeaux-threads:with-lock-held ((fluxer-channel-status-lock channel))
      (when (and (stringp (fluxer-channel-status-text channel))
                 (integerp (fluxer-channel-status-expires channel))
                 (>= now (fluxer-channel-status-expires channel)))
        (setf (fluxer-channel-status-text channel) nil
              (fluxer-channel-status-expires channel) nil
              expired t)
        (handler-case
            (let ((socket (fluxer-channel-socket channel)))
              (when socket
                (send-frame channel socket (presence-frame nil))
                (setf sent t)))
          (error (condition)
            (setf reason (format nil "the expiry clear could not be sent: ~A"
                                 condition))))))
    (when expired
      (if reason
          (note "the custom status expired, but the clear could not be sent: ~A"
                reason)
          (note "the custom status expired.")))
    (if expired
        (list :outcome :expired :reason reason :sent sent)
        (list :outcome :unchanged :reason nil :sent nil))))

(declaim (ftype (function (fluxer-channel &key (:now integer)) list)
                reapply-custom-status))

(defun reapply-custom-status (channel &key (now (get-universal-time)))
  "Reapply a still-current custom status on a new session.

A READY follows an Identify, so the session that just began does not carry the
old presence. A status whose lifetime is over is forgotten here instead of
being published again, and an unchanged status is not resent: a reconnect is
not a new proposal and must not restart the cooldown."
  (let ((outcome nil) (sent nil) (reason nil) (expired nil) (disabled nil))
    (bordeaux-threads:with-lock-held ((fluxer-channel-status-lock channel))
      (let ((text (fluxer-channel-status-text channel)))
        (cond
          ((not (channel-custom-status-p channel))
           (when text
             (setf (fluxer-channel-status-text channel) nil
                   (fluxer-channel-status-expires channel) nil
                   disabled t))
           (setf outcome :disabled))
          ((null text) (setf outcome :unchanged))
          ((custom-status-live-p channel now)
           ;; The lock covers the write so an expiry cannot clear the status
           ;; between this decision and the frame that republishes it.
           (handler-case
               (if (send-presence channel text)
                   (setf outcome :reapplied sent t)
                   (setf outcome :reapplied
                         reason "the channel has no live socket."))
             (error (condition)
               (setf outcome :failed
                     reason (format nil "the status was not reapplied: ~A"
                                    condition)))))
          (t
           (setf (fluxer-channel-status-text channel) nil
                 (fluxer-channel-status-expires channel) nil
                 expired t
                 outcome :expired)))))
    (cond
      (disabled
       (note "dropped a custom status because the channel is opted out."))
      (expired (note "a custom status expired while disconnected."))
      ((eq outcome :failed)
       (note "the custom status was not reapplied: ~A" reason)))
    (list :outcome outcome :reason reason :sent sent)))

(declaim (ftype (function (fluxer-channel &key (:now integer)) list)
                custom-status))

(defun custom-status (channel &key (now (get-universal-time)))
  "Return what CHANNEL currently has as (:text TEXT :expires TIME :live BOOL)."
  (bordeaux-threads:with-lock-held ((fluxer-channel-status-lock channel))
    (list :text (fluxer-channel-status-text channel)
          :expires (fluxer-channel-status-expires channel)
          :live (custom-status-live-p channel now))))

(declaim (ftype (function (fluxer-channel fluxer-socket) string)
                send-heartbeat))

(defun send-heartbeat (channel socket)
  "Send one op 1 heartbeat carrying the last processed sequence."
  (send-frame channel socket
              (heartbeat-frame (fluxer-channel-sequence channel))))

(declaim (ftype (function (fluxer-channel) null) note-fresh-session))

(defun note-fresh-session (channel)
  "Forget the session the last transport carried, and its cursor. Return NIL.

A dispatch sequence belongs to one session, and a new session numbers its
dispatches from one again. A cursor kept across an Identify comes from a
numbering that has ended, so the monotonic filter would drop every dispatch of
the new session as a replay: the channel stays connected, heartbeats, and never
answers another message. This is the one place that forgets."
  (setf (fluxer-channel-sequence channel) nil
        (fluxer-channel-session-id channel) nil)
  nil)

(declaim (ftype (function (fluxer-channel fluxer-socket) string) send-identify))

(defun send-identify (channel socket)
  "Send op 2 Identify, the frame that authenticates a fresh session.

The old session's id and cursor go first: identifying abandons them, and
resuming a session this channel has left is answered with op 9."
  (note-fresh-session channel)
  (send-frame channel socket (identify-frame (fluxer-channel-token channel))))

(declaim (ftype (function (fluxer-channel fluxer-socket) string) send-resume))

(defun send-resume (channel socket)
  "Send op 6 Resume for the session this channel already had."
  (send-frame channel socket
              (resume-frame (fluxer-channel-token channel)
                            (fluxer-channel-session-id channel)
                            (fluxer-channel-sequence channel))))

;;;; REST.

(declaim (ftype (function (string) list) bot-headers))

(defun bot-headers (token)
  "Return the headers every authenticated Fluxer call carries.

The scheme is Bot and not Bearer: a Fluxer token is
<applicationId>.<secret> and the service wants the first word to say so. The
token appears here and nowhere else, and never in a query string, which is the
one place a url ends up in a log."
  (list (cons :authorization (format nil "Bot ~A" token))
        (cons :content-type "application/json")
        (cons :user-agent "enchiridion/0.1.0")))

(declaim (ftype (function (string) (or null string)) discover-gateway))

(defun discover-gateway (token)
  "Ask GET /gateway/bot where the websocket is and return its url, or NIL.

A failure is one line and NIL rather than a condition: the caller is a
reconnect loop that has a backoff for exactly this."
  (handler-case
      (let* ((body (enchiridion.llm::bounded-http-request
                     (enchiridion.llm:make-http-request
                      :url (concatenate 'string +rest-base+ +gateway-path+)
                      :headers (bot-headers token) :timeout +http-timeout-seconds+)
                     :method :get :body-limit 65536))
             (data (enchiridion.llm:parse-json body))
             (url (and (consp data) (gateway-url (getf data :url)))))
        (unless url
          (note "GET ~A answered without a usable url." +gateway-path+))
        url)
    (error (condition)
      (note "gateway discovery failed: ~A" condition)
      nil)))

(declaim (ftype (function (t) (or null string)) message-id))

(defun message-id (data)
  "Return the message id in DATA, a message object, or NIL."
  (and (consp data) (non-blank-string (getf data :id))))

(declaim (ftype (function (string string string &optional integer)
                          (or null string))
                post-message))

(defvar *send-channel* nil)
(defvar *send-deadline* nil)
(defparameter +reply-deadline-seconds+ 30)

(defun wait-to-retry (seconds)
  "Wait in stop-aware slices within the reply deadline."
  (let ((end (+ (real-seconds) (min seconds +reply-deadline-seconds+))))
    (loop while (< (real-seconds) end)
          do (when (or (and *send-channel* (fluxer-channel-stopping-p *send-channel*))
                       (and *send-deadline* (>= (real-seconds) *send-deadline*)))
               (error 'enchiridion.errors:transport-error :detail "reply stopped or timed out"))
             (sleep (max 0 (min 0.05 (- end (real-seconds))))))))

(defun post-message (token channel-id text &optional (attempt 0))
  "POST TEXT to CHANNEL-ID as one message and return the new message id, or NIL.

A 429 is repeated after the wait its own body asks for, up to
+RATE-LIMIT-ATTEMPTS+ times, because the route bucket is 20 requests in 10
seconds per user per channel and a long reply is several requests. Everything
else in the 4xx range is reported once: a wrong channel id does not become
right by being repeated."
  (let ((url (concatenate 'string +rest-base+ "/channels/" channel-id
                          "/messages"))
        (body (json-text (message-body text))))
    (handler-case
        (let ((reply (enchiridion.llm::bounded-http-request
                      (enchiridion.llm:make-http-request
                       :url url :headers (bot-headers token) :body body
                       :timeout +http-timeout-seconds+)
                      :body-limit 65536)))
          ;; An unreadable reply is not a failed send: the message was
          ;; accepted, and retrying it would post it twice.
          (message-id (ignore-errors (enchiridion.llm:parse-json reply))))
      (dexador.error:http-request-failed (failure)
        (let ((status (dexador.error:response-status failure))
              (payload (dexador.error:response-body failure)))
          (if (and (eql status 429) (< attempt +rate-limit-attempts+))
              (progn
                (wait-to-retry (or (retry-after-seconds payload)
                                   (next-backoff (1+ attempt))))
                (post-message token channel-id text (1+ attempt)))
              (error 'enchiridion.errors:transport-error
                     :status status
                     :detail (format nil "~D after ~D attempt~:P: ~A"
                                     status
                                     (1+ attempt)
                                     (error-note payload)))))))))

(declaim (ftype (function (fluxer-channel string string) list) send-reply))

(defun send-reply (channel target text)
  "Scrub TEXT, cut it into messages, POST each to TARGET, and return their ids.

An empty list means the scrubber left nothing to send, which is a success: the
reply was empty, so there was nothing to say."
  (let ((ids '())
        (*send-channel* channel)
        (*send-deadline* (+ (real-seconds) +reply-deadline-seconds+)))
    (enchiridion.compat:with-deadline
        (+reply-deadline-seconds+
         :on-timeout (error 'enchiridion.errors:transport-error :detail "reply timed out"))
      (dolist (piece (outbound-chunks text +message-limit+))
        (when (fluxer-channel-stopping-p channel)
          (error 'enchiridion.errors:transport-error :detail "reply stopped"))
        (let ((id (post-message (fluxer-channel-token channel) target piece)))
          (when id (push id ids)))))
    (nreverse ids)))

;;;; The reaction lifecycle.
;;;;
;;;; A direct message carries a marker while it is not answered: an hourglass
;;;; while it waits for the worker, a wrench while its turn runs, and a warning
;;;; when the turn fails, a reply cannot be delivered whole, or the message is
;;;; evicted from the full queue. A delivered reply removes the marker.
;;;;
;;;; The calls are cosmetic and the paths that ask for them are not: the
;;;; gateway's read thread and the turn worker only enqueue and return. One
;;;; more thread owns the queue and every REST call. The queue is keyed by
;;;; message and coalesces, so a state that arrives before the previous one was
;;;; applied replaces it, and a reply delivered inside one round trip never
;;;; flickers.
;;;;
;;;; The queue is bounded, because a channel that accepts messages faster than
;;;; the reaction bucket carries them must not turn that into memory. The
;;;; applied table is bounded too; it only remembers enough messages to skip a
;;;; delete for a reaction that was never added.

(defparameter +queued-reaction+ "⏳"
  "The marker on a direct message that is waiting for the worker.")

(defparameter +processing-reaction+ "🔧"
  "The marker on a direct message whose turn is running.")

(defparameter +failed-reaction+ "⚠️"
  "The marker left on a direct message whose turn or reply failed, and on one
evicted from the full queue.")

(defparameter +reaction-states+ '(:queued :processing :failed :delivered)
  "The states a message is moved through. DELIVERED adds no marker: it clears
the one that is there.")

(defparameter +max-pending-reactions+ 128
  "How many distinct messages may wait for the reaction worker. Coalescing
means one entry per message and not one per change, and the turn queue in front
of the worker holds only 32, so this is headroom rather than a limit a healthy
channel reaches.")

(defparameter +reaction-tracked-limit+ 512
  "How many messages the applied table remembers. Entries for delivered
messages are removed as they clear, and a failed marker stays because no later
state revisits it. The bound is what keeps a long session's failures from
growing the table without end; evicting one costs no request.")

(defparameter +reaction-drain-seconds+ 1
  "How long a stop spends sending the markers it just set.

The markers a stop creates are the ones a person is most likely to be staring
at, so they get a drain of their own, and the abandoned turn's warning is
enqueued first. One second is what a cosmetic marker is worth: the count line
says how many waiting messages were left. The join that follows gives up at
+REACTION-STOP-SECONDS+ either way, so a channel stop stays inside the
supervisor's eight second share next to the turn worker's five.")

(defparameter +reaction-stop-seconds+ 1
  "How long a stop waits for the reaction thread after its drain. A reaction
that has not finished a call by then is destroyed, because a shutdown is worth
more than a marker.")

(defparameter +reaction-timeout-seconds+ 5
  "Seconds to wait for one reaction call. A marker is cosmetic and never worth
the fifteen a reply gets, so a service that has stopped answering costs five
seconds per call and one line rather than a channel's whole budget.")

(declaim (ftype (function (t) (or null string)) message-reaction-key))

(defun message-reaction-key (data)
  "Return the key that names DATA's message, or NIL.

The key is the channel id and the message id, because a reaction route names
both and a message id alone is unique only within its channel. A payload
without either id has no message to react to."
  (let ((channel (text-field data :channel_id))
        (message (text-field data :id)))
    (when (and (plusp (length channel)) (plusp (length message)))
      (concatenate 'string channel "/" message))))

(declaim (ftype (function (t) boolean) reaction-key-p))

(defun reaction-key-p (key)
  "Return T when KEY is a channel id and a message id with a slash between."
  (and (stringp key)
       (let ((slash (position #\/ key)))
         (and slash
              (plusp slash)
              (< (1+ slash) (length key))))))

(declaim (ftype (function (string) (values string string)) reaction-parts))

(defun reaction-parts (key)
  "Return the channel id and the message id in KEY as two values."
  (let ((slash (position #\/ key)))
    (values (subseq key 0 slash) (subseq key (1+ slash)))))

(defparameter +path-unreserved+
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
  "The characters RFC 3986 leaves alone in a path segment. Everything else is
percent encoded, which is what an emoji needs: the route takes the emoji
itself, and the emoji itself is four UTF-8 octets and not four characters.")

(declaim (ftype (function (string) string) percent-encode-segment))

(defun percent-encode-segment (text)
  "Return TEXT percent encoded as one URL path segment."
  (let ((octets (enchiridion.compat:encode-utf8 text))
        (out (make-string-output-stream)))
    (loop for octet across octets
          do (let ((character (code-char octet)))
               (if (and character
                        (find character +path-unreserved+ :test #'char=))
                   (write-char character out)
                   (format out "%~2,'0X" octet))))
    (get-output-stream-string out)))

(declaim (ftype (function (string string) string) reaction-url))

(defun reaction-url (key emoji)
  "Return the route that adds or removes EMOJI on the message KEY names.

Both ends are the same route: PUT adds the bot's own reaction, DELETE removes
it. @ME is literal and is what says which reaction, because the authorization
header already says which bot."
  (multiple-value-bind (channel message) (reaction-parts key)
    (format nil "~A/channels/~A/messages/~A/reactions/~A/@me"
            +rest-base+
            (percent-encode-segment channel)
            (percent-encode-segment message)
            (percent-encode-segment emoji))))

(declaim (ftype (function (keyword) (or null string)) reaction-emoji))

(defun reaction-emoji (state)
  "Return the marker STATE shows, or NIL for a state that shows none."
  (case state
    (:queued +queued-reaction+)
    (:processing +processing-reaction+)
    (:failed +failed-reaction+)
    (t nil)))

;;;; What the bot has on a message.

(declaim (ftype (function (t string) (or null string)) applied-reaction))

(defun applied-reaction (channel key)
  "Return the marker CHANNEL last put on KEY, or NIL."
  (gethash key (fluxer-channel-reaction-applied channel)))

(declaim (ftype (function (t string string) null) track-reaction))

(defun track-reaction (channel key emoji)
  "Remember that EMOJI is the marker on KEY, evicting the oldest entry when the
table is full. Return NIL."
  (let ((table (fluxer-channel-reaction-applied channel))
        (order (fluxer-channel-reaction-applied-order channel)))
    (setf (gethash key table) emoji)
    (setf order (append (remove key order :test #'string=) (list key)))
    (loop while (> (length order) +reaction-tracked-limit+)
          do (remhash (pop order) table))
    (setf (fluxer-channel-reaction-applied-order channel) order))
  nil)

(declaim (ftype (function (t string) null) forget-reaction))

(defun forget-reaction (channel key)
  "Forget the marker on KEY. Return NIL."
  (remhash key (fluxer-channel-reaction-applied channel))
  (setf (fluxer-channel-reaction-applied-order channel)
        (remove key (fluxer-channel-reaction-applied-order channel)
                :test #'string=))
  nil)

;;;; Sending one change.

(declaim (ftype (function (t real) boolean) reaction-wait))

(defun reaction-wait (channel seconds)
  "Wait up to SECONDS, stopping early when the channel is shutting down.
Return T when the wait ran out and NIL when a stop cut it short."
  (let ((end (+ (real-seconds) (max 0 seconds))))
    (loop
      (when (fluxer-channel-reaction-stopping-p channel)
        (return nil))
      (when (>= (real-seconds) end)
        (return t))
      (sleep (max 0.01 (min 0.05 (- end (real-seconds))))))))

(declaim (ftype (function (t string string boolean &optional integer) boolean)
                reaction-call))

(defun reaction-call (channel key emoji add-p &optional (attempt 0))
  "Add EMOJI to KEY when ADD-P, or remove it, and return T on success.

A 404 is a success: the message or the reaction is already gone, which is the
state the caller wanted. A 429 is retried the way a reply is retried, up to
+RATE-LIMIT-ATTEMPTS+ times, because every marker on every message shares one
bucket of 30 requests per 10 seconds per channel. Anything else is one line and
NIL: a marker that cannot be put is not a reason to stop a channel that is
answering messages."
  (let ((token (non-blank-string (fluxer-channel-token channel))))
    (if (null token)
        (progn
          (note "there is no token, so a ~A marker was not sent." emoji)
          nil)
        (handler-case
            (progn
              (enchiridion.llm::bounded-http-request
               (enchiridion.llm:make-http-request
                :url (reaction-url key emoji)
                :headers (bot-headers token)
                :body ""
                :timeout +reaction-timeout-seconds+)
               :method (if add-p :put :delete)
               :body-limit 4096)
              t)
          (dexador.error:http-request-failed (failure)
            (let ((status (dexador.error:response-status failure)))
              (cond
                ((eql status 404) t)
                ((and (eql status 429)
                      (< attempt +rate-limit-attempts+)
                      (reaction-wait channel
                                     (or (retry-after-seconds
                                          (dexador.error:response-body failure))
                                         (next-backoff (1+ attempt)))))
                 (reaction-call channel key emoji add-p (1+ attempt)))
                (t
                 (note "the ~A reaction on ~A failed with ~D: ~A"
                       (if add-p "add" "remove") key status
                       (error-note (dexador.error:response-body failure)))
                 nil))))
          (error (condition)
            (note "the ~A reaction on ~A failed: ~A"
                  (if add-p "add" "remove") key condition)
            nil)))))

(declaim (ftype (function (t string keyword) (or null string))
                apply-reaction-state))

(defun apply-reaction-state (channel key state)
  "Bring the bot's marker on KEY to STATE and return what is now applied.

The applied table is what makes the cost proportional to the changes: a
message coalesced from waiting straight to delivered never had the hourglass
put, so there is nothing to delete. A call that fails leaves the table saying
what is actually there, not what was wanted. A DELETE that fails stops the
transition, because putting the new marker would leave the old one beside it."
  (let* ((applied (applied-reaction channel key))
         (want (reaction-emoji state)))
    (cond
      ((null want)
       (when (and applied (reaction-call channel key applied nil))
         (forget-reaction channel key))
       nil)
      ((and applied (string= applied want))
       applied)
      (t
       (let ((removed (or (null applied)
                          (reaction-call channel key applied nil))))
         (if (not removed)
             ;; The old marker is still on the message, which is what the
             ;; table says. A new one now would leave both.
             applied
             (progn
               (when applied (forget-reaction channel key))
               (when (reaction-call channel key want t)
                 (track-reaction channel key want))
               (applied-reaction channel key))))))))

;;;; The queue between the two callers and the reaction thread.

(declaim (ftype (function (t t keyword) null) enqueue-reaction))

(defun enqueue-reaction (channel key state)
  "Ask the reaction worker to bring KEY to STATE and return NIL.

Only a lock and a bounded append happen here. The gateway's read thread and
the turn worker both call this, and neither may wait on a service that is
decorative. A state for a message still waiting replaces the waiting one, so
the worker only ever applies the newest one; a delivered state that replaces a
waiting processing state costs no request at all."
  (when (and (reaction-key-p key)
             (member state +reaction-states+))
    (let ((queued nil)
          (full nil))
      (bordeaux-threads:with-lock-held ((fluxer-channel-reaction-lock channel))
        (let ((states (fluxer-channel-reaction-pending channel)))
          (cond
            ((gethash key states)
             (setf (gethash key states) state))
            ((>= (length (fluxer-channel-reaction-order channel))
                 +max-pending-reactions+)
             (setf full t))
            (t
             (setf (gethash key states) state)
             (setf (fluxer-channel-reaction-order channel)
                   (nconc (fluxer-channel-reaction-order channel)
                          (list key)))
             (setf queued t)))))
      (when full
        (note "the reaction queue is full, so a ~(~A~) marker on ~A was dropped."
              state key))
      (when queued
        (bordeaux-threads:signal-semaphore
         (fluxer-channel-reaction-ready channel)))))
  nil)

(declaim (ftype (function (t) t) dequeue-reaction))

(defun dequeue-reaction (channel)
  "Return the next (KEY . STATE) for the reaction worker, or NIL."
  (bordeaux-threads:with-lock-held ((fluxer-channel-reaction-lock channel))
    (let ((key (pop (fluxer-channel-reaction-order channel))))
      (when key
        (let ((state (gethash key (fluxer-channel-reaction-pending channel))))
          (remhash key (fluxer-channel-reaction-pending channel))
          (cons key state))))))

(declaim (ftype (function (t) null) fail-pending-reactions))

(defun fail-pending-reactions (channel)
  "Turn every waiting or running marker into the warning one and return NIL.

A message that has not reached a terminal state when the channel stops will
never be answered, and an hourglass or a wrench left on it is a promise the
process can no longer keep. A delivered state is left alone: its reply did
reach the gateway, so the stop still clears its marker."
  (bordeaux-threads:with-lock-held ((fluxer-channel-reaction-lock channel))
    (let ((states (fluxer-channel-reaction-pending channel))
          (keys '()))
      (maphash (lambda (key state)
                 (when (member state '(:queued :processing))
                   (push key keys)))
               states)
      (dolist (key keys)
        (setf (gethash key states) :failed))))
  nil)

;;;; The one thread that applies them.

(declaim (ftype (function (t) boolean) reaction-drain-expired-p))

(defun reaction-drain-expired-p (channel)
  "Return T when a stop's drain window has passed."
  (let ((deadline (fluxer-channel-reaction-deadline channel)))
    (and deadline
         (fluxer-channel-reaction-stopping-p channel)
         (>= (real-seconds) deadline))))

(declaim (ftype (function (t) null) run-reaction-worker))

(defun run-reaction-worker (channel)
  "Apply queued reaction states until CHANNEL stops. Return NIL.

The thread waits on a semaphore rather than polling, and the same semaphore
wakes it at a stop. A stop keeps draining until the queue is empty or its
deadline passes, so the warning markers a stop creates are sent when the
service still answers."
  (loop
    (let ((entry (dequeue-reaction channel)))
      (cond
        (entry
         (apply-reaction-state channel (car entry) (cdr entry)))
        ((fluxer-channel-reaction-stopping-p channel)
         (return))
        (t
         (bordeaux-threads:wait-on-semaphore
          (fluxer-channel-reaction-ready channel)
          :timeout +worker-wait-seconds+))))
    (when (reaction-drain-expired-p channel)
      (return)))
  nil)

(declaim (ftype (function (t) t) start-reaction-worker))

(defun start-reaction-worker (channel)
  "Reset the reaction state and start the one thread that applies it."
  (setf (fluxer-channel-reaction-stopping-p channel) nil
        (fluxer-channel-reaction-deadline channel) nil
        (fluxer-channel-reaction-pending channel) (make-hash-table :test #'equal)
        (fluxer-channel-reaction-order channel) nil
        (fluxer-channel-reaction-applied channel) (make-hash-table :test #'equal)
        (fluxer-channel-reaction-applied-order channel) nil
        (fluxer-channel-reaction-worker channel)
        (bordeaux-threads:make-thread
         (lambda () (run-reaction-worker channel))
         :name "enchiridion fluxer reactions"))
  channel)

(declaim (ftype (function (t) null) stop-reaction-worker))

(defun stop-reaction-worker (channel)
  "Mark what is waiting as failed, drain for a bounded time, and join the
reaction thread. Return NIL.

The thread is joined after the drain with +REACTION-STOP-SECONDS+, not the
turn worker's five: a reaction is never worth making a shutdown wait on a
service that may be gone. The applied table is left as it is: a restart resets
it, and until then it is the only record of which markers the bot put down."
  (let ((worker (fluxer-channel-reaction-worker channel)))
    (when worker
      (fail-pending-reactions channel)
      (setf (fluxer-channel-reaction-stopping-p channel) t
            (fluxer-channel-reaction-deadline channel)
            (+ (real-seconds) +reaction-drain-seconds+))
      (bordeaux-threads:signal-semaphore (fluxer-channel-reaction-ready channel))
      (join-thread-bounded worker +reaction-stop-seconds+)
      ;; The thread is joined or destroyed, so these reads are not racing a
      ;; writer. Taking the lock here would deadlock if the thread died while
      ;; it held it, which is the one thing a bounded join cannot rule out.
      (let ((left (length (fluxer-channel-reaction-order channel))))
        (setf (fluxer-channel-reaction-pending channel) (make-hash-table :test #'equal)
              (fluxer-channel-reaction-order channel) nil)
        (when (plusp left)
          (note "~D reaction~:P were not sent before the stop." left)))
      (setf (fluxer-channel-reaction-worker channel) nil)))
  nil)

;;;; The queue between the read thread and the worker.

(declaim (ftype (function (fluxer-channel t) null) enqueue-inkbound))

(defun enqueue-inkbound (channel data)
  "Hand DATA to the worker and return NIL.

The queue is bounded. A turn can take minutes, and the gateway does not stop
sending while it runs, so a full queue drops the oldest waiting message and
counts it rather than growing without a limit. The drop is one log line, which
is loud enough to act on and quiet enough not to stop the channel, and the
message it dropped is marked failed because no turn will ever answer it.

The stop flag is read under the same lock that writes the queue. A message
that arrives after a stop began is therefore never left waiting for a worker
that has gone: it is refused, and marked failed for the same reason."
  (let ((dropped nil)
        (refused nil))
    (bordeaux-threads:with-lock-held ((fluxer-channel-pending-lock channel))
      (if (fluxer-channel-stopping-p channel)
          (setf refused t)
          (progn
            (when (>= (length (fluxer-channel-pending channel))
                      +max-pending-messages+)
              (setf dropped (pop (fluxer-channel-pending channel)))
              (incf (fluxer-channel-dropped channel)))
            (setf (fluxer-channel-pending channel)
                  (nconc (fluxer-channel-pending channel) (list data))))))
    (cond
      (refused
       (note "the channel is stopping, so a message was not queued.")
       (enqueue-reaction channel (message-reaction-key data) :failed))
      (dropped
       (note "the queue is full, so the oldest waiting message was dropped (~D so far)."
             (fluxer-channel-dropped channel))
       (enqueue-reaction channel (message-reaction-key dropped) :failed)))
    (unless refused
      (bordeaux-threads:signal-semaphore (fluxer-channel-pending-ready channel))))
  nil)

(declaim (ftype (function (fluxer-channel) t) claim-inkbound))

(defun claim-inkbound (channel)
  "Return the oldest waiting payload for the worker, or NIL.

NIL means the queue was empty, or the channel is stopping. The stop flag and
the queue are read under one lock, so a stop cannot begin between the check and
the pop: a message is either claimed by a running worker or left for
STOP-WORKER to mark failed, never both."
  (bordeaux-threads:with-lock-held ((fluxer-channel-pending-lock channel))
    (unless (fluxer-channel-stopping-p channel)
      (pop (fluxer-channel-pending channel)))))

;;;; The worker: the one thread that runs a turn.

(declaim (ftype (function (t (or null string)) null) note-active-reaction))

(defun note-active-reaction (channel key)
  "Record the message the worker is inside, or clear it with NIL.

A stop that has to destroy the worker reads this to mark the abandoned message
failed. The pending lock is the one both sides already take, and neither side
holds it across a call that waits."
  (bordeaux-threads:with-lock-held ((fluxer-channel-pending-lock channel))
    (setf (fluxer-channel-active-reaction channel) key))
  nil)

(declaim (ftype (function (fluxer-channel t) null) handle-inkbound))

(defun handle-inkbound (channel data)
  "Run one turn for DATA and send its reply. Return NIL.

The turn is an injected function, and a turn that signals, or one that answers
without :OK-P, is one log line and no reply. A worker that dies on the first
bad turn is a channel that stops answering, and the gateway does not care whose
fault it was.

The reaction is part of the same lifecycle. DELIVERED is enqueued only when
SEND-REPLY returns, which is the one answer that says every piece reached the
gateway; a reply whose second piece fails leaves FAILED, because a person who
got half an answer has not got the answer."
  (let* ((message (message-create->msg data))
         (key (message-reaction-key data))
         (turn (fluxer-channel-turn channel))
         (completed nil))
    (unwind-protect
         (progn
           (note-active-reaction channel key)
           (enqueue-reaction channel key :processing)
           (cond
             ((not (functionp turn))
              (note "there is no turn function, so ~A was not answered."
                    (enchiridion.channel:message-digest message))
              (enqueue-reaction channel key :failed))
             ((handler-case
                  (let ((result (funcall turn message)))
                    (cond
                      ((not (listp result))
                       (note "the turn answered ~S, which is not a result plist."
                             result)
                       nil)
                      ((not (getf result :ok-p))
                       (note "the turn failed for ~A: ~A"
                             (enchiridion.channel:message-digest message)
                             (or (getf result :error) "no reason given"))
                       nil)
                      (t
                       (handler-case
                           (progn
                             (send-reply channel
                                         (enchiridion.channel:msg-target message)
                                         (getf result :reply))
                             (when (getf result :status)
                               (ignore-errors
                                 (propose-custom-status
                                  channel (getf result :status)
                                  :author (enchiridion.channel:msg-author message))))
                             t)
                         (error (condition)
                           (note "the reply for ~A did not finish: ~A"
                                 (enchiridion.channel:message-digest message)
                                 condition)
                           nil)))))
                (error (condition)
                  (note "the turn for ~A signalled: ~A"
                        (enchiridion.channel:message-digest message)
                        condition)
                  nil))
              (enqueue-reaction channel key :delivered))
             (t
              (enqueue-reaction channel key :failed)))
           (setf completed t))
      ;; A destroyed thread that runs this cleanup did not reach a terminal
      ;; state, so the marker stays set for STOP-WORKER to find and mark failed.
      (when completed
        (note-active-reaction channel nil))))
  nil)

(declaim (ftype (function (fluxer-channel) null) run-worker))

(defun run-worker (channel)
  "Run every inkbound message through the turn, one at a time, until stopped.

One worker thread, so two turns never run at once and messages are answered in
the order they arrived. The wait is signalled as well as timed, so a lost
wake-up costs +WORKER-WAIT-SECONDS+ and never a message.

The stop flag is checked again by CLAIM-INKBOUND, under the queue lock, when a
wake-up is turned into work. A stop that lands after the wait but before the
pop therefore ends the loop instead of starting one more turn."
  (loop
    (when (fluxer-channel-stopping-p channel)
      (return))
    (when (bordeaux-threads:wait-on-semaphore
           (fluxer-channel-pending-ready channel)
           :timeout +worker-wait-seconds+)
      (let ((data (claim-inkbound channel)))
        (when data
          (handle-inkbound channel data)))))
  nil)

(declaim (ftype (function (fluxer-channel) null) stop-worker))

(defun stop-worker (channel)
  "Ask the worker to finish, wake it, and join it for a bounded time. Return
NIL.

A turn that had to be destroyed, and every message still waiting behind it,
will never be answered, so each is marked failed on the message itself. The
markers are only enqueued here: the reaction thread is stopped after this, and
that order is what lets it send them."
  (bordeaux-threads:with-lock-held ((fluxer-channel-pending-lock channel))
    (setf (fluxer-channel-stopping-p channel) t))
  (bordeaux-threads:signal-semaphore (fluxer-channel-pending-ready channel))
  (let ((worker (fluxer-channel-worker channel))
        (abandoned nil)
        (active nil)
        (waiting nil))
    (when worker
      (setf abandoned (join-thread-bounded worker +stop-join-seconds+)
            (fluxer-channel-worker channel) nil))
    (bordeaux-threads:with-lock-held ((fluxer-channel-pending-lock channel))
      (setf active (fluxer-channel-active-reaction channel)
            (fluxer-channel-active-reaction channel) nil
            waiting (fluxer-channel-pending channel)
            (fluxer-channel-pending channel) nil))
    (when (and abandoned active)
      (enqueue-reaction channel active :failed))
    (dolist (data waiting)
      (enqueue-reaction channel (message-reaction-key data) :failed))
    (when waiting
      (note "~D waiting message~:P dropped at the stop." (length waiting))))
  nil)

;;;; The read thread's handlers.
;;;;
;;;; Everything below runs on the library's read thread. It parses, it notes,
;;;; and it hands a payload to the worker. It never runs a turn and it never
;;;; waits: a read thread inside a model call is a socket whose heartbeats
;;;; stop, and the gateway closes that with 4009.

(declaim (ftype (function (t) (or null string)) message-text))

(defun message-text (message)
  "Return MESSAGE as text, or NIL. A binary frame is not something this
protocol uses: every gateway frame is JSON."
  (and (stringp message) message))

(declaim (ftype (function (fluxer-socket t) null) note-hello))

(defun note-hello (socket frame)
  "Record the interval Hello names and wake the thread waiting for it."
  (let ((interval (hello-interval frame)))
    (when interval
      (setf (fluxer-socket-heartbeat-interval socket) interval)))
  (bordeaux-threads:signal-semaphore (fluxer-socket-hello socket))
  nil)

(declaim (ftype (function (fluxer-socket) null) note-ack))

(defun note-ack (socket)
  "Record that the gateway accepted a heartbeat."
  (setf (fluxer-socket-last-ack socket) (get-universal-time))
  nil)

(declaim (ftype (function (fluxer-channel fluxer-socket) null)
                note-invalid-session))

(defun note-invalid-session (channel socket)
  "Identify again on the same socket after op 9.

The socket stays open and unauthenticated after an invalid session, so closing
it and reconnecting would throw away a working transport. SEND-IDENTIFY drops
the session id and the cursor: a resume after an invalid session is answered
with op 9 again, and op 9 is never sent with d true, so an Identify is the only
frame that can work."
  (unless (fluxer-channel-stopping-p channel)
    (send-identify channel socket))
  nil)

(declaim (ftype (function (fluxer-socket) null) note-reconnect-requested))

(defun note-reconnect-requested (socket)
  "Note that the gateway asked for a reconnect, and close the socket.

The close ends the read thread's loop, and the reconnect loop decides from the
session's age whether the next socket resumes or identifies."
  (note "the gateway asked for a reconnect.")
  (close-socket socket)
  nil)

(declaim (ftype (function (fluxer-channel t) null) note-ready))

(declaim (ftype (function (t) (or null string)) ready-user-id))

(defun ready-user-id (data)
  "Return the agent's own user id in DATA, a READY payload, or NIL.

The id is the one under :USER, which is the shape a READY event carries. A
flattened :USER_ID is accepted as well, because the alternative to a tolerant
read here is an unarmed echo guard, and an unarmed echo guard is the agent
answering itself in a loop that costs tokens and never ends."
  (or (let ((user (and (consp data) (getf data :user))))
        (and (consp user) (non-blank-string (getf user :id))))
      (non-blank-string (and (consp data) (getf data :user_id)))))

(declaim (ftype (function (fluxer-channel t) null) note-ready))

(defun note-ready (channel frame)
  "Record who the agent is and which session this socket is, from READY.

The reconnect budget is not reset here. A gateway that completes the handshake
and closes again reaches READY as well, so a reset here would retry it once a
second for the life of the process; only the reconnect loop can measure a
connection that stayed up. See NEXT-ATTEMPT."
  (let ((data (frame-data frame)))
    (when (consp data)
      (setf (fluxer-channel-self-id channel) (ready-user-id data))
      (setf (fluxer-channel-session-id channel)
            (non-blank-string (getf data :session_id))))
    (note "connected as ~A." (or (fluxer-channel-self-id channel)
                                 "an unknown user"))
    ;; READY follows an Identify, so this session began without the presence
    ;; the last one had. A status that is still current goes out again; one
    ;; that has expired is forgotten rather than republished.
    (reapply-custom-status channel))
  nil)

(declaim (ftype (function (list t) t) check-sender))

(defun check-sender (allowlist id)
  "Signal UNAUTHORIZED when ID is not on ALLOWLIST, and return ID when it is.

The condition is the policy in one object: a caller in this process can catch
it and ask, rather than read a NIL and guess which rule said no. The report
reads \"~A is not allowed to talk to this agent\", so the sender's id is what
the condition carries."
  (unless (allowed-p allowlist id)
    (error 'enchiridion.errors:unauthorized :channel (or id "an unknown sender")))
  id)

(declaim (ftype (function (fluxer-channel t) null) offer-message))

(defun offer-message (channel data)
  "Allow or drop DATA, a MESSAGE_CREATE payload, and return NIL.

Three refusals, each with its own line and none of them an error out of this
thread: a message that is not a direct message from a person, and a direct
message from someone the allowlist does not name. A refusal is never answered,
because an answer is a reply to whoever asked.

The waiting marker is queued before the message reaches the worker, so the
worker's processing marker cannot overtake it: the two states are read in the
order they were enqueued, and a marker that arrived late would move a message
back to waiting while its turn ran."
  (cond
    ((not (inkbound-p data (fluxer-channel-self-id channel)))
     (note "dropped a message that is not a direct message from a person."))
    (t
     (handler-case
         (progn
            (check-sender (channel-allowlist channel) (author-id data))
            (enqueue-reaction channel (message-reaction-key data) :queued)
            (enqueue-inkbound channel data))
       (enchiridion.errors:unauthorized (condition)
         (note "~A" condition))
       (error (condition)
         (note "dropped a message that could not be checked: ~A" condition)))))
  nil)

(declaim (ftype (function (fluxer-channel t) null) note-session-start))

(defun note-session-start (channel frame)
  "Forget the old cursor when READY names a session the channel has not been in.

A READY whose session id differs from the one in hand is a new numbering that
starts at one. Dropping the cursor here recovers a stale one even on a path that
never sent an Identify, and the READY then passes the filter and records the new
session. A resume answers with the session id already in hand, so a resumed
session keeps its cursor and keeps dropping what it has answered."
  (let* ((data (frame-data frame))
         (session (non-blank-string (and (consp data) (getf data :session_id)))))
    (when (and session
               (non-blank-string (fluxer-channel-session-id channel))
               (not (string= session (fluxer-channel-session-id channel))))
      (note-fresh-session channel)))
  nil)

(declaim (ftype (function (fluxer-channel t) null) handle-dispatch))

(defun handle-dispatch (channel frame)
  "Advance the sequence and hand an inkbound direct message to the worker.

The sequence advances for every dispatch, including the ones dropped, because
it is what a heartbeat reports and what a resume replays from. A replayed
dispatch keeps its old number, so a redelivery is dropped here rather than
answered twice.

READY is read before the filter: it is the one frame that says the numbering
restarted, and a cursor from the old numbering would drop it."
  (when (ready-p frame)
    (note-session-start channel frame))
  (multiple-value-bind (sequence fresh-p)
      (advance-sequence (fluxer-channel-sequence channel) (frame-seq frame))
    (setf (fluxer-channel-sequence channel) sequence)
    (when fresh-p
      (cond
        ((ready-p frame) (note-ready channel frame))
        ((message-create-p frame) (offer-message channel (frame-data frame))))))
  nil)

(declaim (ftype (function (fluxer-channel t) boolean) current-socket-p))

(defun current-socket-p (channel socket)
  "Return T when SOCKET is the socket CHANNEL is working on.

The library closes a socket from another thread by destroying its read thread,
and a frame that thread had already read can still arrive afterwards. It carries
the sequence of a session that is over, so letting it through would move the
cursor the live session reads from and turn real dispatches into replays. NIL,
the state before the first socket is recorded, accepts a frame: that is a new
connection's Hello arriving before the channel records the socket."
  (let ((current (fluxer-channel-socket channel)))
    (or (null current) (eq current socket))))

(declaim (ftype (function (fluxer-channel fluxer-socket t) null) handle-text))

(defun handle-text (channel socket message)
  "Handle one inbound websocket message and return NIL.

This runs on the library's read thread, so it does three cheap things and no
more: parse the frame, note what the channel needs, and hand anything that
needs a turn to the worker. The error handler is what keeps a bad frame from
ending the read loop, because the library's loop would treat a signal as the
end of the connection."
  (handler-case
      (let ((text (message-text message)))
        (when (and text (current-socket-p channel socket))
          (let ((frame (parse-frame text)))
            (cond
              ((null frame)
               (note "dropped a frame that is not a JSON object: ~A"
                     (short-text text 120)))
              ((eql +op-hello+ (frame-op frame)) (note-hello socket frame))
              ((eql +op-heartbeat+ (frame-op frame)) (send-heartbeat channel socket))
              ((eql +op-heartbeat-ack+ (frame-op frame)) (note-ack socket))
              ((eql +op-invalid-session+ (frame-op frame))
               (note-invalid-session channel socket))
              ((eql +op-reconnect+ (frame-op frame)) (note-reconnect-requested socket))
              ((eql +op-dispatch+ (frame-op frame)) (handle-dispatch channel frame))
              (t nil)))))
    (error (condition)
      (note "a frame could not be handled: ~A" condition)))
  nil)

;;;; One connection.

(declaim (ftype (function (fluxer-channel) boolean) resume-open-p))

(defun resume-open-p (channel)
  "Return T when the session this channel had can still be resumed.

The gateway keeps a session for +RESUME-WINDOW-SECONDS+ after a transport end,
so a reconnect inside the window resumes and is sent what it missed. After it,
a fresh Identify is the only frame that works."
  (and (non-blank-string (fluxer-channel-session-id channel))
       (resume-window-open-p (fluxer-channel-session-ended channel)
                             (get-universal-time))))

(declaim (ftype (function (fluxer-channel string) (or null fluxer-socket))
                open-socket))

(defun open-socket (channel url)
  "Connect to URL and return the socket, or NIL after one line.

The handlers go on before the connection starts, because the close can fire
inside START-CONNECTION and a listener attached afterwards would miss it."
  (handler-case
      (let ((socket (make-instance 'fluxer-socket :url url)))
        (websocket-driver:on :message socket
                             (lambda (message)
                               (handle-text channel socket message)))
        (websocket-driver:on :close socket
                             (lambda (&key code reason)
                               (note-socket-closed socket code)
                               (when reason
                                 (note "the gateway closed: ~A" reason))))
        (websocket-driver:on :error socket
                             (lambda (condition)
                               (note "the socket errored: ~A" condition)))
        (websocket-driver:start-connection socket)
        socket)
    (error (condition)
      (note "could not connect to ~A: ~A" url condition)
      nil)))

(declaim (ftype (function (fluxer-channel fluxer-socket) null) run-heartbeats))

(defun run-heartbeats (channel socket)
  "Send heartbeats until the socket closes or CHANNEL is stopped. Return NIL.

Every beat is due one interval after the last one was written, measured from
the clock rather than accumulated, so a slow send cannot make the beats drift
late. The wait is sliced at one second, which is what makes a stop or a close
take effect at once instead of one interval later.

A half open transport looks like a quiet one: writes still succeed and no frame
arrives again. This is the only place that can tell them apart, so a beat left
unanswered for +HEARTBEAT-ACK-TIMEOUT-SECONDS+ closes the socket here and lets
the reconnect loop do the rest."
  (let* ((beat 0)
         (interval (or (fluxer-socket-heartbeat-interval socket)
                       +default-heartbeat-interval+))
         (sent nil)
         (due (+ (real-seconds) (heartbeat-delay 0 interval))))
    (loop
      (when (or (fluxer-channel-stopping-p channel)
                (fluxer-socket-closed-p socket))
        (return))
      ;; The heartbeat is already awake at least once a second, so the status
      ;; deadline rides on it instead of starting a timer of its own.
      (when (fluxer-channel-status-text channel)
        (expire-custom-status channel))
      (when (heartbeat-ack-overdue-p sent (fluxer-socket-last-ack socket)
                                    (get-universal-time))
        (note "no heartbeat acknowledged for ~D seconds, so this socket is gone."
              +heartbeat-ack-timeout-seconds+)
        (close-socket socket)
        (return))
      (let ((now (real-seconds)))
        (if (< now due)
            (wait-for-close socket (min 1.0 (- due now)))
            (progn
              (send-heartbeat channel socket)
              (setf sent (get-universal-time))
              (setf interval (or (fluxer-socket-heartbeat-interval socket)
                                 interval))
              (incf beat)
              (setf due (+ (real-seconds) (heartbeat-delay beat interval))))))))
  nil)

(declaim (ftype (function (fluxer-channel fluxer-socket) null) run-session))

(defun run-session (channel socket)
  "Authenticate SOCKET and run it until it closes or CHANNEL is stopped.

A session young enough to resume is resumed, because a resume replays what the
disconnect lost; anything else identifies. Both are followed by heartbeats,
since the interval is Hello's and Hello has already arrived."
  (if (resume-open-p channel)
      (send-resume channel socket)
      (send-identify channel socket))
  (run-heartbeats channel socket)
  nil)

(declaim (ftype (function (fluxer-socket) null) note-pre-hello-close))

(defun note-pre-hello-close (socket)
  "Note that the gateway closed before Hello, which is where a refused token
shows up first."
  (note "the gateway closed before Hello: ~A."
        (close-code-note (fluxer-socket-close-code socket)))
  nil)

(declaim (ftype (function (fluxer-channel) t) connect-once))

(defun connect-once (channel)
  "Connect, run the session, and return the close code or NIL.

NIL means no connection was opened at all, which is a discovery or handshake
failure. Anything else is the code the socket ended with, or :CLOSED when it
ended without one."
  (let ((socket nil))
    (unwind-protect
         (progn
           (let ((url (discover-gateway (fluxer-channel-token channel))))
             (when url
               (setf socket (open-socket channel url))))
           (when socket
             (setf (fluxer-channel-socket channel) socket)
             (cond
               ((fluxer-socket-closed-p socket) (note-pre-hello-close socket))
               ((not (wait-for-hello socket +identify-wait-seconds+))
                (note "the gateway sent no Hello within ~D seconds."
                      +identify-wait-seconds+))
               ((fluxer-socket-closed-p socket) (note-pre-hello-close socket))
               (t (run-session channel socket)))
             (or (fluxer-socket-close-code socket) :closed)))
      (close-socket socket)
      (when socket
        (setf (fluxer-channel-session-ended channel) (get-universal-time))
        (setf (fluxer-channel-socket channel) nil)))))

(declaim (ftype (function (t) boolean) fatal-close-p))

(defun fatal-close-p (code)
  "Return T when CODE says reconnecting cannot work."
  (and (integerp code)
       (not (null (member code +fatal-close-codes+)))))

(declaim (ftype (function (fluxer-channel integer) null) sleep-backoff))

(defun sleep-backoff (channel attempt)
  "Wait NEXT-BACKOFF seconds for ATTEMPT, or until CHANNEL is stopped.

The wait is sliced, so a stop during a sixty second backoff takes effect in
half a second rather than in a minute."
  (let ((deadline (+ (real-seconds) (next-backoff attempt))))
    (loop while (and (not (fluxer-channel-stopping-p channel))
                     (< (real-seconds) deadline))
          do (sleep (min 0.5 (max 0.05 (- deadline (real-seconds)))))))
  nil)

;;;; The protocol.

(declaim (ftype (function (fluxer-channel) null) shutdown))

(defun shutdown (channel)
  "Close the socket, stop the turn worker, and drain the reaction thread. Return
NIL.

Safe to run twice and safe on a channel that never started: a stop and an
unwinding start both run it. The turn worker stops first because it is what
turns a waiting message into a failed one, and the reaction thread has to still
be there to send those markers."
  (close-socket (fluxer-channel-socket channel))
  (stop-worker channel)
  (stop-reaction-worker channel)
  nil)

(defmethod enchiridion.channel:channel-start ((channel fluxer-channel) &key config)
  "Start CHANNEL and block until it is stopped.

The method does not return while the channel is live. The supervisor calls it
again when it returns, so a return is the restart signal and the reconnect
budget is what makes returning rare: five backed-off attempts, then one line
and a :FAILED state for the supervisor to try again in a second.

A missing token and a missing turn function are both refused here, in one line,
before any socket opens. Neither signals: they are configuration facts the
operator can see in the log, and a channel that signals them takes a supervisor
down over a mis-set variable."
  (when config
    (setf (fluxer-channel-config channel) config))
  (let ((token (resolve-token :name (channel-token-env channel))))
    (unless token
      (note "no bot token: set ~A, or :token-env in the :fluxer section."
            (channel-token-env channel))
      (setf (enchiridion.channel:channel-live-p channel) nil
            (enchiridion.channel:channel-state channel) :failed)
      (return-from enchiridion.channel:channel-start channel))
    (setf (fluxer-channel-token channel) token))
  (unless (functionp (fluxer-channel-turn channel))
    (note "no turn function is injected, so there is nothing to answer with.")
    (setf (enchiridion.channel:channel-live-p channel) nil
          (enchiridion.channel:channel-state channel) :failed)
    (return-from enchiridion.channel:channel-start channel))
  (setf (fluxer-channel-stopping-p channel) nil
        (fluxer-channel-attempt channel) 0
        (fluxer-channel-dropped channel) 0
        (fluxer-channel-pending channel) nil
        (fluxer-channel-active-reaction channel) nil
        ;; A socket left over from a stop is not the one the next connection
        ;; will read, and CURRENT-SOCKET-P would take its frames for another's
        (fluxer-channel-socket channel) nil
        (enchiridion.channel:channel-live-p channel) t
        (enchiridion.channel:channel-state channel) :live)
  ;; The reaction thread starts first, so no accepted message can outrun the
  ;; thread that will carry its markers.
  (start-reaction-worker channel)
  (setf (fluxer-channel-worker channel)
        (bordeaux-threads:make-thread
         (lambda () (run-worker channel))
         :name "enchiridion fluxer worker"))
  (let ((outcome
          (unwind-protect
               (loop
                 (when (fluxer-channel-stopping-p channel)
                   (return :stopped))
                 (let* ((started (get-universal-time))
                        (code (handler-case (connect-once channel)
                                (error (condition)
                                  (note "the connection failed: ~A" condition)
                                  nil))))
                   (when (fluxer-channel-stopping-p channel)
                     (return :stopped))
                   (cond
                     ((null code)
                      (note "could not open a gateway connection."))
                     ((fatal-close-p code)
                      (note "the gateway refused the session: ~A. Not retrying."
                            (close-code-note code))
                      (return :failed))
                     (t
                      (note "the gateway connection ended: ~A."
                            (close-code-note code))))
                   (setf (fluxer-channel-attempt channel)
                         (next-attempt (fluxer-channel-attempt channel)
                                       (- (get-universal-time) started))))
                 (when (> (fluxer-channel-attempt channel)
                          +max-reconnect-attempts+)
                   (note "gave up after ~D reconnects."
                         +max-reconnect-attempts+)
                   (return :failed))
                 (sleep-backoff channel (fluxer-channel-attempt channel)))
            (shutdown channel))))
    (setf (enchiridion.channel:channel-live-p channel) nil
          (enchiridion.channel:channel-state channel)
          (if (eq outcome :stopped) :stopped :failed)))
  channel)

(defmethod enchiridion.channel:channel-stop ((channel fluxer-channel))
  "Stop CHANNEL: close the socket, wake the worker, and join what is left.

Safe to call twice, and safe on a channel that never started, because a
supervisor stops every channel it holds."
  (shutdown channel)
  (setf (enchiridion.channel:channel-live-p channel) nil
        (enchiridion.channel:channel-state channel) :stopped)
  channel)

(defmethod enchiridion.channel:channel-send ((channel fluxer-channel) target text
                                             &key reply-to)
  "Send TEXT to TARGET, the channel id of a direct message conversation.

REPLY-TO is accepted and not sent: a direct message has one conversation, so a
reply reference buys nothing the target does not already say. The return value
is the list of message ids the gateway accepted."
  (declare (ignore reply-to))
  (unless (fluxer-channel-token channel)
    (error 'enchiridion.errors:configuration-error
           :key "fluxer"
           :detail "the channel is not started, so there is no token to send with."))
  (send-reply channel target text))

(defmethod enchiridion.channel:channel-status ((channel fluxer-channel))
  "Return CHANNEL's state."
  (enchiridion.channel:channel-state channel))

;;;; The entry points.

(declaim (ftype (function (t) boolean) fluxer-running-p))

(defun fluxer-running-p (channel)
  "Return T while CHANNEL is live."
  (and (typep channel 'fluxer-channel)
       (eq :live (enchiridion.channel:channel-status channel))))

(declaim (ftype (function (&key (:turn t) (:config t))
                           (values fluxer-channel &rest t))
                start-fluxer))

(defun start-fluxer (&key turn config)
  "Create a Fluxer channel, start it, and return it.

This is the one shot entry for a caller that is not a supervisor, and it blocks
for as long as the channel runs, exactly as START-CLI does."
  (let ((channel (make-fluxer-channel :turn turn :config config)))
    (enchiridion.channel:channel-start channel)
    channel))

(declaim (ftype (function (t) t) stop-fluxer))

(defun stop-fluxer (channel)
  "Stop CHANNEL and return it."
  (enchiridion.channel:channel-stop channel))
