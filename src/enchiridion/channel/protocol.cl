;;;; protocol.cl --- The one message shape and the channel protocol.
;;;;
;;;; Every channel normalizes inbound traffic into one MSG and receives
;;;; outbound sends through the same four generic functions. Nothing above
;;;; this file learns which channel a turn came from, which is what lets a
;;;; second channel be one subclass instead of a branch in the kernel.
;;;;
;;;; The base class is a CLOS class and not a structure because there is one
;;;; subclass per channel. The slot accessor is CHANNEL-STATE and not
;;;; CHANNEL-STATUS, because CHANNEL-STATUS is the protocol method that asks a
;;;; channel how it is doing; one name for both would make the slot and the
;;;; question the same symbol.

(in-package #:enchiridion.channel)

;;;; The message.

;; A defstruct carries no :documentation option: a trailing :documentation is
;; read as a slot named DOCUMENTATION instead of as a note about the struct.
;; So each slot's meaning is a comment here. Every slot has a type and a
;; default, so an empty message is a valid one and a caller fills only what it
;; knows. The field names match PLAN.md section 16.3 and the field order there.
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
;;;;
;;;; ARGUMENTS arrives either as one plist or as keyword arguments, because a
;;;; caller holding a plist from a queue and a caller writing a call site are
;;;; both normal, and two functions for that would be one function and a
;;;; source of drift.

(declaim (ftype (function (&rest t) msg) normalize))

(defun normalize (&rest arguments)
  "Return a MSG built from ARGUMENTS.

ARGUMENTS is either a plist, as (normalize '(:author \"penny\")), or keyword
arguments, as (normalize :author \"penny\"). Both spellings reach the same
slots.

A missing or empty id is minted from the counter as cli-1, the channel name and
a number, so a message always has something to be replied to. A missing or zero
timestamp is filled from GET-UNIVERSAL-TIME. Every other absent slot keeps the
MSG default, which is the empty string."
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

;;;; The digest.

(defparameter +message-digest-length+ 60
  "How much of a body MESSAGE-DIGEST keeps. A log line longer than this is a
log line the next entry scrolls past.")

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
  "Return one short line naming MESSAGE's channel, its author, and the first
part of its text, for the ledger and the log.

The line is deliberately not a dump of the whole message: it is read by a human
scanning a transcript, and a full body would bury the next line."
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
          :documentation "Where the channel is: :stopped, :starting, :live, or :failed.")
   (thread :accessor channel-thread :initarg :thread :initform nil :type t
           :documentation "The thread the channel runs on, or NIL when it has none."))
  (:documentation
   "The base class every channel subclasses. One subclass per channel, so a new
channel is a new file rather than a branch in the supervisor."))

;;;; Defining a channel.

(defmacro define-channel (name &key constructor)
  "Define a channel class NAME and its constructor.

CONSTRUCTOR names the constructor function and defaults to MAKE-<NAME> in the
package where NAME is read. The class inherits every slot from CHANNEL, so a
subclass declares only what it adds. A channel that adds nothing is still a
real class, and its constructor takes the four base slots."
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
;;;;
;;;; Four generic functions and one default method each. A channel that
;;;; implements nothing is a channel that says so by name, rather than one that
;;;; silently drops a send, which is the failure that costs a turn.

(defgeneric channel-start (channel &key config)
  (:documentation
   "Start CHANNEL and return it. CONFIG is the channel's section of the
configuration. A subclass implements this; the default method signals that it
did not."))

(defgeneric channel-stop (channel)
  (:documentation
   "Stop CHANNEL and release whatever it holds. A subclass implements this; the
default method signals that it did not."))

(defgeneric channel-send (channel target text &key reply-to)
  (:documentation
   "Send TEXT to TARGET through CHANNEL. REPLY-TO names the message this one
answers. Return whatever the channel returns for a successful send; a subclass
implements this and the default method signals that it did not."))

(defgeneric channel-status (channel)
  (:documentation
   "Return CHANNEL's state, one of the CHANNEL-STATE keywords. A subclass
implements this; the default method signals that it did not."))

(declaim (ftype (function (channel symbol) null) unimplemented-channel-operation))

(defun unimplemented-channel-operation (channel operation)
  "Signal a CONFIGURATION-ERROR naming CHANNEL and OPERATION.

The channel's name is the :KEY, because the report method prints the key and
the report is the part a person reads. The operation goes in the detail, where
a caller that wants it can ask the condition for it."
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
  "Send TEXT to TARGET through CHANNEL as a reply and return what CHANNEL-SEND
returns.

This is the one place a reply leaves the agent, so a caller holding a channel
does not have to know whether a send is a websocket frame, an HTTP response, or
a line on a terminal."
  (channel-send channel target text :reply-to reply-to))
