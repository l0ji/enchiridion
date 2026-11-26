;;;; protocol.lsp --- Normalized message struct and channel protocol.
;;;;
;;;; All channels normalize inbound traffic into MSG and implement the four
;;;; channel generic functions. The state slot accessor is CHANNEL-STATE to
;;;; avoid colliding with the CHANNEL-STATUS generic function.

(in-package #:enchiridion.channel)

;;;; The message.

;; Every slot has a type and default so callers only supply known fields.
(defstruct msg
  (:id "" :type string)          ; the channel's own id for this message
  (:channel :cli :type keyword)  ; where it came from
  (:target "" :type string)      ; where a reply goes
  (:thread "" :type string)      ; thread id, empty when there is none
  (:author "" :type string)      ; who sent it
  (:text "" :type string)        ; the body
  (:ts 0 :type fixnum)           ; unix time, zero until NORMALIZE fills it
  (:reply-to "" :type string))   ; the message this one answers

;;;; Identifiers.

(defvar *message-counter* 0
  "How many messages NORMALIZE has numbered. One counter for every channel, so
two channels cannot mint the same id.")

(declaim (ftype (function (keyword) string) next-message-id))

(defun next-message-id (channel)
  "Return the next message id for CHANNEL, a short string such as cli-1."
  (format nil "~(~A~)-~D" channel (incf *message-counter*)))

;;;; Normalizing.

(declaim (ftype (function (&rest t) msg) normalize))

(defun normalize (&rest arguments)
  "Return a MSG built from ARGUMENTS (either a single plist or keyword args).
Mints an id via NEXT-MESSAGE-ID when absent/empty and fills :ts via
GET-UNIVERSAL-TIME when absent/zero."
  (let* ((plist (cond
                  ((null arguments) '())
                  ((listp (first arguments)) (first arguments))
                  (t arguments)))
         (channel (or (getf plist :channel) :cli))
         (id (getf plist :id))
         (ts (getf plist :ts 0)))
    (make-msg
     :id (if (and (stringp id) (plusp (length id))) id (next-message-id channel))
     :channel channel
     :target (or (getf plist :target) "")
     :thread (or (getf plist :thread) "")
     :author (or (getf plist :author) "")
     :text (or (getf plist :text) "")
     :ts (if (and (integerp ts) (plusp ts)) ts (get-universal-time))
     :reply-to (or (getf plist :reply-to) ""))))

;;;; In-flight follow-ups.

(declaim (ftype (function (function function &key
                           (:count (integer 0 *)) (:chars (integer 0 *)))
                          function)
                make-followup-selector))

(defun make-followup-selector (same-route-p message-text &key (count 4) (chars 16000))
  "Return a selector for one turn, with a shared COUNT and CHARS budget.
Given a pending list, return the claimed messages and the remaining list in order.
Call while holding the queue lock; leave an oversized match and later matches queued."
  (lambda (pending)
    (let ((claimed '()) (waiting '()))
      (loop for tail on pending
            for message = (first tail)
            do (cond
                 ((zerop count)
                  (return (values (nreverse claimed) (nreconc waiting tail))))
                 ((funcall same-route-p message)
                  (let ((size (length (funcall message-text message))))
                    (when (> size chars)
                      (return (values (nreverse claimed) (nreconc waiting tail))))
                    (push message claimed)
                    (decf count)
                    (decf chars size)))
                 (t (push message waiting)))
            finally (return (values (nreverse claimed) (nreverse waiting)
                                    (and (plusp count) (plusp chars))))))))

(defstruct turn-reuse
  route
  work
  (expires-at 0))

(defun turn-time ()
  (/ (get-internal-real-time) internal-time-units-per-second))

(defun remember-turn-work (reuse route work &key (now (turn-time)))
  "Keep the last published turn's work for up to 30 seconds."
  (setf (turn-reuse-route reuse) route
        (turn-reuse-work reuse) work
        (turn-reuse-expires-at reuse) (+ now 30)))

(defun take-turn-work (reuse route &key (now (turn-time)))
  "Consume saved work, returning it only to a matching, recent turn."
  (prog1 (and route (equal route (turn-reuse-route reuse))
              (< now (turn-reuse-expires-at reuse))
              (turn-reuse-work reuse))
    (setf (turn-reuse-route reuse) nil
          (turn-reuse-work reuse) nil)))

;;;; The digest.

(defparameter +message-digest-length+ 60
  "Maximum characters kept from the first line by MESSAGE-DIGEST.")

(declaim (ftype (function (string) string) digest-text))

(defun digest-text (text)
  "Return the first line of TEXT, cut to +MESSAGE-DIGEST-LENGTH+ characters and
marked with an ellipsis when it was cut."
  (let* ((end (or (position #\Newline text) (length text)))
         (line (subseq text 0 end)))
    (when (> (length line) +message-digest-length+)
      (setf line (concatenate 'string (subseq line 0 +message-digest-length+) "...")))
    line))

(declaim (ftype (function (msg) string) message-digest))

(defun message-digest (message)
  "Return a one-line summary of MESSAGE (channel/author: truncated first line)."
  (format nil "~(~A~)/~A: ~A"
          (msg-channel message)
          (msg-author message)
          (digest-text (msg-text message))))

;;;; The channel class.

(defclass channel ()
  ((name :accessor channel-name :initarg :name :initform "" :type string
         :documentation "The channel's name, as config and the status file write it.")
   (live-p :accessor channel-live-p :initarg :live-p :initform nil :type boolean
           :documentation "True while the channel is accepting traffic.")
   (state :accessor channel-state :initarg :state :initform :stopped :type keyword
          :documentation "Where the channel is: :stopped, :starting, :live, :unavailable, or :failed.")
   (start-error :accessor channel-start-error :initform nil :type (or null string)
                :documentation "Scrubbed condition text from the last failed start, or NIL.")
   (thread :accessor channel-thread :initarg :thread :initform nil :type t
           :documentation "The thread the channel runs on, or NIL when it has none."))
  (:documentation "Base CLOS class for all channel implementations."))

;;;; Defining a channel.

(defmacro define-channel (name &key constructor)
  "Define a CHANNEL subclass NAME and its constructor (default MAKE-<NAME> in
NAME's package), accepting the four base CHANNEL slots."
  (let ((constructor (or constructor
                         (intern (format nil "MAKE-~A" (symbol-name name))
                                 (symbol-package name)))))
    `(progn
       (defclass ,name (channel) ())
       (defun ,constructor (&key (name ,(string-downcase (symbol-name name)))
                              (live-p nil) (state :stopped) (thread nil))
         ,(format nil "Return a new ~A with the given slot values." name)
         (make-instance ',name :name name :live-p live-p :state state :thread thread)))))

;;;; The protocol.

(defgeneric channel-start (channel &key config)
  (:documentation "Start CHANNEL with its CONFIG section and return it."))

(defgeneric channel-stop (channel)
  (:documentation "Stop CHANNEL and release its resources."))

(defgeneric channel-send (channel target text &key reply-to)
  (:documentation "Send TEXT to TARGET through CHANNEL, optionally answering REPLY-TO."))

(defgeneric channel-status (channel)
  (:documentation "Return CHANNEL's current state keyword."))

(declaim (ftype (function (channel symbol) null) unimplemented-channel-operation))

(defun unimplemented-channel-operation (channel operation)
  "Signal a CONFIGURATION-ERROR with CHANNEL's name as :KEY and OPERATION in :DETAIL."
  (error 'enchiridion.errors:configuration-error
         :key (channel-name channel)
         :detail (format nil "~A does not implement ~A." (type-of channel) operation)))

(defmethod channel-start ((channel channel) &key config)
  "Refuse to start a channel that has no CHANNEL-START method."
  (declare (ignore config))
  (unimplemented-channel-operation channel 'channel-start))

(defmethod channel-stop ((channel channel))
  "Refuse to stop a channel that has no CHANNEL-STOP method."
  (unimplemented-channel-operation channel 'channel-stop))

(defmethod channel-send ((channel channel) target text &key reply-to)
  "Refuse to send through a channel that has no CHANNEL-SEND method."
  (declare (ignore target text reply-to))
  (unimplemented-channel-operation channel 'channel-send))

(defmethod channel-status ((channel channel))
  "Refuse to report the state of a channel that has no CHANNEL-STATUS method."
  (unimplemented-channel-operation channel 'channel-status))

;;;; Sending a reply.

(declaim (ftype (function (channel t string &key (:reply-to string)) t) deliver))

(defun deliver (channel target text &key reply-to)
  "Send TEXT to TARGET through CHANNEL as a reply via CHANNEL-SEND."
  (channel-send channel target text :reply-to reply-to))
