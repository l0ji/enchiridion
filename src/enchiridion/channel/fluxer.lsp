;;;; fluxer.lsp --- Fluxer direct-message channel (gateway websocket inbound, REST outbound).
;;;;
;;;; Enforces deny-by-default allowlisting, DM-only filtering, and secret scrubbing on outbound
;;;; replies. Uses bounded reconnects, a single turn worker thread, and a coalescing reaction worker.

(in-package #:enchiridion.channel.fluxer)

;;;; Protocol constants.

(defparameter +rest-base+ "https://api.fluxer.app/v1"
  "The REST base every Fluxer call is made under.")

(defparameter +gateway-path+ "/gateway/bot"
  "The discovery path, under +REST-BASE+, that answers with the websocket url.")

(defparameter +gateway-query+ "?v=1&encoding=json"
  "Query string appended to /gateway/bot URLs to request v1 JSON frames.")

(defparameter +default-heartbeat-interval+ 41250
  "Fallback heartbeat interval in milliseconds before Hello arrives.")

(defparameter +heartbeat-ack-timeout-seconds+ 45
  "Seconds an unacknowledged heartbeat may remain open before closing the socket.
Gateway closes with 4009 after 45s; this detects half-open transports.")

(defparameter +identify-wait-seconds+ 10
  "Seconds to wait for Hello after the websocket handshake.")

(defparameter +message-limit+ 2000
  "The outbound message limit, in UTF-16 code units.")

(defparameter +custom-status-max-characters+ 128
  "The longest custom status text the gateway accepts, in characters.")

(defparameter +custom-status-max-ttl-seconds+ 86400
  "The longest configurable custom status lifetime, in seconds.")

(defparameter +custom-status-max-cooldown-seconds+ 3600
  "The longest configurable custom status cooldown, in seconds.")

(defparameter +presence-online+ "online"
  "Base presence state; gateway requires d.status even when only custom_status changes.")

(defparameter +http-timeout-seconds+ 15
  "Timeout in seconds for a single REST request.")

(defparameter +max-reconnect-attempts+ 5
  "Consecutive reconnect attempts before returning :FAILED to the supervisor.")

(defparameter +reconnect-base-seconds+ 1
  "The first reconnect wait, in seconds. Each later wait doubles it.")

(defparameter +reconnect-max-seconds+ 60
  "Maximum reconnect backoff wait, in seconds.")

(defparameter +reconnect-stable-seconds+ 30
  "Minimum connection duration in seconds before resetting the reconnect budget.
Prevents rapid retry loops when a gateway reaches READY and immediately closes.")

(defparameter +resume-window-seconds+ 60
  "Seconds the gateway retains a session after disconnect for op 6 Resume.")

(defparameter +rate-limit-attempts+ 3
  "Retries after HTTP 429 (route bucket is 20 requests/10s per user per channel).")

(defparameter +max-pending-messages+ 32
  "Maximum inbound messages queued for the turn worker.")

(defparameter +typing-fresh-seconds+ 8)

(defparameter +worker-wait-seconds+ 0.2
  "Semaphore wait timeout in seconds before re-checking the stop flag.")

(defparameter +stop-join-seconds+ 5
  "Seconds to wait for an in-flight turn on stop before destroying the worker thread.")

(defparameter +op-dispatch+ 0
  "The dispatch opcode. Every event arrives as one of these.")

(defparameter +op-heartbeat+ 1
  "Heartbeat opcode; payload is last processed sequence (or null), answered with op 11.")

(defparameter +op-identify+ 2
  "The identify opcode. It authenticates a fresh session on an open socket.")

(defparameter +op-presence+ 3
  "Presence opcode for status/custom_status updates (unacknowledged by gateway).")

(defparameter +op-resume+ 6
  "The resume opcode. It reattaches to a session the gateway still holds.")

(defparameter +op-reconnect+ 7
  "The reconnect opcode. The gateway is asking for a new socket.")

(defparameter +op-invalid-session+ 9
  "Invalid session opcode; socket stays open and requires a fresh Identify, not Resume.")

(defparameter +op-hello+ 10
  "Hello opcode; first frame after handshake, carrying heartbeat_interval.")

(defparameter +op-heartbeat-ack+ 11
  "Heartbeat ACK opcode; gateway closes 4009 if 45s pass without one.")

(defparameter +direct-message-channel-type+ 1
  "channel_type for 1:1 DMs; all other types (group/guild) are ignored.")

(defparameter +fatal-close-codes+ '(4002 4004 4012)
  "Gateway close codes that must not be retried: 4002 (decode error), 4004 (auth failed),
4012 (invalid API version).")

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
  "Human-readable log descriptions for gateway close codes.")

(defparameter +token-env-default+ "FLUXER_BOT_TOKEN"
  "The environment variable name used when the configuration names none.")

;; jzon encodes NIL as false and uses this unexported symbol for JSON null,
;; required by heartbeat frames before the first dispatch.
(defconstant +json-null+ 'com.inuoe.jzon::null
  "Value serialized as JSON null rather than false.")

;;;; Reading a frame.

(declaim (ftype (function (string) t) parse-frame))

(defun parse-frame (text)
  "Parse gateway frame TEXT into a keyword plist, or NIL for non-JSON / missing numeric :op.
Never signals on the read thread."
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
  "Return the dispatch sequence number of FRAME, or NIL. Replays retain their original number."
  (getf frame :s))

(declaim (ftype (function (t) t) frame-data))

(defun frame-data (frame)
  "Return the payload of FRAME, or NIL."
  (getf frame :d))

(declaim (ftype (function (t) (or null integer)) hello-interval))

(defun hello-interval (frame)
  "Return the heartbeat interval in milliseconds from an op 10 Hello FRAME, or NIL."
  (let ((data (frame-data frame)))
    (when (consp data)
      (let ((interval (getf data :heartbeat_interval)))
        (and (integerp interval) (plusp interval) interval)))))

(declaim (ftype (function (t &optional t t) (or null integer)) frame-close-code))

(defun frame-close-code (data &optional start end)
  "Extract the 16-bit close code from raw websocket frame bytes DATA, or NIL.
Unmasks masked close frames (opcode 8). Needed because websocket-driver drops the
close code before firing its :close event."
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
  "Convert VALUE for STRINGIFY: keyword plists become hash tables with downcased keys,
and non-keyword lists become vectors (otherwise plists serialize as JSON arrays)."
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
  "Return VALUE trimmed of whitespace if it is a non-empty string, else NIL."
  (let ((trimmed (and (stringp value)
                      (string-trim '(#\Space #\Tab #\Newline #\Return) value))))
    (and trimmed (plusp (length trimmed)) trimmed)))

(declaim (ftype (function (t) (or null string)) gateway-url))

(defun gateway-url (advertised)
  "Append v=1&encoding=json to ADVERTISED /gateway/bot URL, or return NIL.
Preserves the advertised scheme (ws:// or wss://) for self-hosted deployments."
  (let ((url (non-blank-string advertised)))
    (when url
      (concatenate 'string url (if (find #\? url) "&v=1&encoding=json"
                                   +gateway-query+)))))

(declaim (ftype (function (string) list) identify-frame))

(defun identify-frame (token)
  "Return an op 2 Identify frame for TOKEN.
Omits intents/shard (DMs are account-scoped); :properties is required or gateway closes 4002."
  (list :op +op-identify+
        :d (list :token token
                 :properties (list :os "linux"
                                   :browser "enchiridion"
                                   :device "enchiridion"))))

(declaim (ftype (function (t) list) heartbeat-frame))

(defun heartbeat-frame (sequence)
  "Return an op 1 Heartbeat frame for last processed SEQUENCE, encoding NIL as JSON null
rather than false."
  (list :op +op-heartbeat+
        :d (if (integerp sequence) sequence +json-null+)))

(declaim (ftype (function (string string t) list) resume-frame))

(defun resume-frame (token session-id sequence)
  "Return an op 6 Resume frame for TOKEN, SESSION-ID, and SEQUENCE (valid within 60s)."
  (list :op +op-resume+
        :d (list :token token
                 :session_id session-id
                 :seq (if (integerp sequence) sequence +json-null+))))

(declaim (ftype (function (string (or null string)) list) message-body))

(defun message-body (text reply-to)
  "Return the REST body for TEXT, with a non-pinging reply reference when set."
  (if reply-to
      (list :content text
            :message_reference (list :message_id reply-to)
            :allowed_mentions (list :replied_user nil))
      (list :content text)))

;;;; Custom status validation and frames.
;;;; Enforces single-line, bounded, secret-free proposals with channel-owned TTL and cooldown.

(declaim (ftype (function (character) boolean) control-character-p))

(defun control-character-p (character)
  "Return T when CHARACTER cannot appear in a one line status."
  (let ((code (char-code character)))
    (or (< code 32) (= code 127))))

(declaim (ftype (function (t) (values (or null string) (or null string)))
                validate-custom-status))

(defun validate-custom-status (proposal)
  "Validate PROPOSAL as custom status text; return (values TEXT NIL) or (values NIL REASON).
Requires trimmed non-empty text <= +CUSTOM-STATUS-MAX-CHARACTERS+, no control chars, and no scrubber redactions."
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
  "Return an op 3 presence frame setting custom_status to TEXT, or JSON null to clear.
Always includes d.status = \"online\" as required by the gateway."
  (list :op +op-presence+
        :d (list :status +presence-online+
                 :custom_status (if text
                                    (list :text text)
                                    +json-null+))))

;;;; Who may talk, and what counts as a message.

(declaim (ftype (function (t t) boolean) allowed-p))

(defun allowed-p (allowlist id)
  "Return T iff non-empty string user ID is a member of string list ALLOWLIST.
Deny-by-default: NIL/empty/non-list allowlists and non-string entries match nothing. Keyed on user ID, never username."
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
  "Return string value of KEY in DATA, or \"\" if missing or non-string."
  (let ((value (and (consp data) (getf data key))))
    (if (stringp value) value "")))

(declaim (ftype (function (t) boolean) direct-message-p))

(defun direct-message-p (data)
  "Return T when DATA describes a one-on-one direct message."
  (and (consp data)
       (eql +direct-message-channel-type+ (getf data :channel_type))))

(declaim (ftype (function (t) boolean) guild-event-p))

(defun guild-event-p (data)
  "Return T when DATA carries a non-NIL :guild_id."
  (let ((guild (and (consp data) (getf data :guild_id))))
    (and guild (not (null guild)))))

(declaim (ftype (function (t) boolean) bot-author-p))

(defun bot-author-p (data)
  "Return T when DATA's author has a truthy :bot flag (prevents bot-to-bot loops)."
  (let ((author (and (consp data) (getf data :author))))
    (and (consp author) (not (null (getf author :bot))))))

(declaim (ftype (function (t t) boolean) own-author-p))

(defun own-author-p (data self-id)
  "Return T when DATA's author matches SELF-ID (NIL before READY)."
  (let ((author (author-id data)))
    (and (non-blank-string self-id)
         (non-blank-string author)
         (string= author self-id))))

(declaim (ftype (function (t t) boolean) inkbound-p))

(defun inkbound-p (data self-id)
  "Return T when DATA is a 1:1 DM (no guild_id) from a non-bot user other than SELF-ID."
  (and (direct-message-p data)
       (not (guild-event-p data))
       (not (bot-author-p data))
       (not (own-author-p data self-id))))

(declaim (ftype (function (t) boolean) message-create-p))

(defun message-create-p (frame)
  "Return T when FRAME is a MESSAGE_CREATE dispatch."
  (and (eql +op-dispatch+ (frame-op frame))
       (let ((type (getf frame :t)))
         (and (stringp type) (string= "MESSAGE_CREATE" type)))))

(declaim (ftype (function (t) boolean) ready-p))

(defun ready-p (frame)
  "Return T when FRAME is a READY dispatch."
  (and (eql +op-dispatch+ (frame-op frame))
       (let ((type (getf frame :t)))
         (and (stringp type) (string= "READY" type)))))

(declaim (ftype (function (t) list) message-fields))

(defun message-fields (data)
  "Convert MESSAGE_CREATE payload DATA to the plist expected by NORMALIZE.
Uses channel_id as :target and omits timestamp so NORMALIZE supplies a numeric one."
  (list :channel :fluxer
        :id (text-field data :id)
        :author (or (author-id data) "")
        :target (text-field data :channel_id)
        :text (text-field data :content)))

(declaim (ftype (function (t) t) message-create->msg))

(defun message-create->msg (data)
  "Normalize MESSAGE_CREATE payload DATA into a channel message using the gateway message id."
  (enchiridion.channel:normalize (message-fields data)))

(declaim (ftype (function (t t) t) advance-sequence))

(defun advance-sequence (last incoming)
  "Return (values NEW-LAST FRESH-P) for INCOMING dispatch sequence against LAST.
Drops replays (INCOMING <= LAST); accepts frames with non-integer sequences without advancing LAST."
  (cond
    ((not (integerp incoming)) (values last t))
    ((and (integerp last) (<= incoming last)) (values last nil))
    (t (values incoming t))))

;;;; Cutting a reply into messages.

(defun whitespace-character-p (character)
  (not (null (member character '(#\Space #\Tab #\Newline #\Return #\Page)
                     :test #'char=))))

(defun message-character-width (character)
  ;; Fluxer measures content in UTF-16 code units
  (if (> (char-code character) #xffff) 2 1))

(defun message-width (text)
  (loop for character across text sum (message-character-width character)))

(defun message-end (text start end budget)
  (loop for index from start below end
        do (decf budget (message-character-width (char text index)))
        when (minusp budget) return index
        finally (return end)))

(defstruct markdown-span
  start end body-start body-end fence block-spoiler)

(defparameter +inline-markdown-scanner+
  (cl-ppcre:create-scanner
   (concatenate 'string
                "\\\\[^\\r\\n]|\\[[^\\[\\]\\r\\n]*\\]"
                "\\((?>[^()\\r\\n]*)(?:\\([^()\\r\\n]*\\)(?>[^()\\r\\n]*))*\\)"
                "|<https?://[^\\s<>]+>|https?://[^\\s<>]+"
                "|(?<!`)(`{1,2})(?!`)[^\\r\\n]+?(?<![\\\\`])\\1(?!`)"
                "|(\\|\\|)[^\\r\\n]+?(?<!\\\\)\\2"
                "|(?<![\\w*_~])((?>\\*{1,3}|_{1,3}|~~))(?![\\s*_~])"
                "[^\\r\\n]+?(?<![\\\\\\s])\\3(?![*_~])")))

(defun inline-markdown-spans (text start end)
  (loop for from = start then to
        while (< from end)
        for (match to groups-start groups-end) =
          (multiple-value-list (cl-ppcre:scan +inline-markdown-scanner+ text :start from :end end))
        while match
        for marker = (position-if #'identity groups-start)
        for width = (and marker (- (aref groups-end marker) (aref groups-start marker)))
        unless (and width (not (position-if-not (lambda (c) (char= c (char text match)))
                                                text :start match :end to)))
          collect (make-markdown-span :start match :end to
                                      :body-start (and width (+ match width))
                                      :body-end (and width (- to width)))))

(defun backtick-end (text start end)
  (or (position-if-not (lambda (character) (char= character #\`)) text :start start :end end)
      end))

(defun fence-opener (text start end)
  (loop with inline-width = nil
        for index = start then after
        while (< index end)
        for character = (char text index)
        for after = (case character
                      (#\\ (min end (+ index 2)))
                      (#\` (backtick-end text index end))
                      (otherwise (1+ index)))
        when (char= character #\`)
          do (let ((width (- after index)))
               (cond ((eql width inline-width) (setf inline-width nil))
                     (inline-width nil)
                     ((< width 3) (setf inline-width width))
                     ((not (position #\` text :start after :end end))
                      (return (values index width)))))))

(defun fence-closer (text start end width)
  (loop for tick = (position #\` text :start start :end end)
          then (position #\` text :start after :end end)
        while tick
        for after = (backtick-end text tick end)
        when (>= (- after tick) width)
          do (when (or (= after end) (whitespace-character-p (char text after)))
               (return (values (if (position-if-not #'whitespace-character-p text
                                                    :start start :end tick)
                                   tick
                                   start)
                               after)))
             (return)))

(defun markdown-spans (text &optional (from 0) (end (length text)))
  (let ((prose-start from)
        (opening nil)
        (spans '()))
    (labels ((add-prose (stop)
               (dolist (span (inline-markdown-spans text prose-start stop))
                 (push span spans))))
      (loop for start = from then next
            while (< start end)
            for line-end = (or (position #\Newline text :start start :end end) end)
            for next = (min (1+ line-end) end)
            for first = (position-if-not #'whitespace-character-p text :start start :end line-end)
            do (cond
                 (opening
                  (multiple-value-bind (body-end close)
                      (fence-closer text start line-end (markdown-span-fence opening))
                    (when close
                      (setf (markdown-span-body-end opening) body-end
                            (markdown-span-end opening) close
                            prose-start close)
                      (push opening spans)
                      (setf opening nil))))
                 ((and first (<= (+ first 2) line-end)
                       (string= "||" text :start2 first :end2 (+ first 2))
                       (not (search "||" text :start2 (+ first 2) :end2 line-end)))
                  (let ((close (search "||" text :start2 next :end2 end)))
                    (when close
                      (add-prose start)
                      (setf prose-start (+ close 2)
                            next (1+ (or (position #\Newline text :start prose-start :end end)
                                         (1- end))))
                      (push (make-markdown-span :start start :end prose-start :block-spoiler t
                                                :body-start (+ first 2) :body-end close)
                            spans))))
                 ((and first (< line-end end) (not (char= #\> (char text first))))
                  (multiple-value-bind (tick width) (fence-opener text first line-end)
                    (when tick
                      (let ((opener (if (= tick first) start tick)))
                        (add-prose opener)
                        (setf prose-start opener
                              opening (make-markdown-span :start opener :body-start next
                                                          :fence width))))))))
      (add-prose end))
    (nreverse spans)))

(defun next-chunk-start (text start end keep-indent)
  (let ((visible (position-if-not #'whitespace-character-p text :start start :end end)))
    (if visible
        (let ((newline (position #\Newline text :start start :end visible :from-end t)))
          (cond (newline (1+ newline))
                ((or keep-indent (and (plusp start) (char= (char text (1- start)) #\Newline)))
                 start)
                (t visible)))
        end)))

(defun markdown-cut (text start end spans)
  "Return the best cut in the window, without splitting a protected span."
  (let ((paragraph nil)
        (line nil)
        (space nil))
    (loop for index from start below end
          for span = (first spans)
          for character = (char text index)
          do (cond
               ((and span (= index (markdown-span-start span)))
                (when (> (markdown-span-end span) end)
                  (setf end index)
                  (return))
                (setf index (1- (markdown-span-end span)))
                (pop spans))
               ((char= character #\Newline)
                (when (and line (not (position-if-not #'whitespace-character-p text
                                                      :start line :end index)))
                  (setf paragraph (1+ index)))
                (setf line (1+ index)))
               ((and (> index start) (whitespace-character-p character)
                     (not (whitespace-character-p (char text (1- index)))))
                (setf space index))))
    (or paragraph line space end)))

(declaim (ftype (function (string (integer 2 *)) list) chunk-text))

(defun chunk-text (text limit)
  "Fit Fluxer messages to LIMIT, counting any repeated Markdown delimiters."
  (let ((end (length text))
        (pieces '()))
    (labels ((emit (start end prefix suffix)
               (when (or (plusp (length prefix))
                         (position-if-not #'whitespace-character-p text :start start :end end))
                 (push (with-output-to-string (message)
                         (write-string prefix message)
                         (write-string text message :start start :end end)
                         (write-string suffix message))
                       pieces)))
             (body-room (budget prefix suffix)
               (- budget (message-width prefix) (message-width suffix)))
             (split-verbatim (start end prefix suffix fence)
               (let ((budget (body-room limit prefix suffix))
                     (line-suffix (and fence (format nil "~%~A" suffix))))
                 (when (<= (if fence 3 2) budget)
                   (loop for from = start then cut
                         while (< from end)
                         for hard-end = (message-end text from end budget)
                         for newline = (and fence (position #\Newline text :start from :end hard-end
                                                             :from-end t))
                         for cut = (cond (newline (1+ newline))
                                         (fence (message-end text from hard-end (1- budget)))
                                         (t hard-end))
                         do (emit from cut prefix (if (and fence (not newline)) line-suffix suffix)))
                   t)))
             (split-span (span prefix suffix depth)
               (let* ((start (markdown-span-start span))
                      (end (markdown-span-end span))
                      (body-start (markdown-span-body-start span))
                      (body-end (markdown-span-body-end span))
                      (fence (markdown-span-fence span))
                      (spoiler (markdown-span-block-spoiler span))
                      (code (and body-start (char= (char text start) #\`)))
                      (opener (cond (spoiler (format nil "~A||~%" prefix))
                                    (body-start (concatenate 'string prefix
                                                             (subseq text start body-start)))))
                      (closer (cond (fence (concatenate 'string
                                                       (make-string fence :initial-element #\`)
                                                       suffix))
                                    (spoiler (format nil "~%||~A" suffix))
                                    (body-end (concatenate 'string
                                                           (subseq text body-end end) suffix)))))
                 (cond
                   ((and (or fence code) (split-verbatim body-start body-end opener closer fence)))
                   ((and body-start (not (or fence code)) (< depth 10)
                         (<= 2 (body-room limit opener closer)))
                    (split-range body-start body-end
                                 (if spoiler (markdown-spans text body-start body-end)
                                     (inline-markdown-spans text body-start body-end))
                                 opener closer (1+ depth)))
                   (t (split-range start end nil prefix suffix depth)))))
             (split-range (start end spans prefix suffix &optional (depth 0))
               (loop with budget = (body-room limit prefix suffix)
                     with next = start
                     for first-span = (first spans)
                     for keep-indent = (and first-span (= (markdown-span-start first-span) next)
                                            (or (markdown-span-fence first-span)
                                                (markdown-span-block-spoiler first-span)))
                     for from = (next-chunk-start text next end keep-indent)
                     for hard-end = (message-end text from end budget)
                     while (< from end)
                     do (loop while (and spans (<= (markdown-span-end (first spans)) from))
                              do (pop spans))
                        (let ((span (first spans)))
                          (cond
                            ((= hard-end end)
                             (emit from end prefix suffix)
                             (return))
                            ((and span (= (markdown-span-start span) from)
                                  (> (markdown-span-end span) hard-end))
                             (split-span span prefix suffix depth)
                             (setf next (markdown-span-end span)))
                            (t
                             (setf next (markdown-cut text from hard-end spans))
                             (emit from (if (zerop (length suffix))
                                            next
                                            (1+ (or (position-if-not #'whitespace-character-p text
                                                                    :start from :end next :from-end t)
                                                    (1- from))))
                                   prefix suffix)))))))
      (cond
        ((not (position-if-not #'whitespace-character-p text)) nil)
        ((= end (message-end text 0 end limit)) (list text))
        (t (split-range 0 end (markdown-spans text) "" "")
           (nreverse pieces))))))

(declaim (ftype (function (t (integer 2 *)) list) outbound-chunks))

(defun outbound-chunks (text limit)
  "Scrub secrets from TEXT and chunk to LIMIT UTF-16 code units, or return NIL if empty."
  (let ((clean (enchiridion.llm.secrets:scrub text)))
    (if (stringp clean)
        (chunk-text clean limit)
        nil)))

;;;; Waiting between attempts.

(declaim (ftype (function (integer) real) next-backoff))

(defun next-backoff (attempt)
  "Return exponential backoff in seconds for ATTEMPT, capped at +RECONNECT-MAX-SECONDS+."
  (min +reconnect-max-seconds+
       (* +reconnect-base-seconds+ (expt 2 (max 0 (1- attempt))))))

(declaim (ftype (function (integer integer) integer) next-attempt))

(defun next-attempt (attempt connection-seconds)
  "Return the next reconnect attempt count after a connection lasting CONNECTION-SECONDS.
Resets to 1 if >= +RECONNECT-STABLE-SECONDS+; otherwise increments ATTEMPT."
  (if (>= connection-seconds +reconnect-stable-seconds+)
      1
      (1+ attempt)))

(declaim (ftype (function (t) (or null real)) retry-after-seconds))

(defun retry-after-seconds (body)
  "Parse numeric retry_after seconds from a 429 JSON BODY, or return NIL."
  (handler-case
      (let ((data (enchiridion.llm:parse-json body)))
        (when (consp data)
          (let ((value (getf data :retry_after)))
            (when (and (realp value) (not (minusp value)))
              value))))
    (error () nil)))

(declaim (ftype (function (t t) boolean) resume-window-open-p))

(defun resume-window-open-p (ended now)
  "Return T when universal time NOW is within +RESUME-WINDOW-SECONDS+ of ENDED."
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
  "Read token from environment variable NAME and register it with the secret scrubber before returning, or NIL."
  (let ((token (non-blank-string (enchiridion.compat:environment-value name))))
    (when token
      (enchiridion.llm.secrets:register-secret name token :env)
      token)))

(declaim (ftype (function (&key (:name t)) (or null string)) resolve-token))

(defun resolve-token (&key name)
  "Resolve the Fluxer bot token from secrets store first, then environment variable NAME (default :TOKEN-ENV).
Returns NIL if missing or blank without signalling."
  (let ((name (or (non-blank-string name) (configured-token-env))))
    (or (non-blank-string (enchiridion.llm.secrets:secret-value name))
        (environment-token name))))

;;;; The socket.

(defclass fluxer-socket (websocket-driver.ws.client:client)
  ((close-code :accessor fluxer-socket-close-code :initform nil :type t
               :documentation "Close code captured from raw close frame bytes before websocket-driver drops it.")
   (closed-p :accessor fluxer-socket-closed-p :initform nil :type boolean
             :documentation "True once :close has been handled (guards against duplicate :close events).")
   (hello :accessor fluxer-socket-hello
          :initform (bordeaux-threads:make-semaphore :name "fluxer hello")
          :type t
          :documentation "Semaphore signalled when Hello arrives or the socket closes.")
   (done :accessor fluxer-socket-done
         :initform (bordeaux-threads:make-semaphore :name "fluxer done")
         :type t
         :documentation "Semaphore signalled when the socket closes to wake the heartbeat loop.")
   (heartbeat-interval :accessor fluxer-socket-heartbeat-interval :initform nil
                       :type t
                       :documentation "Heartbeat interval from Hello, in milliseconds.")
   (last-ack :accessor fluxer-socket-last-ack :initform nil :type t
             :documentation "Universal time of the last heartbeat ACK.")
   (state-lock :accessor fluxer-socket-state-lock
               :initform (bordeaux-threads:make-lock "fluxer socket")
               :type t
               :documentation "Guards mutable socket state shared between the read and session threads."))
  (:documentation
   "Gateway websocket client subclass that captures the close code from raw frame bytes
before websocket-driver discards it."))

(defmethod websocket-driver.ws.base:parse :around ((socket fluxer-socket)
                                                   data &key start end)
  "Record the close code from raw frame bytes DATA before delegating to websocket-driver."
  (let ((code (frame-close-code data start end)))
    (when code
      (bordeaux-threads:with-lock-held ((fluxer-socket-state-lock socket))
        (setf (fluxer-socket-close-code socket) code))))
  (call-next-method))

;;;; The channel.

(defclass fluxer-channel (enchiridion.channel:channel)
  ((turn :accessor fluxer-channel-turn :initarg :turn :initform nil :type t
         :documentation "Injected turn handler (lambda (msg) ...) returning a result plist.")
   (reuse :reader fluxer-channel-reuse :initform (enchiridion.channel:make-turn-reuse))
   (followups-p :reader fluxer-channel-followups-p :initarg :followups-p :initform nil
                :type boolean)
   (config :accessor fluxer-channel-config :initarg :config :initform nil
           :type t
           :documentation "Explicit :FLUXER options or full config; NIL uses the active config.")
   (token :accessor fluxer-channel-token :initform nil :type t
          :documentation "Bot token resolved at start; never logged.")
   (socket :accessor fluxer-channel-socket :initform nil :type t
           :documentation "The live gateway socket, or NIL.")
   (send-lock :accessor fluxer-channel-send-lock
              :initform (bordeaux-threads:make-lock "fluxer send")
              :type t
              :documentation "Serializes websocket writes; websocket-driver send is unlocked and interleaving causes 4002.")
   (pending :accessor fluxer-channel-pending :initform nil :type list
            :documentation "FIFO queue of inbound MESSAGE_CREATE payloads for the turn worker.")
   (typing :accessor fluxer-channel-typing :initform nil :type list
           :documentation "Recent typing times by DM route.")
   (active-route :accessor fluxer-channel-active-route :initform nil :type list)
   (pending-lock :accessor fluxer-channel-pending-lock
                 :initform (bordeaux-threads:make-lock "fluxer pending")
                 :type t
                 :documentation "Guards the inbox, active route, typing times, and the stop handoff.")
   (pending-ready :accessor fluxer-channel-pending-ready
                  :initform (bordeaux-threads:make-condition-variable
                             :name "fluxer pending")
                  :type t
                  :documentation "Notifies the worker when work arrives or the channel stops.")
   (worker :accessor fluxer-channel-worker :initform nil :type t
           :documentation "The one thread that runs turns.")
   (stopping-p :accessor fluxer-channel-stopping-p :initform nil :type boolean
               :documentation "True once channel shutdown has been requested.")
   (sequence :accessor fluxer-channel-sequence :initform nil :type t
             :documentation "Last processed dispatch sequence, or NIL before the first dispatch.")
   (self-id :accessor fluxer-channel-self-id :initform nil :type t
            :documentation "Bot user ID from READY, used by the echo guard.")
   (session-id :accessor fluxer-channel-session-id :initform nil :type t
               :documentation "Session ID from READY, used for op 6 Resume.")
   (session-ended :accessor fluxer-channel-session-ended :initform nil :type t
                  :documentation "Universal time when the last transport ended, for the resume window.")
   (attempt :accessor fluxer-channel-attempt :initform 0 :type integer
            :documentation "Consecutive reconnect attempts since the last stable connection.")
   (status-text :accessor fluxer-channel-status-text :initform nil :type t
                :documentation "Active custom status text from an explicit proposal, or NIL.")
   (status-expires :accessor fluxer-channel-status-expires :initform nil :type t
                   :documentation "Universal time when the active custom status expires, or NIL.")
   (status-changed :accessor fluxer-channel-status-changed :initform nil :type t
                   :documentation "Universal time of the last accepted status change, for cooldown.")
   (status-lock :accessor fluxer-channel-status-lock
                :initform (bordeaux-threads:make-lock "fluxer status")
                :type t
                :documentation "Guards custom status state across worker, read thread (READY), and heartbeat expiry.")
   (dropped :accessor fluxer-channel-dropped :initform 0 :type integer
            :documentation "How many messages a full queue has dropped.")
   (reaction-pending :accessor fluxer-channel-reaction-pending
                     :initform (make-hash-table :test #'equal) :type hash-table
                     :documentation "Coalescing map of \"channel/message\" -> newest pending reaction state.")
   (reaction-order :accessor fluxer-channel-reaction-order :initform nil :type list
                   :documentation "FIFO keys in REACTION-PENDING, bounded by +MAX-PENDING-REACTIONS+.")
   (reaction-lock :accessor fluxer-channel-reaction-lock
                  :initform (bordeaux-threads:make-lock "fluxer reactions")
                  :type t
                  :documentation "Guards REACTION-PENDING and REACTION-ORDER.")
   (reaction-ready :accessor fluxer-channel-reaction-ready
                   :initform (bordeaux-threads:make-semaphore
                              :name "fluxer reactions")
                   :type t
                   :documentation "Semaphore counting queued reaction updates.")
   (reaction-worker :accessor fluxer-channel-reaction-worker :initform nil :type t
                    :documentation "The one thread that sends reactions, or NIL.")
   (reaction-stopping-p :accessor fluxer-channel-reaction-stopping-p
                        :initform nil :type boolean
                        :documentation "True once reaction worker drain/shutdown has been requested (separate from STOPPING-P).")
   (reaction-deadline :accessor fluxer-channel-reaction-deadline :initform nil
                      :type t
                      :documentation "REAL-SECONDS deadline for draining reactions during stop, or NIL.")
   (reaction-applied :accessor fluxer-channel-reaction-applied
                     :initform (make-hash-table :test #'equal) :type hash-table
                     :documentation "Map of \"channel/message\" -> last applied emoji to skip redundant DELETEs.")
   (reaction-applied-order :accessor fluxer-channel-reaction-applied-order
                           :initform nil :type list
                           :documentation "FIFO keys in REACTION-APPLIED, bounded by +REACTION-TRACKED-LIMIT+.")
   (active-reactions :accessor fluxer-channel-active-reactions :initform nil
                     :type list
                     :documentation "Reaction keys for messages claimed by the current turn."))
  (:documentation
   "Fluxer DM channel. Decouples websocket reading from turn execution via a single
worker thread and manages cosmetic reactions on a separate coalescing worker."))

(declaim (ftype (function (&key (:turn t) (:config t) (:followups-p boolean))
                           (values fluxer-channel &rest t))
                make-fluxer-channel))

(defun make-fluxer-channel (&key turn config (followups-p nil))
  "Return a stopped Fluxer channel invoking TURN for each DM.
With FOLLOWUPS-P, pass TURN its follow-up callback and any recent work."
  (make-instance 'fluxer-channel :name "fluxer" :turn turn :config config
                 :followups-p followups-p))

;;;; What the configuration says.

(declaim (ftype (function (fluxer-channel) list) channel-options))

(defun channel-options (channel)
  "Return effective :FLUXER options for CHANNEL.
Merges a section plist over the active config key-by-key so partial overrides preserve :ALLOWED-USERS."
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
  "Return the :ALLOWED-USERS list for CHANNEL, or NIL (deny all) if missing or not a list."
  (let ((allowlist (getf (channel-options channel) :allowed-users)))
    (if (listp allowlist) allowlist nil)))

(declaim (ftype (function (fluxer-channel) string) channel-token-env))

(defun channel-token-env (channel)
  "Return the configured :TOKEN-ENV name for CHANNEL, or +TOKEN-ENV-DEFAULT+."
  (or (non-blank-string (getf (channel-options channel) :token-env))
      +token-env-default+))

(declaim (ftype (function (fluxer-channel) boolean) channel-custom-status-p))

(defun channel-custom-status-p (channel)
  "Return T when :CUSTOM-STATUS is explicitly enabled for CHANNEL (default NIL)."
  (not (null (getf (channel-options channel) :custom-status))))

(declaim (ftype (function (fluxer-channel) (or null string))
                custom-status-operator))

(defun custom-status-operator (channel)
  "Return the user ID permitted to update CHANNEL's custom status, or NIL.
Uses :CUSTOM-STATUS-USER if allowlisted; otherwise the sole allowlisted user if there is exactly one.
Multiple allowlisted users without an explicit :CUSTOM-STATUS-USER permits nobody."
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
  "Return integer option KEY within [MINIMUM, MAXIMUM] for CHANNEL, or the shipped default."
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
  "Serializes log lines across the read, turn, and reaction threads.")

(declaim (ftype (function (t integer) string) short-text))

(defun short-text (text limit)
  "Return the first line of TEXT truncated to LIMIT characters with \"...\"."
  (let* ((line (if (stringp text) text (format nil "~S" text)))
         (end (or (position #\Newline line) (length line))))
    (if (< end limit)
        (if (= end (length line))
            line
            (subseq line 0 end))
        (concatenate 'string (subseq line 0 limit) "..."))))

(declaim (ftype (function (string &rest t) null) note))

(defun note (control &rest arguments)
  "Write one flattened, secret-scrubbed log line to *ERROR-OUTPUT* and return NIL."
  (let* ((text (apply #'format nil control arguments))
         ;; Flatten whitespace so untrusted remote strings cannot inject extra log lines.
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
  "Return monotonic clock time in seconds (sub-second resolution for heartbeats/backoff)."
  (/ (get-internal-real-time) internal-time-units-per-second))

(declaim (ftype (function (t t integer) boolean) heartbeat-ack-overdue-p))

(defun heartbeat-ack-overdue-p (sent acked now)
  "Return T when heartbeat sent at universal time SENT is unacknowledged past +HEARTBEAT-ACK-TIMEOUT-SECONDS+
at NOW (ACKED is NIL or earlier than SENT)."
  (and (integerp sent)
       (integerp now)
       (> (- now sent) +heartbeat-ack-timeout-seconds+)
       (or (not (integerp acked))
           (< acked sent))))

(declaim (ftype (function (integer integer &optional t) real) heartbeat-delay))

(defun heartbeat-delay (beat interval &optional jitter)
  "Return seconds to wait before heartbeat BEAT given INTERVAL ms.
Beat 0 waits a random jitter fraction of INTERVAL (or explicit JITTER); later beats wait one full INTERVAL."
  (let ((interval (max 1 interval)))
    (if (plusp beat)
        (/ interval 1000)
        (/ (or jitter (random interval)) 1000))))

(declaim (ftype (function (t real) boolean) join-thread-bounded))

(defun join-thread-bounded (thread seconds)
  "Wait up to SECONDS for THREAD to exit, destroying it if still alive.
Returns T if destroyed, NIL if it exited cleanly."
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
  "Close SOCKET if non-NIL, ignoring errors. Idempotent with the :close handler."
  (when socket
    (ignore-errors (websocket-driver:close-connection socket)))
  nil)

(declaim (ftype (function (fluxer-socket t) null) note-socket-closed))

(defun note-socket-closed (socket code)
  "Idempotently mark SOCKET closed, preserve its close CODE, and signal both DONE and HELLO semaphores."
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
  "Wait up to SECONDS for Hello or socket close; callers disambiguate via CLOSED-P."
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
  "Serialize plist FRAME to JSON and write it to SOCKET under SEND-LOCK to prevent interleaved frames (4002)."
  (let ((text (json-text frame)))
    (bordeaux-threads:with-lock-held ((fluxer-channel-send-lock channel))
      (websocket-driver:send socket text))
    text))

;;;; Custom status state machine (never signals; failures must not affect replies).

(declaim (ftype (function (fluxer-channel &optional integer) boolean)
                custom-status-live-p))

(defun custom-status-live-p (channel &optional (now (get-universal-time)))
  "Return T when CHANNEL has a non-empty custom status with strict expiry NOW < EXPIRES."
  (let ((text (fluxer-channel-status-text channel))
        (expires (fluxer-channel-status-expires channel)))
    (and (stringp text)
         (plusp (length text))
         (integerp expires)
         (< now expires))))

(declaim (ftype (function (fluxer-channel (or null string)) (or null string))
                send-presence))

(defun send-presence (channel text)
  "Send an op 3 presence frame for TEXT (or NIL to clear); returns frame text or NIL if disconnected."
  (let ((socket (fluxer-channel-socket channel)))
    (when socket
      (send-frame channel socket (presence-frame text)))))

(declaim (ftype (function (fluxer-channel t integer) list)
                apply-status-proposal))

(defun apply-status-proposal (channel proposal now)
  "Apply validated status PROPOSAL (text or :CLEAR) at NOW under STATUS-LOCK; return decision plist.
Holds STATUS-LOCK across the socket write to preserve wire ordering and prevent racing with expiry."
  (let ((outcome nil) (reason nil) (frame-p nil) (frame-text nil))
    (bordeaux-threads:with-lock-held ((fluxer-channel-status-lock channel))
      (let ((cooldown (channel-custom-status-cooldown channel))
            (live (custom-status-live-p channel now))
            (changed (fluxer-channel-status-changed channel)))
        ;; Drop expired status before deciding so clears are no-ops and new text does not deduplicate against it.
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
  "Propose PROPOSAL (string, :CLEAR, or NIL) as CHANNEL's custom status, enforcing opt-in,
operator authorization (when AUTHOR is given), validation, cooldown, and deduplication.
Returns (:outcome KEYWORD :reason STRING-OR-NIL :sent BOOL)."
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
  "Clear CHANNEL's custom status if expired at NOW, sending an op 3 clear if connected.
Returns (:outcome (:expired|:unchanged) :reason STRING-OR-NIL :sent BOOL)."
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
  "Reapply a still-live custom status on a fresh READY session without resetting cooldown;
drops statuses that expired while disconnected or if :CUSTOM-STATUS was disabled."
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
           ;; Hold STATUS-LOCK across the write so expiry cannot race republish.
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
  "Clear session ID and dispatch sequence cursor. Must run on fresh Identify so the monotonic
sequence filter does not drop new-session dispatches (which restart at 1) as replays."
  (setf (fluxer-channel-sequence channel) nil
        (fluxer-channel-session-id channel) nil)
  nil)

(declaim (ftype (function (fluxer-channel fluxer-socket) string) send-identify))

(defun send-identify (channel socket)
  "Reset session state and send op 2 Identify on SOCKET."
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
  "Return REST headers with Bot authorization scheme (never placed in URLs)."
  (list (cons :authorization (format nil "Bot ~A" token))
        (cons :content-type "application/json")
        (cons :user-agent "enchiridion/0.1.0")))

(declaim (ftype (function (string) (or null string)) discover-gateway))

(defun discover-gateway (token)
  "Fetch websocket URL via GET /gateway/bot; logs and returns NIL on error."
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

(declaim (ftype (function (t) (or null string)) reply-anchor))

(defun reply-anchor (data)
  "Return the gateway ID for a default or reply message."
  (when (member (getf data :type 0) '(0 19))
    (message-id data)))

(declaim (ftype (function (string string string (or null string))
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

(defun post-message (token channel-id text reply-to)
  "Post TEXT to CHANNEL-ID, dropping the reference if its message is gone."
  (let ((url (concatenate 'string +rest-base+ "/channels/" channel-id "/messages"))
        (headers (bot-headers token))
        (rate-limits 0))
    (loop for attempt from 1 do
      (when (and *send-channel* (fluxer-channel-stopping-p *send-channel*))
        (error 'enchiridion.errors:transport-error :detail "reply stopped"))
      (handler-case
          (let ((reply (enchiridion.llm::bounded-http-request
                        (enchiridion.llm:make-http-request
                         :url url :headers headers
                         :body (json-text (message-body text reply-to))
                         :timeout +http-timeout-seconds+)
                        :body-limit 65536)))
            ;; A 2xx accepted the message even if its response cannot be parsed
            (return (message-id (ignore-errors (enchiridion.llm:parse-json reply)))))
        (dexador.error:http-request-failed (failure)
          (let ((status (dexador.error:response-status failure))
                (payload (dexador.error:response-body failure)))
            (cond
              ((and (eql status 429) (< rate-limits +rate-limit-attempts+))
               (incf rate-limits)
               (wait-to-retry (or (retry-after-seconds payload)
                                  (next-backoff rate-limits))))
              ((and reply-to (eql status 404)
                    (equal "UNKNOWN_MESSAGE"
                           (ignore-errors
                             (getf (enchiridion.llm:parse-json payload) :code))))
               (note "reply target ~A was not found; sending without the reference."
                     reply-to)
               (setf reply-to nil))
              (t
               (error 'enchiridion.errors:transport-error
                      :status status
                      :detail (format nil "~D after ~D attempt~:P: ~A"
                                      status attempt (error-note payload)))))))))))

(declaim (ftype (function (fluxer-channel string string &key (:reply-to (or null string)))
                          list)
                send-reply))

(defun send-reply (channel target text &key reply-to)
  "Send scrubbed TEXT in chunks, referencing REPLY-TO on the first chunk only."
  (let ((*send-channel* channel)
        (*send-deadline* (+ (real-seconds) +reply-deadline-seconds+)))
    (enchiridion.compat:with-deadline
        (+reply-deadline-seconds+
         :on-timeout (error 'enchiridion.errors:transport-error :detail "reply timed out"))
      (loop for piece in (outbound-chunks text +message-limit+)
            for anchor = (non-blank-string reply-to) then nil
            for id = (post-message (fluxer-channel-token channel) target piece anchor)
            when id collect id))))

;;;; Reaction lifecycle: ⏳ queued -> 🔧 processing -> cleared on delivery (or ⚠️ on failure/eviction).
;;;; Cosmetic REST calls run on a dedicated worker with a bounded, per-message coalescing queue
;;;; and a bounded applied-marker table to skip redundant DELETEs.

(defparameter +queued-reaction+ "⏳"
  "The marker on a direct message that is waiting for the worker.")

(defparameter +processing-reaction+ "🔧"
  "The marker on a direct message whose turn is running.")

(defparameter +failed-reaction+ "⚠️"
  "Marker left on a DM whose turn/reply failed or was evicted from the queue.")

(defparameter +reaction-states+ '(:queued :processing :failed :delivered)
  "Valid reaction states (:DELIVERED clears the active marker).")

(defparameter +max-pending-reactions+ 128
  "Maximum distinct messages queued for the reaction worker (coalesced per message).")

(defparameter +reaction-tracked-limit+ 512
  "Maximum entries in the applied-reaction table (FIFO-evicted to bound memory).")

(defparameter +reaction-drain-seconds+ 1
  "Seconds spent draining final reaction updates (e.g., failure markers) during stop.")

(defparameter +reaction-stop-seconds+ 1
  "Seconds to wait for the reaction thread to exit after drain before destroying it.")

(defparameter +reaction-timeout-seconds+ 5
  "HTTP timeout in seconds for a single cosmetic reaction request.")

(declaim (ftype (function (t) (or null string)) message-reaction-key))

(defun message-reaction-key (data)
  "Return \"channel_id/message_id\" key for DATA, or NIL if either ID is missing."
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
  "RFC 3986 unreserved characters; all other UTF-8 octets (including emoji) are percent-encoded.")

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
  "Return the PUT/DELETE reaction endpoint URL for KEY and EMOJI (using literal @me)."
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
  "PUT (when ADD-P) or DELETE EMOJI on KEY; return T on success.
Treats 404 as success, retries 429 up to +RATE-LIMIT-ATTEMPTS+ times, and logs/returns NIL on other errors."
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
  "Transition KEY to STATE using the applied-marker table to skip redundant DELETEs.
If removing the prior marker fails, aborts before adding the new one to avoid leaving two markers."
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
             applied
             (progn
               (when applied (forget-reaction channel key))
               (when (reaction-call channel key want t)
                 (track-reaction channel key want))
               (applied-reaction channel key))))))))

;;;; The queue between the two callers and the reaction thread.

(declaim (ftype (function (t t keyword) null) enqueue-reaction))

(defun enqueue-reaction (channel key state)
  "Non-blocking enqueue of STATE for KEY on the reaction worker.
Coalesces by replacing any queued state for KEY; drops with a log line if full."
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
  "Rewrite all queued :QUEUED/:PROCESSING reaction states to :FAILED (leaving :DELIVERED intact)."
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
  "Drain queued reaction states until stopped and either empty or past +REACTION-DRAIN-SECONDS+."
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
  "Mark pending reactions failed, drain up to +REACTION-DRAIN-SECONDS+, and bounded-join the reaction thread."
  (let ((worker (fluxer-channel-reaction-worker channel)))
    (when worker
      (fail-pending-reactions channel)
      (setf (fluxer-channel-reaction-stopping-p channel) t
            (fluxer-channel-reaction-deadline channel)
            (+ (real-seconds) +reaction-drain-seconds+))
      (bordeaux-threads:signal-semaphore (fluxer-channel-reaction-ready channel))
      (join-thread-bounded worker +reaction-stop-seconds+)
      ;; Thread is stopped; avoid taking REACTION-LOCK in case it was destroyed while holding it.
      (let ((left (length (fluxer-channel-reaction-order channel))))
        (setf (fluxer-channel-reaction-pending channel) (make-hash-table :test #'equal)
              (fluxer-channel-reaction-order channel) nil)
        (when (plusp left)
          (note "~D reaction~:P were not sent before the stop." left)))
      (setf (fluxer-channel-reaction-worker channel) nil)))
  nil)

;;;; The queue between the read thread and the worker.

(defun dm-route (target author)
  (when (and (non-blank-string target) (non-blank-string author))
    (list target author)))

(defun inbound-route (data)
  (dm-route (text-field data :channel_id) (author-id data)))

(defun clear-typing (channel route)
  "Remove ROUTE's typing time with the inbox lock held."
  (when route
    (setf (fluxer-channel-typing channel)
          (delete route (fluxer-channel-typing channel) :key #'car :test #'equal))))

(declaim (ftype (function (fluxer-channel t) null) enqueue-inkbound))

(defun enqueue-inkbound (channel data)
  "Queue DATA, evicting the oldest waiting message if full."
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
            (clear-typing channel (inbound-route data))
            (setf (fluxer-channel-pending channel)
                  (nconc (fluxer-channel-pending channel) (list data)))
            (bordeaux-threads:condition-notify (fluxer-channel-pending-ready channel)))))
    (cond
      (refused
       (note "the channel is stopping, so a message was not queued.")
       (enqueue-reaction channel (message-reaction-key data) :failed))
      (dropped
       (note "the queue is full, so the oldest waiting message was dropped (~D so far)."
             (fluxer-channel-dropped channel))
       (enqueue-reaction channel (message-reaction-key dropped) :failed))))
  nil)

(declaim (ftype (function (fluxer-channel &key (:wait-p boolean)) t) claim-inkbound))

(defun claim-inkbound (channel &key (wait-p nil))
  "Pop the oldest waiting payload, optionally waiting until work or shutdown."
  (let ((lock (fluxer-channel-pending-lock channel)))
    (bordeaux-threads:with-lock-held (lock)
      (loop
        (when (fluxer-channel-stopping-p channel)
          (return nil))
        (when (fluxer-channel-pending channel)
          (return (pop (fluxer-channel-pending channel))))
        (unless wait-p
          (return nil))
        (bordeaux-threads:condition-wait (fluxer-channel-pending-ready channel) lock)))))

;;;; The worker: the one thread that runs a turn.

(defun typing-expires-at (channel route)
  (let ((entry (assoc route (fluxer-channel-typing channel) :test #'equal)))
    (when entry (+ (cdr entry) +typing-fresh-seconds+))))

(defun claim-followups (channel select route grace
                        &key (clock #'real-seconds) (wait #'bordeaux-threads:condition-wait))
  "Claim matching payloads. Wait for fresh typing at most GRACE seconds."
  (let ((lock (fluxer-channel-pending-lock channel))
        (deadline (when (plusp grace) (+ (funcall clock) grace)))
        (waited nil))
    (bordeaux-threads:with-lock-held (lock)
      (loop
        (when (fluxer-channel-stopping-p channel)
          (return (values nil waited)))
        (multiple-value-bind (claimed waiting room-p)
            (funcall select (fluxer-channel-pending channel))
          (when claimed
            (setf (fluxer-channel-pending channel) waiting)
            (dolist (data claimed)
              (let ((key (message-reaction-key data)))
                (when key (push key (fluxer-channel-active-reactions channel)))))
            (return (values claimed waited)))
          (let* ((now (funcall clock))
                 (typing-end (when (and deadline room-p)
                               (typing-expires-at channel route)))
                 (wait-until (when typing-end (min deadline typing-end))))
            (unless (and wait-until (< now wait-until))
              (return (values nil waited)))
            (setf waited t)
            (funcall wait (fluxer-channel-pending-ready channel)
                     lock :timeout (- wait-until now))))))))

(defun make-turn-steer (channel route)
  "Return the follow-up callback for an authenticated DM route."
  (when route
    (labels ((text (data) (text-field data :content))
             (matches (data)
               (and (equal route (inbound-route data))
                    (non-blank-string (text data)))))
      (let ((select (enchiridion.channel:make-followup-selector #'matches #'text))
            (grace (status-seconds channel :typing-wait-seconds 0 30))
            (held-p nil))
        (lambda (phase)
          (multiple-value-bind (claimed waited)
              (claim-followups channel select route
                               (if (and (eq phase :before-final) (not held-p)) grace 0))
            (when waited (setf held-p t))
            (mapcar #'text claimed)))))))

(defun set-active-reactions (channel keys &optional route)
  (bordeaux-threads:with-lock-held ((fluxer-channel-pending-lock channel))
    (let ((active (fluxer-channel-active-route channel)))
      (unless (or route (member active (fluxer-channel-pending channel)
                                :key #'inbound-route :test #'equal))
        (clear-typing channel active)))
    (setf (fluxer-channel-active-reactions channel) keys
          (fluxer-channel-active-route channel) route)))

(declaim (ftype (function (fluxer-channel t) null) handle-inkbound))

(defun handle-inkbound (channel data)
  "Execute one turn for DATA and send its reply, catching errors so the worker stays alive.
Marks :DELIVERED only after all reply chunks succeed; otherwise marks :FAILED."
  (let* ((message (message-create->msg data))
         (key (message-reaction-key data))
         (route (inbound-route data))
         (reuse (fluxer-channel-reuse channel))
         (turn (fluxer-channel-turn channel))
         (completed nil))
    (unwind-protect
         (progn
           (set-active-reactions channel (when key (list key)) route)
           (enqueue-reaction channel key :processing)
           (cond
             ((not (functionp turn))
              (note "there is no turn function, so ~A was not answered."
                    (enchiridion.channel:message-digest message))
              (enqueue-reaction channel key :failed))
             ((handler-case
                  (let ((result (if (fluxer-channel-followups-p channel)
                                     (funcall turn message (make-turn-steer channel route)
                                              (enchiridion.channel:take-turn-work reuse route))
                                     (funcall turn message))))
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
                      ((getf result :silent-p)
                       (note "chose not to reply to message ~A."
                             (enchiridion.channel:msg-id message))
                       t)
                      ((not (non-blank-string (getf result :reply)))
                       (note "the turn returned no reply for message ~A."
                             (enchiridion.channel:msg-id message))
                       nil)
                      (t
                       (handler-case
                           (progn
                             (send-reply channel
                                         (enchiridion.channel:msg-target message)
                                         (getf result :reply)
                                         :reply-to (reply-anchor data))
                             (when route
                               (enchiridion.channel:remember-turn-work reuse route (getf result :work)))
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
              (dolist (claimed (fluxer-channel-active-reactions channel))
                (enqueue-reaction channel claimed :delivered)))
             (t
              (dolist (claimed (fluxer-channel-active-reactions channel))
                (enqueue-reaction channel claimed :failed))))
           (setf completed t))
      ;; Leave active reactions if destroyed mid-turn so STOP-WORKER marks it failed.
      (when completed
        (set-active-reactions channel nil))))
  nil)

(declaim (ftype (function (fluxer-channel) null) run-worker))

(defun run-worker (channel)
  "Process queued messages sequentially until the channel stops."
  (loop for data = (claim-inkbound channel :wait-p t)
        while data do (handle-inkbound channel data))
  nil)

(declaim (ftype (function (fluxer-channel) null) stop-worker))

(defun stop-worker (channel)
  "Set STOPPING-P, wake and bounded-join the turn worker, and mark any destroyed or queued
messages :FAILED. Must run before STOP-REACTION-WORKER so failure markers can be drained."
  (bordeaux-threads:with-lock-held ((fluxer-channel-pending-lock channel))
    (setf (fluxer-channel-stopping-p channel) t)
    (bordeaux-threads:condition-notify (fluxer-channel-pending-ready channel)))
  (let ((worker (fluxer-channel-worker channel))
        (abandoned nil)
        (active nil)
        (waiting nil))
    (when worker
      (setf abandoned (join-thread-bounded worker +stop-join-seconds+)
            (fluxer-channel-worker channel) nil))
    (bordeaux-threads:with-lock-held ((fluxer-channel-pending-lock channel))
      (setf active (fluxer-channel-active-reactions channel)
            (fluxer-channel-active-reactions channel) nil
            waiting (fluxer-channel-pending channel)
            (fluxer-channel-pending channel) nil
            (fluxer-channel-active-route channel) nil
            (fluxer-channel-typing channel) nil))
    (when abandoned
      (dolist (key active)
        (enqueue-reaction channel key :failed)))
    (dolist (data waiting)
      (enqueue-reaction channel (message-reaction-key data) :failed))
    (when waiting
      (note "~D waiting message~:P dropped at the stop." (length waiting))))
  nil)

;;;; Read-thread frame handlers (must stay non-blocking so heartbeats never stall).

(declaim (ftype (function (t) (or null string)) message-text))

(defun message-text (message)
  "Return MESSAGE if it is a text string, else NIL (binary frames are ignored)."
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
  "Re-identify on the same open socket after op 9 (session is unresumable)."
  (unless (fluxer-channel-stopping-p channel)
    (send-identify channel socket))
  nil)

(declaim (ftype (function (fluxer-socket) null) note-reconnect-requested))

(defun note-reconnect-requested (socket)
  "Log op 7 reconnect request and close SOCKET so the reconnect loop resumes or re-identifies."
  (note "the gateway asked for a reconnect.")
  (close-socket socket)
  nil)

(declaim (ftype (function (fluxer-channel t) null) note-ready))

(declaim (ftype (function (t) (or null string)) ready-user-id))

(defun ready-user-id (data)
  "Extract the bot's user ID from READY payload DATA (:user/:id or :user_id), or NIL."
  (or (let ((user (and (consp data) (getf data :user))))
        (and (consp user) (non-blank-string (getf user :id))))
      (non-blank-string (and (consp data) (getf data :user_id)))))

(declaim (ftype (function (fluxer-channel t) null) note-ready))

(defun note-ready (channel frame)
  "Record self ID and session ID from READY and reapply any live custom status.
Does not reset reconnect attempts (handled by NEXT-ATTEMPT after +RECONNECT-STABLE-SECONDS+)."
  (let ((data (frame-data frame)))
    (when (consp data)
      (setf (fluxer-channel-self-id channel) (ready-user-id data))
      (setf (fluxer-channel-session-id channel)
            (non-blank-string (getf data :session_id))))
    (note "connected as ~A." (or (fluxer-channel-self-id channel)
                                 "an unknown user"))
    (reapply-custom-status channel))
  nil)

(declaim (ftype (function (list t) t) check-sender))

(defun check-sender (allowlist id)
  "Return ID if allowlisted, otherwise signal ENCHIRIDION.ERRORS:UNAUTHORIZED."
  (unless (allowed-p allowlist id)
    (error 'enchiridion.errors:unauthorized :channel (or id "an unknown sender")))
  id)

(declaim (ftype (function (fluxer-channel t) null) offer-message))

(defun offer-message (channel data)
  "Filter and allowlist-check MESSAGE_CREATE DATA, logging refusals without replying.
Enqueues :QUEUED before handing DATA to the worker so :PROCESSING cannot overtake it."
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
  "Reset the sequence cursor if READY carries a new session_id (numbering restarts at 1);
resumed sessions keep their existing cursor."
  (let* ((data (frame-data frame))
         (session (non-blank-string (and (consp data) (getf data :session_id)))))
    (when (and session
               (non-blank-string (fluxer-channel-session-id channel))
               (not (string= session (fluxer-channel-session-id channel))))
      (note-fresh-session channel)))
  nil)

(defun note-typing (channel data)
  "Record typing only for the sender of an active or queued DM."
  (let ((route (and (consp data) (not (guild-event-p data))
                    (dm-route (text-field data :channel_id) (text-field data :user_id)))))
    (when route
      (bordeaux-threads:with-lock-held ((fluxer-channel-pending-lock channel))
        (when (and (not (fluxer-channel-stopping-p channel))
                   (or (equal route (fluxer-channel-active-route channel))
                       (member route (fluxer-channel-pending channel)
                               :key #'inbound-route :test #'equal)))
          (clear-typing channel route)
          (when (> (length (fluxer-channel-typing channel)) +max-pending-messages+)
            (setf (fluxer-channel-typing channel) (butlast (fluxer-channel-typing channel))))
          (push (cons route (real-seconds)) (fluxer-channel-typing channel))
          (bordeaux-threads:condition-notify (fluxer-channel-pending-ready channel)))))))

(declaim (ftype (function (fluxer-channel t) null) handle-dispatch))

(defun handle-dispatch (channel frame)
  "Advance the dispatch sequence and route ready, message, and typing events.
Checks READY session change before filtering so a stale cursor cannot drop a new session's READY."
  (when (ready-p frame)
    (note-session-start channel frame))
  (multiple-value-bind (sequence fresh-p)
      (advance-sequence (fluxer-channel-sequence channel) (frame-seq frame))
    (setf (fluxer-channel-sequence channel) sequence)
    (when fresh-p
      (cond
        ((ready-p frame) (note-ready channel frame))
        ((message-create-p frame) (offer-message channel (frame-data frame)))
        ((equal "TYPING_START" (getf frame :t)) (note-typing channel (frame-data frame))))))
  nil)

(declaim (ftype (function (fluxer-channel t) boolean) current-socket-p))

(defun current-socket-p (channel socket)
  "Return T when SOCKET is CHANNEL's active socket (or none is recorded yet).
Ignores late frames from destroyed prior sockets so they cannot corrupt the live sequence cursor."
  (let ((current (fluxer-channel-socket channel)))
    (or (null current) (eq current socket))))

(declaim (ftype (function (fluxer-channel fluxer-socket t) null) handle-text))

(defun handle-text (channel socket message)
  "Parse and dispatch one inbound JSON text frame on the read thread, catching all errors."
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
  "Return T when CHANNEL has a session ID within +RESUME-WINDOW-SECONDS+ of disconnect."
  (and (non-blank-string (fluxer-channel-session-id channel))
       (resume-window-open-p (fluxer-channel-session-ended channel)
                             (get-universal-time))))

(declaim (ftype (function (fluxer-channel string) (or null fluxer-socket))
                open-socket))

(defun open-socket (channel url)
  "Create fluxer-socket, attach handlers before START-CONNECTION, and return it (or NIL on error)."
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
  "Send heartbeats on SOCKET until closed or stopped, slicing waits at 1s for responsiveness
and custom-status expiry. Closes SOCKET if an ACK is overdue past +HEARTBEAT-ACK-TIMEOUT-SECONDS+
to detect half-open transports."
  (let* ((beat 0)
         (interval (or (fluxer-socket-heartbeat-interval socket)
                       +default-heartbeat-interval+))
         (sent nil)
         (due (+ (real-seconds) (heartbeat-delay 0 interval))))
    (loop
      (when (or (fluxer-channel-stopping-p channel)
                (fluxer-socket-closed-p socket))
        (return))
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
  "Send Resume (if within window) or Identify, then run the heartbeat loop."
  (if (resume-open-p channel)
      (send-resume channel socket)
      (send-identify channel socket))
  (run-heartbeats channel socket)
  nil)

(declaim (ftype (function (fluxer-socket) null) note-pre-hello-close))

(defun note-pre-hello-close (socket)
  "Log a gateway close that occurred before Hello."
  (note "the gateway closed before Hello: ~A."
        (close-code-note (fluxer-socket-close-code socket)))
  nil)

(declaim (ftype (function (fluxer-channel) t) connect-once))

(defun connect-once (channel)
  "Run one gateway connection attempt; return close code, :CLOSED, or NIL on discovery/connect failure."
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
  "Sleep NEXT-BACKOFF seconds in stop-aware slices."
  (let ((deadline (+ (real-seconds) (next-backoff attempt))))
    (loop while (and (not (fluxer-channel-stopping-p channel))
                     (< (real-seconds) deadline))
          do (sleep (min 0.5 (max 0.05 (- deadline (real-seconds)))))))
  nil)

;;;; The protocol.

(declaim (ftype (function (fluxer-channel) null) shutdown))

(defun shutdown (channel)
  "Idempotently close the socket, stop the turn worker, and drain the reaction worker.
Stops the turn worker before the reaction worker so failure markers can still be sent."
  (close-socket (fluxer-channel-socket channel))
  (stop-worker channel)
  (stop-reaction-worker channel)
  nil)

(defmethod enchiridion.channel:channel-start ((channel fluxer-channel) &key config)
  "Start CHANNEL and block until stopped or reconnect budget (+MAX-RECONNECT-ATTEMPTS+) is exhausted.
Logs and marks :FAILED without signalling if token or turn function is missing.
Fatal close codes stop retrying immediately."
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
        (fluxer-channel-active-reactions channel) nil
        (fluxer-channel-active-route channel) nil
        (fluxer-channel-typing channel) nil
        ;; Clear any stale socket so CURRENT-SOCKET-P does not misclassify frames.
        (fluxer-channel-socket channel) nil
        (enchiridion.channel:channel-live-p channel) t
        (enchiridion.channel:channel-state channel) :live)
  (enchiridion.channel:clear-turn-work (fluxer-channel-reuse channel))
  ;; Start reaction worker before turn worker so queued messages have a reaction consumer.
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
  "Idempotently stop CHANNEL and set its state to :STOPPED."
  (shutdown channel)
  (setf (enchiridion.channel:channel-live-p channel) nil
        (enchiridion.channel:channel-state channel) :stopped)
  channel)

(defmethod enchiridion.channel:channel-send ((channel fluxer-channel) target text
                                             &key reply-to)
  "Send TEXT to DM channel TARGET and return the accepted message IDs."
  (unless (fluxer-channel-token channel)
    (error 'enchiridion.errors:configuration-error
           :key "fluxer"
           :detail "the channel is not started, so there is no token to send with."))
  (send-reply channel target text :reply-to reply-to))

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
  "Create, start, and block on a Fluxer channel; return it when stopped."
  (let ((channel (make-fluxer-channel :turn turn :config config)))
    (enchiridion.channel:channel-start channel)
    channel))

(declaim (ftype (function (t) t) stop-fluxer))

(defun stop-fluxer (channel)
  "Stop CHANNEL and return it."
  (enchiridion.channel:channel-stop channel))
