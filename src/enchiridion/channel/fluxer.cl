;;;; fluxer.cl --- The Fluxer direct-message channel.
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
;;;; read thread never holds a turn while the socket backs up behind it.
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

(defparameter +identify-wait-seconds+ 10
  "How long to wait for Hello after the handshake. A gateway that accepts the
socket and then says nothing is not a gateway to sit and wait on.")

(defparameter +message-limit+ 2000
  "How many characters one message may carry. The resolved default for a bot.")

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

(defun frame-close-code (data &optional (start 0) end)
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
  (let ((end (or end (length data))))
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
            :documentation "Reconnects since the last READY. READY resets it,
so a healthy session starts its next failure with a fresh budget.")
   (dropped :accessor fluxer-channel-dropped :initform 0 :type integer
            :documentation "How many messages a full queue has dropped."))
  (:documentation
   "The Fluxer direct-message channel. One worker thread runs every turn, so a
slow turn queues instead of starving the socket, and the library's read thread
only ever parses a frame and hands it on."))

(declaim (ftype (function (&key (:turn t) (:config t)) fluxer-channel)
                make-fluxer-channel))

(defun make-fluxer-channel (&key turn config)
  "Return a stopped Fluxer channel that calls TURN for every inkbound message.

TURN is (lambda (msg) ...) and returns a plist (:ok-p BOOL :reply STRING :error
STRING :usage PLIST-OR-NIL). It is the only way this channel reaches an agent:
the channel never calls the kernel, so a test hands it a closure and a
supervisor hands it the agent's turn. CONFIG is the :FLUXER options, or a whole
configuration that carries them; NIL means whatever is active."
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

(declaim (ftype (function (t integer) null) join-thread-bounded))

(defun join-thread-bounded (thread seconds)
  "Wait up to SECONDS for THREAD to finish, then destroy it. Return NIL.

A plain join on a worker that is inside a model call is a stop that never
finishes, and the deadline is what makes a stop a stop."
  (when (and thread (bordeaux-threads:thread-alive-p thread))
    (let ((deadline (+ (real-seconds) seconds)))
      (loop while (and (bordeaux-threads:thread-alive-p thread)
                       (< (real-seconds) deadline))
            do (sleep 0.05))
      (when (bordeaux-threads:thread-alive-p thread)
        (ignore-errors (bordeaux-threads:destroy-thread thread)))))
  nil)

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

(declaim (ftype (function (fluxer-channel fluxer-socket) string)
                send-heartbeat))

(defun send-heartbeat (channel socket)
  "Send one op 1 heartbeat carrying the last processed sequence."
  (send-frame channel socket
              (heartbeat-frame (fluxer-channel-sequence channel))))

(declaim (ftype (function (fluxer-channel fluxer-socket) string) send-identify))

(defun send-identify (channel socket)
  "Send op 2 Identify, the frame that authenticates a fresh session."
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
      (let* ((body (dexador:request (concatenate 'string +rest-base+
                                                 +gateway-path+)
                                    :method :get
                                    :headers (bot-headers token)
                                    :connect-timeout +http-timeout-seconds+
                                    :read-timeout +http-timeout-seconds+))
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
        (let ((reply (dexador:request url
                                      :method :post
                                      :headers (bot-headers token)
                                      :content body
                                      :connect-timeout +http-timeout-seconds+
                                      :read-timeout +http-timeout-seconds+)))
          ;; An unreadable reply is not a failed send: the message was
          ;; accepted, and retrying it would post it twice.
          (message-id (ignore-errors (enchiridion.llm:parse-json reply))))
      (dexador.error:http-request-failed (failure)
        (let ((status (dexador.error:response-status failure))
              (payload (dexador.error:response-body failure)))
          (if (and (eql status 429) (< attempt +rate-limit-attempts+))
              (progn
                (sleep (or (retry-after-seconds payload)
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
  (let ((ids '()))
    (dolist (piece (outbound-chunks text +message-limit+))
      (let ((id (post-message (fluxer-channel-token channel) target piece)))
        (when id (push id ids))))
    (nreverse ids)))

;;;; The queue between the read thread and the worker.

(declaim (ftype (function (fluxer-channel t) null) enqueue-inkbound))

(defun enqueue-inkbound (channel data)
  "Hand DATA to the worker and return NIL.

The queue is bounded. A turn can take minutes, and the gateway does not stop
sending while it runs, so a full queue drops the oldest waiting message and
counts it rather than growing without a limit. The drop is one log line, which
is loud enough to act on and quiet enough not to stop the channel."
  (bordeaux-threads:with-lock-held ((fluxer-channel-pending-lock channel))
    (when (>= (length (fluxer-channel-pending channel)) +max-pending-messages+)
      (pop (fluxer-channel-pending channel))
      (incf (fluxer-channel-dropped channel))
      (note "the queue is full, so the oldest waiting message was dropped (~D so far)."
            (fluxer-channel-dropped channel)))
    (setf (fluxer-channel-pending channel)
          (nconc (fluxer-channel-pending channel) (list data))))
  (bordeaux-threads:signal-semaphore (fluxer-channel-pending-ready channel))
  nil)

(declaim (ftype (function (fluxer-channel) t) dequeue-inkbound))

(defun dequeue-inkbound (channel)
  "Return the oldest payload waiting for the worker, or NIL when none is."
  (bordeaux-threads:with-lock-held ((fluxer-channel-pending-lock channel))
    (pop (fluxer-channel-pending channel))))

;;;; The worker: the one thread that runs a turn.

(declaim (ftype (function (fluxer-channel t) null) handle-inkbound))

(defun handle-inkbound (channel data)
  "Run one turn for DATA and send its reply. Return NIL.

The turn is an injected function, and a turn that signals, or one that answers
without :OK-P, is one log line and no reply. A worker that dies on the first
bad turn is a channel that stops answering, and the gateway does not care whose
fault it was."
  (let ((message (message-create->msg data))
        (turn (fluxer-channel-turn channel)))
    (if (not (functionp turn))
        (note "there is no turn function, so ~A was not answered."
              (enchiridion.channel:message-digest message))
        (handler-case
            (let ((result (funcall turn message)))
              (cond
                ((not (listp result))
                 (note "the turn answered ~S, which is not a result plist."
                       result))
                ((getf result :ok-p)
                 (send-reply channel
                             (enchiridion.channel:msg-target message)
                             (getf result :reply)))
                (t
                 (note "the turn failed for ~A: ~A"
                       (enchiridion.channel:message-digest message)
                       (or (getf result :error) "no reason given")))))
          (error (condition)
            (note "the turn for ~A signalled: ~A"
                  (enchiridion.channel:message-digest message)
                  condition)))))
  nil)

(declaim (ftype (function (fluxer-channel) null) run-worker))

(defun run-worker (channel)
  "Run every inkbound message through the turn, one at a time, until stopped.

One worker thread, so two turns never run at once and messages are answered in
the order they arrived. The wait is signalled as well as timed, so a lost
wake-up costs +WORKER-WAIT-SECONDS+ and never a message."
  (loop until (fluxer-channel-stopping-p channel)
        do (when (bordeaux-threads:wait-on-semaphore
                  (fluxer-channel-pending-ready channel)
                  :timeout +worker-wait-seconds+)
             (let ((data (dequeue-inkbound channel)))
               (when data
                 (handle-inkbound channel data)))))
  nil)

(declaim (ftype (function (fluxer-channel) null) stop-worker))

(defun stop-worker (channel)
  "Ask the worker to finish, wake it, and join it for a bounded time. Return
NIL."
  (setf (fluxer-channel-stopping-p channel) t)
  (bordeaux-threads:signal-semaphore (fluxer-channel-pending-ready channel))
  (let ((worker (fluxer-channel-worker channel)))
    (when worker
      (join-thread-bounded worker +stop-join-seconds+)
      (setf (fluxer-channel-worker channel) nil)))
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
it and reconnecting would throw away a working transport. The session id goes
with it: a resume after an invalid session is answered with op 9 again, and op
9 is never sent with d true, so the only frame that can work is an Identify."
  (setf (fluxer-channel-session-id channel) nil)
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

The reconnect budget resets here: a session that reached READY is a connection
that worked, and the next failure deserves a fresh count rather than the remains
of an earlier outage's."
  (let ((data (frame-data frame)))
    (when (consp data)
      (setf (fluxer-channel-self-id channel) (ready-user-id data))
      (setf (fluxer-channel-session-id channel)
            (non-blank-string (getf data :session_id))))
    (setf (fluxer-channel-attempt channel) 0)
    (note "connected as ~A." (or (fluxer-channel-self-id channel)
                                 "an unknown user")))
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
because an answer is a reply to whoever asked."
  (cond
    ((not (inkbound-p data (fluxer-channel-self-id channel)))
     (note "dropped a message that is not a direct message from a person."))
    (t
     (handler-case
         (check-sender (channel-allowlist channel) (author-id data))
       (enchiridion.errors:unauthorized (condition)
         (note "~A" condition))
       (error (condition)
         (note "dropped a message that could not be checked: ~A" condition)))))
  nil)

(declaim (ftype (function (fluxer-channel t) null) handle-dispatch))

(defun handle-dispatch (channel frame)
  "Advance the sequence and hand an inkbound direct message to the worker.

The sequence advances for every dispatch, including the ones dropped, because
it is what a heartbeat reports and what a resume replays from. A replayed
dispatch keeps its old number, so a redelivery is dropped here rather than
answered twice."
  (multiple-value-bind (sequence fresh-p)
      (advance-sequence (fluxer-channel-sequence channel) (frame-seq frame))
    (setf (fluxer-channel-sequence channel) sequence)
    (when fresh-p
      (cond
        ((ready-p frame) (note-ready channel frame))
        ((message-create-p frame) (offer-message channel (frame-data frame))))))
  nil)

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
        (when text
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
take effect at once instead of one interval later."
  (let* ((beat 0)
         (interval (or (fluxer-socket-heartbeat-interval socket)
                       +default-heartbeat-interval+))
         (due (+ (real-seconds) (heartbeat-delay 0 interval))))
    (loop
      (when (or (fluxer-channel-stopping-p channel)
                (fluxer-socket-closed-p socket))
        (return))
      (let ((now (real-seconds)))
        (if (< now due)
            (wait-for-close socket (min 1.0 (- due now)))
            (progn
              (send-heartbeat channel socket)
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
  "Close the socket and join the worker. Return NIL.

Safe to run twice and safe on a channel that never started: a stop and an
unwinding start both run it."
  (close-socket (fluxer-channel-socket channel))
  (stop-worker channel)
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
        (enchiridion.channel:channel-live-p channel) t
        (enchiridion.channel:channel-state channel) :live)
  (setf (fluxer-channel-worker channel)
        (bordeaux-threads:make-thread
         (lambda () (run-worker channel))
         :name "enchiridion fluxer worker"))
  (let ((outcome
          (unwind-protect
               (loop
                 (when (fluxer-channel-stopping-p channel)
                   (return :stopped))
                 (let ((code (handler-case (connect-once channel)
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
                            (close-code-note code)))))
                 (incf (fluxer-channel-attempt channel))
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

(declaim (ftype (function (&key (:turn t) (:config t)) fluxer-channel)
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
