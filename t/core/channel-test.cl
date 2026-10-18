;;;; channel-test.cl --- The message shape and the channel protocol.
;;;;
;;;; The msg struct is the one shape every channel normalizes into, so these
;;;; tests pin its defaults and both spellings of NORMALIZE. The stub channel
;;;; below is the smallest class that proves DELIVER reaches CHANNEL-SEND, and
;;;; the bare channel proves that a subclass which implements nothing refuses
;;;; by name instead of doing nothing quietly.

(defpackage #:enchiridion-channel-test
  (:use #:cl)
  (:import-from #:rove #:deftest #:ok #:ng #:testing #:signals)
  (:export #:run))

(in-package #:enchiridion-channel-test)

;;;; The message.

(deftest msg-defaults ()
  (let ((message (enchiridion.channel:make-msg)))
    (testing "every slot has its default"
      (ok (equal "" (enchiridion.channel:msg-id message)))
      (ok (eq :cli (enchiridion.channel:msg-channel message)))
      (ok (equal "" (enchiridion.channel:msg-target message)))
      (ok (equal "" (enchiridion.channel:msg-thread message)))
      (ok (equal "" (enchiridion.channel:msg-author message)))
      (ok (equal "" (enchiridion.channel:msg-text message)))
      (ok (eql 0 (enchiridion.channel:msg-ts message)))
      (ok (equal "" (enchiridion.channel:msg-reply-to message))))))

(deftest normalize-from-a-plist ()
  (let ((message (enchiridion.channel:normalize
                   '(:channel :http :author "penny" :text "hello" :thread "t-1"))))
    (testing "the plist reaches the slots"
      (ok (eq :http (enchiridion.channel:msg-channel message)))
      (ok (equal "penny" (enchiridion.channel:msg-author message)))
      (ok (equal "hello" (enchiridion.channel:msg-text message)))
      (ok (equal "t-1" (enchiridion.channel:msg-thread message))))))

(deftest normalize-from-keywords ()
  (let ((message (enchiridion.channel:normalize :channel :fluxer :author "penny" :text "hi")))
    (testing "the keyword arguments reach the slots"
      (ok (eq :fluxer (enchiridion.channel:msg-channel message)))
      (ok (equal "penny" (enchiridion.channel:msg-author message)))
      (ok (equal "hi" (enchiridion.channel:msg-text message))))))

(deftest normalize-fills-id-and-ts ()
  (let ((message (enchiridion.channel:normalize :author "penny" :text "hello")))
    (testing "an absent id is minted from the counter"
      (ok (stringp (enchiridion.channel:msg-id message)))
      (ok (plusp (length (enchiridion.channel:msg-id message))))
      (ok (eql 0 (search "cli-" (enchiridion.channel:msg-id message)))))
    (testing "a zero timestamp is filled from the clock"
      (ok (integerp (enchiridion.channel:msg-ts message)))
      (ok (plusp (enchiridion.channel:msg-ts message)))))
  (testing "two messages do not share an id"
    (ng (equal (enchiridion.channel:msg-id (enchiridion.channel:normalize))
               (enchiridion.channel:msg-id (enchiridion.channel:normalize))))))

(deftest normalize-keeps-what-it-is-given ()
  (let ((message (enchiridion.channel:normalize '(:id "m-7" :ts 42 :reply-to "m-6"))))
    (testing "an id and a timestamp survive"
      (ok (equal "m-7" (enchiridion.channel:msg-id message)))
      (ok (eql 42 (enchiridion.channel:msg-ts message))))
    (testing "and so does reply-to"
      (ok (equal "m-6" (enchiridion.channel:msg-reply-to message))))))

;;;; The digest.

(deftest message-digest-names-channel-and-author ()
  (let* ((message (enchiridion.channel:normalize
                   '(:channel :http :author "penny" :text "hello there")))
         (digest (enchiridion.channel:message-digest message)))
    (testing "the digest is one line"
      (ng (search (string #\Newline) digest)))
    (testing "it names the channel and the author"
      (ok (search "http" digest))
      (ok (search "penny" digest)))
    (testing "it carries the start of the text"
      (ok (search "hello there" digest)))))

(deftest message-digest-stops-at-the-first-line ()
  (let ((message (enchiridion.channel:normalize :text (format nil "first~%second"))))
    (ok (search "first" (enchiridion.channel:message-digest message)))
    (ng (search "second" (enchiridion.channel:message-digest message)))))

(deftest message-digest-stays-short ()
  (let* ((message (enchiridion.channel:normalize
                   :text (make-string 500 :initial-element #\x)))
         (digest (enchiridion.channel:message-digest message)))
    (ok (< (length digest) 120))))

;;;; Two channels.
;;;;
;;;; DEFINE-CHANNEL defines the class and its constructor. STUB-CHANNEL
;;;; implements only CHANNEL-SEND, so the other three generic functions keep
;;;; their default methods. BARE-CHANNEL implements nothing, so all four do.

(defparameter *sent* '()
  "Every CHANNEL-SEND the stub channel handled, newest first, as
(target text reply-to).")

(enchiridion.channel:define-channel stub-channel)

(defmethod enchiridion.channel:channel-send ((channel stub-channel) target text &key reply-to)
  "Record the send and return it, so a test can see the round trip."
  (declare (ignore channel))
  (push (list target text reply-to) *sent*)
  (list :target target :text text :reply-to reply-to))

(enchiridion.channel:define-channel bare-channel)

(deftest define-channel-defines-a-class-and-a-constructor ()
  (let ((channel (make-bare-channel)))
    (testing "the class and its constructor exist"
      (ok (typep channel 'bare-channel))
      (ok (typep channel 'enchiridion.channel:channel)))
    (testing "the base slots take their defaults"
      (ok (equal "bare-channel" (enchiridion.channel:channel-name channel)))
      (ok (null (enchiridion.channel:channel-live-p channel)))
      (ok (eq :stopped (enchiridion.channel:channel-state channel)))
      (ok (null (enchiridion.channel:channel-thread channel))))
    (testing "and the constructor takes them"
      (let ((named (make-stub-channel :name "stub" :state :live :live-p t)))
        (ok (equal "stub" (enchiridion.channel:channel-name named)))
        (ok (eq :live (enchiridion.channel:channel-state named)))
        (ok (enchiridion.channel:channel-live-p named))))))

(deftest deliver-reaches-channel-send ()
  (let ((stub (make-stub-channel :name "stub")))
    (setf *sent* '())
    (let ((result (enchiridion.channel:deliver stub "operator" "hello" :reply-to "m-1")))
      (testing "the send arrived with its reply-to"
        (ok (equal '(("operator" "hello" "m-1")) *sent*)))
      (testing "deliver returns what channel-send returned"
        (ok (equal '(:target "operator" :text "hello" :reply-to "m-1") result))))))

(deftest a-channel-that-implements-nothing-refuses ()
  (let ((channel (make-bare-channel :name "bare")))
    (testing "every default method signals a configuration-error"
      (ok (signals (enchiridion.channel:channel-start channel)
                   'enchiridion.errors:configuration-error))
      (ok (signals (enchiridion.channel:channel-stop channel)
                   'enchiridion.errors:configuration-error))
      (ok (signals (enchiridion.channel:channel-send channel "target" "text")
                   'enchiridion.errors:configuration-error))
      (ok (signals (enchiridion.channel:channel-status channel)
                   'enchiridion.errors:configuration-error)))
    (testing "and the condition names the channel"
      (let ((condition (handler-case (enchiridion.channel:channel-status channel)
                         (enchiridion.errors:configuration-error (condition) condition))))
        (ok (typep condition 'enchiridion.errors:configuration-error))
        (ok (search "bare" (princ-to-string condition)))))))
