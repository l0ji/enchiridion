;;;; http.lsp --- Hunchentoot webhook channel (/message, /health, /usage).
;;;;
;;;; Replies travel in the HTTP response body, so CHANNEL-SEND is unimplemented.
;;;; Non-loopback binds require a bearer token before opening a socket.
;;;; Route handlers receive TURN, HEALTH, and USAGE callbacks to stay decoupled
;;;; from the kernel.

(in-package #:enchiridion.channel.http)

;;;; Limits.

(defparameter +http-body-limit+ 65536
  "Default max request body size in bytes (checked against Content-Length before
reading, and counted during chunked reads).")

(defparameter +http-usage-limit+ 50
  "Default row count returned by GET /usage.")

(defparameter +http-max-usage-limit+ 1000
  "Maximum ?limit= value accepted by GET /usage.")

(defparameter +http-turn-key-length+ 64
  "Length of the lower-case hexadecimal capability that names one followable turn.")

(defparameter +http-followup-limit+ 4
  "Follow-up texts one keyed turn accepts.")

(defparameter +http-followup-chars+ 16000
  "Follow-up characters, summed, that one keyed turn accepts.")

(defparameter +http-closed-turn-limit+ 64
  "Closed turn keys remembered so a late follow-up hears closed, not unknown.")

(defparameter +http-reply-reuse-seconds+ 30
  "Seconds a completed keyed turn's work stays reusable by a reply_to.")

(defparameter *http-drain-seconds* 6
  "Default seconds CHANNEL-STOP budgets for stopping the acceptor and draining
in-flight turns before the supervisor closes the store.")

(defparameter +http-read-timeout+ 5
  "Socket read/write timeout in seconds (hunchentoot requires both to match).")

;;;; The one condition this file signals.

(define-condition http-error (enchiridion.errors:enchiridion-error)
  ((status :initarg :status :initform 500 :reader http-error-status
           :documentation "The status code the client should see.")
   (message :initarg :message :initform "" :reader http-error-message
            :documentation "One line, safe to return to the caller.")
   (allow :initarg :allow :initform nil :reader http-error-allow
          :documentation "The Allow header, when the failure is a method.")
   (retry-after :initarg :retry-after :initform nil :reader http-error-retry-after
                :documentation "Seconds the caller should wait, or NIL.")
   (code :initarg :code :initform nil :reader http-error-code
         :documentation "Stable machine-readable code for a follow-up refusal, or NIL."))
  (:report (lambda (condition stream)
             (format stream "HTTP ~D: ~A"
                     (http-error-status condition)
                     (http-error-message condition))))
  (:documentation
   "Refused webhook request carrying HTTP status, safe client message, and optional headers."))

(defmacro http-fail (status message &key allow retry-after code)
  "Signal HTTP-ERROR with STATUS and MESSAGE. Macro so the compiler sees the
non-local exit for type checking."
  `(error 'http-error :status ,status :message ,message
                      :allow ,allow :retry-after ,retry-after :code ,code))

;;;; JSON.

(declaim (ftype (function (&rest t) hash-table) json-object))

(defun json-object (&rest pairs)
  "Return PAIRS as a string-keyed hash table (JZON serializes plists as arrays)."
  (let ((table (make-hash-table :test #'equal)))
    (loop for (key value) on pairs by #'cddr
          do (setf (gethash (string-downcase (string key)) table) value))
    table))

(declaim (ftype (function (t) string) json-text))

(defun json-text (value)
  "Return VALUE encoded as JSON text."
  (com.inuoe.jzon:stringify value))

(defparameter +json-null+ 'null
  "Symbol JZON serializes as JSON null (NIL serializes as false).")

(declaim (ftype (function (t) t) json-value))

(defun json-value (value)
  "Convert VALUE for JZON: plists to hash tables, :NULL to +JSON-NULL+,
keywords to lowercase strings."
  (cond
    ((hash-table-p value) value)
    ((eq value :null) +json-null+)
    ((keywordp value) (string-downcase (symbol-name value)))
    ((and (consp value) (keywordp (first value)))
     (let ((table (make-hash-table :test #'equal)))
       (loop for (key item) on value by #'cddr
             do (setf (gethash (string-downcase (string key)) table)
                      (json-value item)))
       table))
    (t value)))

(declaim (ftype (function (string &optional (or null string)) string) error-body))

(defun error-body (message &optional code)
  "Return the one line JSON error object the webhook answers with.
CODE, when set, is the stable machine-readable reason a follow-up was refused."
  (if code
      (json-text (json-object "ok" nil "error" message "code" code))
      (json-text (json-object "ok" nil "error" message))))

;;;; The service.

;; IN-FLIGHT tracks active turns separately from hunchentoot's
;; requests-in-progress so shutdown waits for model calls to finish.
(defstruct (http-service (:constructor %make-http-service))
  (turn nil :type t)
  (health nil :type t)
  (usage nil :type t)
  (token nil :type t)
  (bind "127.0.0.1" :type string)
  (port 8787 :type (integer 0 65535))
  (body-limit +http-body-limit+ :type (integer 1 *))
  (followups-p nil :type boolean)
  (turns (make-hash-table :test #'equal) :type hash-table)
  (closed-turns nil :type list)
  (last-work nil :type t)
  (followup-lock nil :type t)
  (in-flight 0 :type integer)
  (in-flight-lock nil :type t))

(declaim (ftype (function (&key (:turn t) (:health t) (:usage t) (:token t)
                                (:bind string) (:port integer) (:body-limit integer)
                                (:followups-p boolean))
                          http-service)
                make-http-service))

(defun make-http-service (&key turn health usage token (bind "127.0.0.1") (port 8787)
                               (body-limit +http-body-limit+) (followups-p nil))
  "Construct an HTTP-SERVICE without binding a port. Trims BIND and TOKEN;
empty BIND defaults to 127.0.0.1 and empty TOKEN becomes NIL. With FOLLOWUPS-P,
TURN accepts a second argument, the checkpoint callback, and a third when a
reply_to supplies prior work."
  (check-type bind string)
  (check-type port (integer 0 65535))
  (check-type body-limit (integer 1 *))
  (check-type followups-p boolean)
  (let ((bind (string-trim '(#\Space #\Tab) bind))
        (token (and (stringp token)
                    (string-trim '(#\Space #\Tab #\Newline #\Return) token))))
    (%make-http-service :turn turn :health health :usage usage
                        :token (if (and token (plusp (length token))) token nil)
                        :bind (if (plusp (length bind)) bind "127.0.0.1")
                        :port port
                        :body-limit body-limit
                        :followups-p followups-p
                        :followup-lock (bordeaux-threads:make-lock
                                        "enchiridion http followups")
                        :in-flight-lock (bordeaux-threads:make-lock
                                         "enchiridion http in flight"))))

(declaim (ftype (function (http-service) null) enter-turn))

(defun enter-turn (service)
  "Count one turn as running. Return NIL."
  (bordeaux-threads:with-lock-held ((http-service-in-flight-lock service))
    (incf (http-service-in-flight service)))
  nil)

(declaim (ftype (function (http-service) null) leave-turn))

(defun leave-turn (service)
  "Count one turn as finished. Return NIL."
  (bordeaux-threads:with-lock-held ((http-service-in-flight-lock service))
    (decf (http-service-in-flight service)))
  nil)

;;;; Follow-ups.
;;;;
;;;; A keyed turn registers a capability before its callback runs, but only its
;;;; first kernel checkpoint opens admission. A turn that answers 503 has never
;;;; accepted a follow-up. An empty :BEFORE-FINAL drain closes the key, which
;;;; is the publication cutoff: the answer that follows cannot share its turn.
;;;; All queue and state changes share one short lock, never a model call.

(defstruct (http-turn (:constructor %make-http-turn (key)))
  (key "" :type string)
  (state :pending :type keyword)
  (queue nil :type list)
  (count 0 :type (integer 0 *))
  (chars 0 :type (integer 0 *)))

(defstruct (http-work (:constructor %make-http-work))
  (key "" :type string)
  (work nil :type t)
  (at 0 :type integer))

(declaim (ftype (function (http-service string) (values t t)) claim-http-work))

(defun claim-http-work (service key)
  "Return the work remembered under KEY within its reuse window, once.
The second value is the claimed entry, so a turn that never ran can restore it
with its original deadline. An unmatched probe leaves the remembered work
alone; a matching expired or already used entry is forgotten."
  (bordeaux-threads:with-lock-held ((http-service-followup-lock service))
    (let ((stored (http-service-last-work service)))
      (when (and stored (string= key (http-work-key stored)))
        (let ((fresh (<= (- (get-internal-real-time) (http-work-at stored))
                         (* +http-reply-reuse-seconds+
                            internal-time-units-per-second))))
          (setf (http-service-last-work service) nil)
          (when fresh
            (values (http-work-work stored) stored)))))))

(declaim (ftype (function (http-service string t) null) remember-http-work))

(defun remember-http-work (service key work)
  "Remember opaque WORK for a completed keyed turn under KEY.
Only the most recent entry is kept."
  (bordeaux-threads:with-lock-held ((http-service-followup-lock service))
    (setf (http-service-last-work service)
          (%make-http-work :key key :work work
                           :at (get-internal-real-time))))
  nil)

(declaim (ftype (function (http-service t) null) restore-http-work))

(defun restore-http-work (service entry)
  "Put a claimed ENTRY back for a turn that never ran, keeping its deadline.
A newer entry is never overwritten."
  (bordeaux-threads:with-lock-held ((http-service-followup-lock service))
    (when (and entry (null (http-service-last-work service)))
      (setf (http-service-last-work service) entry)))
  nil)

(declaim (ftype (function (t) boolean) turn-key-p))

(defun turn-key-p (value)
  "Return T when VALUE is 64 lower-case hexadecimal characters."
  (and (stringp value)
       (= (length value) +http-turn-key-length+)
       (every (lambda (character)
                (or (char<= #\0 character #\9)
                    (char<= #\a character #\f)))
              value)))

(declaim (ftype (function (http-service http-turn) null) close-http-turn))

(defun close-http-turn (service turn)
  "Close TURN under SERVICE's follow-up lock and remember it for a bounded while.
The caller holds the lock."
  (unless (eq (http-turn-state turn) :closed)
    (setf (http-turn-state turn) :closed)
    (let ((closed (push turn (http-service-closed-turns service))))
      (when (> (length closed) +http-closed-turn-limit+)
        (let ((oldest (car (last closed))))
          (setf (http-service-closed-turns service) (butlast closed))
          (when (eq (gethash (http-turn-key oldest)
                             (http-service-turns service))
                    oldest)
            (remhash (http-turn-key oldest)
                     (http-service-turns service)))))))
  nil)

(declaim (ftype (function (http-service string) http-turn) register-http-turn))

(defun register-http-turn (service key)
  "Register KEY as a pending turn, refusing a key that is active or remembered."
  (bordeaux-threads:with-lock-held ((http-service-followup-lock service))
    (when (gethash key (http-service-turns service))
      (http-fail 409 "That turn key is already in use." :code "turn_key_reused"))
    (let ((turn (%make-http-turn key)))
      (setf (gethash key (http-service-turns service)) turn)
      turn)))

(declaim (ftype (function (http-service http-turn) null) retire-http-turn))

(defun retire-http-turn (service turn)
  "Close TURN, or forget it when it never reached a first checkpoint."
  (bordeaux-threads:with-lock-held ((http-service-followup-lock service))
    (cond
      ((eq (http-turn-state turn) :pending)
       (when (eq (gethash (http-turn-key turn)
                          (http-service-turns service))
                 turn)
         (remhash (http-turn-key turn) (http-service-turns service))))
      ((eq (http-turn-state turn) :closed) nil)
      (t (close-http-turn service turn))))
  nil)

(declaim (ftype (function (http-service http-turn t) list) drain-http-followups))

(defun drain-http-followups (service turn phase)
  "Open TURN at its first checkpoint and return its queued texts in order.
At :BEFORE-FINAL with nothing waiting, close admission before the answer
is published."
  (bordeaux-threads:with-lock-held ((http-service-followup-lock service))
    (when (eq (http-turn-state turn) :pending)
      (setf (http-turn-state turn) :accepting))
    (let ((texts (http-turn-queue turn)))
      (setf (http-turn-queue turn) nil)
      (when (and (eq phase :before-final) (null texts))
        (close-http-turn service turn))
      texts)))

(declaim (ftype (function (http-service http-turn) function) make-turn-steer))

(defun make-turn-steer (service turn)
  "Return the checkpoint callback that drains TURN's follow-ups."
  (lambda (phase)
    (drain-http-followups service turn phase)))

(declaim (ftype (function (t) null) close-http-turns))

(defun close-http-turns (service)
  "Close every open turn on SERVICE and forget reusable work, so a stopping
webhook takes no follow-ups and starts its next run clean."
  (when service
    (bordeaux-threads:with-lock-held ((http-service-followup-lock service))
      (let ((open '()))
        (maphash (lambda (key turn)
                   (declare (ignore key))
                   (unless (eq (http-turn-state turn) :closed)
                     (push turn open)))
                 (http-service-turns service))
        (dolist (turn open)
          (close-http-turn service turn))
        (setf (http-service-last-work service) nil))))
  nil)

(declaim (ftype (function (http-service string string) (values integer string))
                followup-response))

(defun followup-response (service key text)
  "Admit TEXT to the active turn KEY within its 4-text and 16000-character
budget, or refuse it with a coded 409. The codes are unknown_turn, turn_pending,
turn_closed, and turn_full. A key is a capability: the body's author field is
not read and cannot name a different sender."
  (bordeaux-threads:with-lock-held ((http-service-followup-lock service))
    (let ((turn (gethash key (http-service-turns service))))
      (cond
        ((null turn)
         (http-fail 409 "No turn is waiting on that follow-up key."
                    :code "unknown_turn"))
        ((eq (http-turn-state turn) :pending)
         (http-fail 409 "That turn has not reached its first checkpoint yet; retry shortly."
                    :code "turn_pending" :retry-after "1"))
        ((eq (http-turn-state turn) :closed)
         (http-fail 409 "That turn is no longer accepting follow-ups."
                    :code "turn_closed"))
        ((>= (http-turn-count turn) +http-followup-limit+)
         (http-fail 409 (format nil "That turn already accepted its ~D follow-ups."
                               +http-followup-limit+)
                    :code "turn_full"))
        ((> (+ (http-turn-chars turn) (length text)) +http-followup-chars+)
         (http-fail 409 (format nil "That turn already accepted ~D follow-up characters."
                               +http-followup-chars+)
                    :code "turn_full"))
        (t
         (incf (http-turn-count turn))
         (incf (http-turn-chars turn) (length text))
         (setf (http-turn-queue turn)
               (nconc (http-turn-queue turn) (list text)))
         (values 202 (json-text (json-object "ok" t "accepted" t))))))))

;;;; Authentication.

(declaim (ftype (function (string string) boolean) constant-time-string=))

(defun constant-time-string= (left right)
  "Compare LEFT and RIGHT without early exit on character mismatch (length
difference is folded into the accumulator)."
  (declare (type string left right))
  (let ((difference (logxor (length left) (length right)))
        (limit (min (length left) (length right))))
    (dotimes (index limit)
      (setf difference (logior difference
                               (logxor (char-code (char left index))
                                       (char-code (char right index))))))
    (zerop difference)))

(declaim (ftype (function (t) (or null string)) bearer-token))

(defun bearer-token (authorization)
  "Extract the Bearer token from AUTHORIZATION, or NIL."
  (when (and (stringp authorization)
             (> (length authorization) 7)
             (string-equal "bearer " authorization :end2 7))
    (let ((token (string-trim '(#\Space #\Tab) (subseq authorization 7))))
      (if (plusp (length token)) token nil))))

(declaim (ftype (function (http-service t) boolean) authorized-p))

(defun authorized-p (service authorization)
  "Return T when AUTHORIZATION matches SERVICE's token (or when SERVICE has no
token, allowed only on loopback). Compares missing headers as empty strings in
constant time."
  (let ((expected (http-service-token service)))
    (if (or (null expected) (zerop (length expected)))
        t
        (constant-time-string= (or (bearer-token authorization) "") expected))))

;;;; Binding.

(declaim (ftype (function (t) boolean) loopback-bind-p))

(defun loopback-bind-p (bind)
  "Return T when BIND is loopback (empty string, localhost, ::1,
::ffff:127.0.0.1, or ASCII-only 127.x.x.x). NIL is not loopback because
hunchentoot treats NIL as wildcard; hostnames are not resolved."
  (if (not (stringp bind))
      nil
      (let ((text (string-trim '(#\Space #\Tab) bind)))
        (cond
          ((zerop (length text)) t)
          ((string-equal "localhost" text) t)
          ((string= "::1" text) t)
          ((string= "::ffff:127.0.0.1" text) t)
          ((and (>= (length text) 5)
                (string= "127." text :end2 4)
                (= 3 (count #\. text))
                (every (lambda (character)
                         (or (char= character #\.)
                             (char<= #\0 character #\9)))
                       text))
           t)
          (t nil)))))

(declaim (ftype (function (http-service) null) check-http-policy))

(defun check-http-policy (service)
  "Refuse a reachable bind that has no token, before a socket is opened."
  (let ((bind (http-service-bind service))
        (token (http-service-token service)))
    (when (and (not (loopback-bind-p bind))
               (or (null token) (zerop (length token))))
      (error 'enchiridion.errors:configuration-error
             :key :http-token
             :detail (format nil
                             "A webhook bound to ~A answers the network, so it needs a token. Set the variable the :http channel names, or bind 127.0.0.1."
                             bind)))))

;;;; The request.

(defclass http-request-object (hunchentoot:request)
  ((body-abandoned-p :accessor http-request-object-body-abandoned-p
                     :initarg :body-abandoned-p
                     :initform nil
                     :type boolean
                     :documentation
                     "T when the body was not read, so the connection must close."))
  (:documentation
   "Hunchentoot request subclass tracking unread bodies via BODY-ABANDONED-P.
Seals RAW-POST-DATA on init so hunchentoot never allocates an unvalidated Content-Length."))

(defmethod initialize-instance :after ((request http-request-object) &rest initargs)
  "Seal the body until a route opens it."
  (declare (ignore initargs))
  (when (slot-exists-p request 'hunchentoot::raw-post-data)
    (setf (slot-value request 'hunchentoot::raw-post-data) t)))

;; Plain request value so routes can be tested without a socket.
(defstruct (http-request (:constructor %make-http-request))
  (method "GET" :type string)
  (path "/" :type string)
  (query "" :type string)
  (authorization nil :type t)
  (content-type nil :type t)
  (content-length nil :type t)
  (body "" :type string))

(declaim (ftype (function (&key (:method string) (:path string) (:query string)
                                (:authorization t) (:content-type t)
                                (:content-length t) (:body string))
                          http-request)
                make-http-request))

(defun make-http-request (&key (method "GET") (path "/") (query "") authorization
                               content-type content-length (body ""))
  "Construct an HTTP-REQUEST value (used by tests and REQUEST-FROM-HUNCHENTOOT)."
  (check-type method string)
  (check-type path string)
  (check-type body string)
  (%make-http-request :method (string-upcase method) :path path :query query
                      :authorization authorization :content-type content-type
                      :content-length content-length :body body))

(declaim (ftype (function (t) (or null integer)) declared-length))

(defun declared-length (header)
  "Parse HEADER as a positive byte count, or NIL."
  (when (and (stringp header) (plusp (length header)))
    (let ((value (parse-integer header :junk-allowed t)))
      (and value (plusp value) value))))

(declaim (ftype (function (t) boolean) json-content-type-p))

(defun json-content-type-p (value)
  "Return T when VALUE is a string containing application/json."
  (and (stringp value)
       (not (null (search "application/json" (string-downcase value))))))

(declaim (ftype (function (t) boolean) chunked-body-p))

(defun chunked-body-p (transfer-encoding)
  "Return T when TRANSFER-ENCODING contains chunked."
  (and (stringp transfer-encoding)
       (not (null (search "chunked" (string-downcase transfer-encoding))))))

(declaim (ftype (function (t t) boolean) body-declared-p))

(defun body-declared-p (content-length transfer-encoding)
  "Return T when CONTENT-LENGTH or TRANSFER-ENCODING frames a body."
  (or (and (integerp content-length) (plusp content-length))
      (chunked-body-p transfer-encoding)))

(declaim (ftype (function (http-service t (or null integer) t &optional t)
                          (values string boolean))
                read-request-body))

(defun read-request-body (service raw length chunked-p &optional (declared-p (not (null length))))
  "Read RAW's body up to SERVICE's byte limit, returning (VALUES text clean-p).
Rejects dual Content-Length + Transfer-Encoding framing (even Content-Length: 0).
Uses READ-BYTE so chunked terminators are consumed; CLEAN-P is NIL if unread
bytes may remain on the connection."
  (when (and declared-p chunked-p)
    (http-fail 400 "The body declares both a length and a chunked encoding."))
  (when (and length (> length (http-service-body-limit service)))
    (http-fail 413 (format nil "The body is larger than ~D bytes."
                           (http-service-body-limit service))))
  (let ((stream (hunchentoot:raw-post-data :request raw :want-stream t)))
    (if (null stream)
        (values "" t)
        (let ((octets (make-array 256 :element-type '(unsigned-byte 8)
                                      :adjustable t :fill-pointer 0))
              (limit (http-service-body-limit service)))
          (loop for octet = (read-byte stream nil :eof)
                until (eq octet :eof)
                do (when (>= (fill-pointer octets) limit)
                     (http-fail 413 (format nil "The body is larger than ~D bytes."
                                            limit)))
                   (vector-push-extend octet octets))
          (values (handler-case (enchiridion.compat:decode-utf8 octets)
                    (error () (http-fail 400 "The body is not UTF-8 text.")))
                  (or (null length) (= (fill-pointer octets) length)))))))

(declaim (ftype (function (t boolean) boolean) note-body-abandoned))

(defun note-body-abandoned (request abandoned-p)
  "Set BODY-ABANDONED-P on REQUEST (when an HTTP-REQUEST-OBJECT) and return ABANDONED-P."
  (when (typep request 'http-request-object)
    (setf (http-request-object-body-abandoned-p request) abandoned-p))
  abandoned-p)

(declaim (ftype (function (t) boolean) body-abandoned-p))

(defun body-abandoned-p (request)
  "Return T when REQUEST framed a body that nothing read."
  (and (typep request 'http-request-object)
       (http-request-object-body-abandoned-p request)))

(declaim (ftype (function (t) null) open-request-body))

(defun open-request-body (request)
  "Clear the construction seal on RAW-POST-DATA immediately before bounded body reading."
  (when (and (typep request 'http-request-object)
             (slot-exists-p request 'hunchentoot::raw-post-data))
    (setf (slot-value request 'hunchentoot::raw-post-data) nil))
  nil)

(declaim (ftype (function (t) null) seal-request-body))

(defun seal-request-body (request)
  "Mark RAW-POST-DATA as T so HUNCHENTOOT:START-OUTPUT does not allocate and
drain an unread body while writing a refusal. Guarded by SLOT-EXISTS-P."
  (when (and (typep request 'http-request-object)
             (slot-exists-p request 'hunchentoot::raw-post-data))
    (setf (slot-value request 'hunchentoot::raw-post-data) t))
  nil)

(declaim (ftype (function (t) boolean) request-body-unread-p))

(defun request-body-unread-p (request)
  "Return T when REQUEST's headers frame a body that nothing has read yet."
  (body-declared-p (declared-length (hunchentoot:header-in* :content-length request))
                   (hunchentoot:header-in* :transfer-encoding request)))

(declaim (ftype (function (http-service t) http-request) request-from-hunchentoot))

(defun request-from-hunchentoot (service raw)
  "Convert RAW into an HTTP-REQUEST, reading the body only for framed POST
requests and marking abandoned bodies on RAW."
  (let* ((method (string-upcase (string (hunchentoot:request-method* raw))))
         (length-header (hunchentoot:header-in* :content-length raw))
         (length (declared-length length-header))
         (declared-p (and (stringp length-header) (plusp (length length-header))))
         (transfer-encoding (hunchentoot:header-in* :transfer-encoding raw))
         (chunked-p (chunked-body-p transfer-encoding))
         (framed-p (body-declared-p length transfer-encoding)))
    (multiple-value-bind (body clean-p)
        (if (and (string= method "POST") framed-p)
            (progn (open-request-body raw)
                   (read-request-body service raw length chunked-p declared-p))
            (values "" (not framed-p)))
      (note-body-abandoned raw (not clean-p))
      (%make-http-request
       :method method
       :path (or (hunchentoot:script-name* raw) "/")
       :query (or (hunchentoot:query-string* raw) "")
       :authorization (hunchentoot:header-in* :authorization raw)
       :content-type (hunchentoot:header-in* :content-type raw)
       :content-length length
       :body body))))

;;;; The routes.

(declaim (ftype (function (t) t) channel-object))

(defun channel-object (row)
  "Normalize channel status ROW (hash table or plist) for JSON output."
  (if (hash-table-p row)
      row
      (json-object "name" (or (getf row :name) "")
                   "state" (or (getf row :state) "")
                   "enabled" (not (null (getf row :enabled))))))

(declaim (ftype (function (t) hash-table) usage-object))

(defun usage-object (row)
  "Return ROW, one ledger row, as the JSON object the report carries."
  (json-object "id" (getf row :id)
               "session" (getf row :session)
               "model" (getf row :model)
               "input" (getf row :input)
               "output" (getf row :output)
               "cache-read" (getf row :cache-read)
               "cache-write" (getf row :cache-write)
               "channel" (getf row :channel)
               "ts" (getf row :ts)))

(declaim (ftype (function (string string) (or null string)) query-value))

(defun query-value (query name)
  "Return NAME from QUERY, a query string such as limit=5, or NIL."
  (when (and (stringp query) (plusp (length query)))
    (loop for pair in (uiop:split-string query :separator "&")
          for split = (position #\= pair)
          when (and split (string-equal name (subseq pair 0 split)))
            do (return (subseq pair (1+ split))))))

(declaim (ftype (function (http-request) (integer 1 *)) usage-limit))

(defun usage-limit (request)
  "Return ?limit= from REQUEST, clamped to [1, +HTTP-MAX-USAGE-LIMIT+],
defaulting to +HTTP-USAGE-LIMIT+."
  (let ((value (and (query-value (http-request-query request) "limit")
                    (parse-integer (query-value (http-request-query request) "limit")
                                   :junk-allowed t))))
    (cond
      ((null value) +http-usage-limit+)
      ((< value 1) +http-usage-limit+)
      ((> value +http-max-usage-limit+) +http-max-usage-limit+)
      (t value))))

(declaim (ftype (function (http-service) (values integer string)) health-response))

(defun health-response (service)
  "Return (VALUES status body) for GET /health from the live supervisor
callback (200 when ready, 503 otherwise)."
  (let ((report (and (http-service-health service)
                     (funcall (http-service-health service)))))
    (if report
        (let ((ready-p (not (null (getf report :ok-p)))))
          (values (if ready-p 200 503)
                  (json-text
                   (json-object "ok" ready-p
                                "ready" ready-p
                                "uptime" (or (getf report :uptime) 0)
                                "reasons" (or (getf report :reasons) #())
                                "channels" (map 'vector #'channel-object
                                                (getf report :channels))
                                "heartbeat" (json-value (getf report :heartbeat))
                                "persistence" (json-value (getf report :persistence))
                                "providers" (json-value (getf report :providers))
                                "writes" (json-value (getf report :writes))))))
        (values 503 (json-text (json-object "ok" nil
                                            "ready" nil
                                            "error" "the supervisor is not running"))))))

(declaim (ftype (function (http-service http-request) (values integer string))
                usage-response))

(defun usage-response (service request)
  "Return (VALUES status body) for GET /usage, or 503 when no store is open or readable."
  (let ((report (and (http-service-usage service)
                     (funcall (http-service-usage service) (usage-limit request)))))
    (cond
      ((null report)
       (values 503 (json-text (json-object "error" "no memory store is open"))))
      ((not (getf report :ok-p))
       (values 503 (json-text (json-object "error" (or (getf report :error)
                                                       "the ledger is unreadable")))))
      (t
       (let ((rows (getf report :rows)))
         (values 200 (json-text (json-object "count" (length rows)
                                             "rows" (coerce (mapcar #'usage-object rows)
                                                            'vector)))))))))

(declaim (ftype (function (t) hash-table) usage-summary-object))

(defun usage-summary-object (usage)
  "Format turn USAGE plist (summed across all model rounds) as a JSON object."
  (json-object "model" (or (getf usage :model) "")
               "input" (or (getf usage :input) 0)
               "output" (or (getf usage :output) 0)
               "cache-read" (or (getf usage :cache-read) 0)
               "cache-write" (or (getf usage :cache-write) 0)
               "rounds" (or (getf usage :rounds) 0)
               "total" (or (getf usage :total) 0)))

(declaim (ftype (function (string) hash-table) parse-json-object))

(defun parse-json-object (text)
  "Return TEXT parsed as a JSON object, or refuse it with a 400."
  (handler-case
      (let ((value (com.inuoe.jzon:parse text)))
        (if (hash-table-p value)
            value
            (http-fail 400 "The body must be a JSON object.")))
    (http-error (condition) (error condition))
    (error () (http-fail 400 "The body is not JSON."))))

(declaim (ftype (function (http-service t t &optional t t) t) run-turn))

(defun run-turn (service turn message &optional steer work)
  "Run TURN on MESSAGE while tracked as in-flight; logs and converts signalled
errors into a failed-turn plist. STEER is the checkpoint callback and WORK is
prior work a reply_to selected, each only when present."
  (enter-turn service)
  (unwind-protect
       (handler-case
           (cond
             (work (funcall turn message steer work))
             (steer (funcall turn message steer))
             (t (funcall turn message)))
         (error (condition)
           (format *error-output* "~&enchiridion: webhook turn failed: ~A~%" condition)
           (finish-output *error-output*)
           (list :ok-p nil :reply "" :reason :failed
                 :error (princ-to-string condition))))
    (leave-turn service)))

(declaim (ftype (function (hash-table) string) required-text))

(defun required-text (body)
  "Return the non-empty text field BODY needs, or refuse it with a 400."
  (let ((text (gethash "text" body)))
    (unless (and (stringp text)
                 (plusp (length (string-trim '(#\Space #\Tab #\Newline #\Return)
                                             text))))
      (http-fail 400 "The body needs a non-empty text field."))
    text))

(declaim (ftype (function (http-service string t (or null string)
                                          (or null string))
                          (values integer string))
                run-message-turn))

(defun run-message-turn (service text author turn-key reply-to)
  "Run one synchronous turn, registering TURN-KEY for follow-ups when set and
passing work remembered under REPLY-TO when it is still fresh."
  (let ((turn (http-service-turn service)))
    (when (null turn)
      (http-fail 502 "no agent is attached to this webhook."))
    (let* ((message (enchiridion.channel:normalize
                     :channel :http
                     :author (if (stringp author) author "webhook")
                     :text text))
           (state (and turn-key (register-http-turn service turn-key)))
           (work nil)
           (claimed nil)
           (result nil))
      (when reply-to
        (multiple-value-setq (work claimed)
          (claim-http-work service reply-to)))
      (unwind-protect
           (setf result (if state
                            (run-turn service turn message
                                      (make-turn-steer service state) work)
                            (run-turn service turn message nil work)))
        (when (and state (getf result :ok-p) (getf result :work))
          (remember-http-work service turn-key (getf result :work)))
        (when (and claimed (eq (getf result :reason) :busy))
          (restore-http-work service claimed))
        (when state (retire-http-turn service state)))
      (cond
        ((getf result :ok-p)
         (values 200 (json-text
                      (json-object "reply" (or (getf result :reply) "")
                                   "usage" (usage-summary-object (getf result :usage))))))
        ((eq (getf result :reason) :busy)
         (http-fail 503 (or (getf result :error) "the agent is answering another turn.")
                    :retry-after "1"))
        (t
         (http-fail 502 (or (getf result :error) "the turn failed.")))))))

(declaim (ftype (function (http-service http-request) (values integer string))
                message-response))

(defun message-response (service request)
  "Return the status and body for POST /message: one synchronous turn, or a
202 admission when the body follows up to an active key.
TURN_KEY and FOLLOW_UP_TO are caller-minted 64-character lower-case hexadecimal
capabilities, mutually exclusive. REPLY_TO may accompany TURN_KEY or stand
alone; it reuses a completed keyed turn's work once, and otherwise runs an
ordinary turn. A keyed turn accepts follow-ups from its first kernel checkpoint
until an empty :BEFORE-FINAL drain closes admission."
  (unless (json-content-type-p (http-request-content-type request))
    (http-fail 415 "POST /message needs a JSON body."))
  (let* ((body (parse-json-object (http-request-body request)))
         (text (required-text body))
         (author (gethash "author" body))
         (turn-key (gethash "turn_key" body))
         (turn-key-p (nth-value 1 (gethash "turn_key" body)))
         (follow-up-to (gethash "follow_up_to" body))
         (follow-up-p (nth-value 1 (gethash "follow_up_to" body)))
         (reply-to (gethash "reply_to" body))
         (reply-to-p (nth-value 1 (gethash "reply_to" body))))
    (cond
      ((and turn-key-p follow-up-p)
       (http-fail 400 "Use turn_key or follow_up_to, not both."
                  :code "turn_key_conflict"))
      ((and reply-to-p follow-up-p)
       (http-fail 400 "Use reply_to or follow_up_to, not both."
                  :code "turn_key_conflict"))
      ((and (not (http-service-followups-p service))
            (or turn-key-p follow-up-p reply-to-p))
       (http-fail 400 "This webhook does not accept follow-ups."
                  :code "followups_disabled"))
      (follow-up-p
       (unless (turn-key-p follow-up-to)
         (http-fail 400 "A follow-up key must be 64 lower-case hexadecimal characters."
                    :code "invalid_turn_key"))
       (followup-response service follow-up-to text))
      ((or turn-key-p reply-to-p)
       (when turn-key-p
         (unless (turn-key-p turn-key)
           (http-fail 400 "A turn key must be 64 lower-case hexadecimal characters."
                      :code "invalid_turn_key")))
       (when reply-to-p
         (unless (turn-key-p reply-to)
           (http-fail 400 "A reply_to key must be 64 lower-case hexadecimal characters."
                      :code "invalid_reply_to")))
       (run-message-turn service text author
                         (and turn-key-p turn-key)
                         (and reply-to-p reply-to)))
      (t
       (run-message-turn service text author nil nil)))))

(declaim (ftype (function (http-service http-request) (values integer string))
                handle-http-request))

(defun handle-http-request (service request)
  "Route an authenticated REQUEST to /message, /health, or /usage, returning
(VALUES status body) or signalling 405/404."
  (let ((method (http-request-method request))
        (path (http-request-path request)))
    (cond
      ((and (string= method "POST") (string= path "/message"))
       (message-response service request))
      ((and (string= method "GET") (string= path "/health"))
       (health-response service))
      ((and (string= method "GET") (string= path "/usage"))
       (usage-response service request))
      ((member path '("/message" "/health" "/usage") :test #'string=)
       (http-fail 405 (format nil "~A takes ~A." path (if (string= path "/message")
                                                          "POST"
                                                          "GET"))
                  :allow (if (string= path "/message") "POST" "GET")))
      (t
       (http-fail 404 (format nil "There is no route ~A." path))))))

(declaim (ftype (function (http-service http-request) (values integer string))
                dispatch-http-request))

(defun dispatch-http-request (service request)
  "Authenticate REQUEST (401 on missing or invalid token) and dispatch via HANDLE-HTTP-REQUEST."
  (if (authorized-p service (http-request-authorization request))
      (handle-http-request service request)
      (http-fail 401 "A bearer token is required.")))

;;;; The acceptor.

(defclass http-acceptor (hunchentoot:acceptor)
  ((service :accessor http-acceptor-service :initarg :service :initform nil :type t
            :documentation "The service this acceptor answers for."))
  (:documentation
   "Hunchentoot acceptor dispatching all requests as JSON via HANDLE-HTTP-REQUEST."))

(declaim (ftype (function (integer string &key (:allow t) (:retry-after t)) t)
                abort-with))

(defun abort-with (status body &key allow retry-after)
  "Set STATUS, JSON Content-Type, optional headers, and deliver BODY via ABORT-REQUEST-HANDLER."
  (setf (hunchentoot:return-code*) status
        (hunchentoot:content-type*) "application/json; charset=utf-8")
  (when allow
    (setf (hunchentoot:header-out :allow) allow))
  (when retry-after
    (setf (hunchentoot:header-out :retry-after) retry-after))
  (hunchentoot:abort-request-handler body))

(defmethod hunchentoot:acceptor-dispatch-request ((acceptor http-acceptor) request)
  "Dispatch one request as JSON, catching all errors so hunchentoot never emits HTML.
Checks auth before reading the body, and seals RAW-POST-DATA plus sets
Connection: close whenever a framed body is left unread."
  (let ((service (http-acceptor-service acceptor))
        (started (get-internal-real-time))
        (method (string-upcase (string (hunchentoot:request-method* request))))
        (path (or (hunchentoot:script-name* request) "/")))
    ;; Close if framing cannot be read
    (when (handler-case (request-body-unread-p request)
            (error () t))
      (note-body-abandoned request t))
    (unwind-protect
         (handler-case
             (progn
               (unless (authorized-p service (hunchentoot:header-in* :authorization request))
                 (enchiridion.log:log-warn :http "401 unauthorized ~A ~A" method path)
                 (setf (hunchentoot:header-out :www-authenticate) "Bearer")
                 (http-fail 401 "A bearer token is required."))
               (let ((parsed (request-from-hunchentoot service request)))
                 (multiple-value-bind (status body) (handle-http-request service parsed)
                   (let ((elapsed-ms (round (* 1000 (- (get-internal-real-time) started))
                                            internal-time-units-per-second)))
                     (enchiridion.log:log-info :http "~A ~A -> ~D (~Dms)"
                                               method path status elapsed-ms))
                   (abort-with status body))))
           (http-error (condition)
             (let ((status (http-error-status condition))
                   (elapsed-ms (round (* 1000 (- (get-internal-real-time) started))
                                      internal-time-units-per-second)))
               (unless (= status 401)
                 (if (>= status 500)
                     (enchiridion.log:log-warn :http "~A ~A -> ~D (~Dms): ~A"
                                               method path status elapsed-ms
                                               (http-error-message condition))
                     (enchiridion.log:log-info :http "~A ~A -> ~D (~Dms): ~A"
                                               method path status elapsed-ms
                                               (http-error-message condition))))
               (abort-with status
                           (error-body (http-error-message condition)
                                       (http-error-code condition))
                           :allow (http-error-allow condition)
                           :retry-after (http-error-retry-after condition))))
           (error (condition)
             (format *error-output* "~&enchiridion: webhook error: ~A~%" condition)
             (finish-output *error-output*)
             (abort-with 500 (error-body "the webhook failed to answer."))))
      (when (body-abandoned-p request)
        (seal-request-body request)
        (setf (hunchentoot:header-out :connection) "close")))))

(defmethod hunchentoot:process-request :after ((request http-request-object))
  "Force connection close after START-OUTPUT when the request body was abandoned
by setting hunchentoot's unexported *FINISH-PROCESSING-SOCKET*."
  (when (and (http-request-object-body-abandoned-p request)
             (boundp 'hunchentoot::*finish-processing-socket*))
    (setf hunchentoot::*finish-processing-socket* t)))

;;;; The channel.

(defclass http-channel (enchiridion.channel:channel)
  ((service :accessor http-channel-service :initarg :service :initform nil :type t
            :documentation "The service, with the token, the routes and the limit.")
   (acceptor :accessor http-channel-acceptor :initarg :acceptor :initform nil :type t
             :documentation "The running acceptor, or NIL while the channel is down.")
   (stopped-p :accessor http-channel-stopped-p :initarg :stopped-p :initform nil
              :type boolean
              :documentation "Set by CHANNEL-STOP to release the start loop.")
   (stop-lock :accessor http-channel-stop-lock :initarg :stop-lock
              :initform (bordeaux-threads:make-lock "enchiridion http stop")
              :type t
              :documentation
              "Serializes CHANNEL-STOP and start-loop cleanup so drains complete before returning."))
  (:documentation
   "Webhook channel. CHANNEL-START blocks until CHANNEL-STOP for the supervisor restart loop."))

(declaim (ftype (function (&key (:name string) (:service t))
                           (values http-channel &rest t))
                make-http-channel))

(defun make-http-channel (&key (name "http") service)
  "Return a stopped HTTP channel that answers through SERVICE."
  (make-instance 'http-channel :name name :service service))

(declaim (ftype (function (function real) boolean) wait-until))

(defun wait-until (done-p deadline)
  "Poll DONE-P every 50ms until true or DEADLINE passes; return its last value."
  (loop while (and (not (funcall done-p))
                   (< (get-internal-real-time) deadline))
        do (sleep 0.05))
  (funcall done-p))

(declaim (ftype (function (http-service) integer) turns-running))

(defun turns-running (service)
  "Return the number of in-flight turns on SERVICE under its lock."
  (bordeaux-threads:with-lock-held ((http-service-in-flight-lock service))
    (http-service-in-flight service)))

(declaim (ftype (function (t real) boolean) stop-acceptor-within))

(defun stop-acceptor-within (acceptor deadline)
  "Stop ACCEPTOR on a helper thread bounded by DEADLINE; return T on success.
Avoids hanging when hunchentoot:stop waits for a saturated taskmaster."
  (let ((stopper (bordeaux-threads:make-thread
                  (lambda ()
                    (handler-case
                        (progn (hunchentoot:stop acceptor) :stopped)
                      (error (condition) condition)))
                  :name "enchiridion http stop")))
    (if (wait-until (lambda () (not (bordeaux-threads:thread-alive-p stopper))) deadline)
        (let ((outcome (bordeaux-threads:join-thread stopper)))
          (cond
            ((eq outcome :stopped) t)
            (t
             (format *error-output*
                     "~&enchiridion: stopping the webhook listener failed: ~A~%"
                     outcome)
             (finish-output *error-output*)
             nil)))
        nil)))

(declaim (ftype (function (t t) boolean) request-quiet-p))

(defun request-quiet-p (service acceptor)
  "Return T when no request and no turn is running on ACCEPTOR."
  (and (zerop (or (hunchentoot:acceptor-requests-in-progress acceptor) 0))
       (or (null service) (zerop (turns-running service)))))

(declaim (ftype (function (t t real real) null) drain-requests))

(defun drain-requests (service acceptor deadline seconds)
  "Wait until ACCEPTOR and SERVICE have no active requests or turns, logging if
a turn outlasts DEADLINE."
  (unless (wait-until (lambda () (request-quiet-p service acceptor)) deadline)
    (when (and service (plusp (turns-running service)))
      (format *error-output*
              "~&enchiridion: a webhook turn outlasted the ~A second drain; ~
               it may not reach the ledger.~%"
              seconds)
      (finish-output *error-output*)))
  nil)

(declaim (ftype (function (http-channel &key (:seconds real)) null)
                stop-http-acceptor))

(defun stop-http-acceptor (channel &key (seconds *http-drain-seconds*))
  "Stop CHANNEL's acceptor and drain in-flight requests and turns within SECONDS.
Serialized by STOP-LOCK; retains the acceptor slot if stopping times out."
  (bordeaux-threads:with-lock-held ((http-channel-stop-lock channel))
    (let ((acceptor (http-channel-acceptor channel)))
      (when acceptor
        (let ((service (http-channel-service channel))
              (deadline (+ (get-internal-real-time)
                           (* seconds internal-time-units-per-second))))
          (when (stop-acceptor-within acceptor deadline)
            (drain-requests service acceptor deadline seconds)
            (close-http-turns service)
            (setf (http-channel-acceptor channel) nil))))))
  nil)

(defmethod enchiridion.channel:channel-start ((channel http-channel) &key config)
  "Validate bind policy, start the acceptor, and block until stopped.
Binds HUNCHENTOOT:*LOG-LISP-ERRORS-P* to NIL so handler threads inherit it and
avoid duplicate backtraces."
  (declare (ignore config))
  (let ((service (http-channel-service channel)))
    (unless service
      (error 'enchiridion.errors:configuration-error
             :key :http
             :detail "The channel has no service to answer with."))
    (check-http-policy service)
    ;; Release the previous listener before binding again
    (stop-http-acceptor channel)
    (let ((hunchentoot:*log-lisp-errors-p* nil))
      (setf (http-channel-stopped-p channel) nil)
      (setf (http-channel-acceptor channel)
            (hunchentoot:start
             (make-instance 'http-acceptor
                            :name 'enchiridion-http
                            :address (http-service-bind service)
                            :port (http-service-port service)
                            :request-class 'http-request-object
                            :service service
                            :taskmaster (make-instance
                                         'hunchentoot:one-thread-per-connection-taskmaster
                                         :max-thread-count 8
                                         :max-accept-count 16)
                            :read-timeout +http-read-timeout+
                            :write-timeout +http-read-timeout+
                            :access-log-destination nil
                            :message-log-destination nil
                            :persistent-connections-p t)))
      (setf (enchiridion.channel:channel-live-p channel) t
            (enchiridion.channel:channel-state channel) :live)
      (format *error-output* "~&enchiridion: webhook listening on ~A:~D.~%"
              (http-service-bind service)
              (or (hunchentoot:acceptor-port (http-channel-acceptor channel))
                  (http-service-port service)))
      (finish-output *error-output*)
      (unwind-protect
           (loop while (and (enchiridion.channel:channel-live-p channel)
                            (not (http-channel-stopped-p channel)))
                 do (sleep 0.2))
        (stop-http-acceptor channel)
        ;; Ensure state is cleared if stopped before :live was set.
        (setf (enchiridion.channel:channel-live-p channel) nil
              (enchiridion.channel:channel-state channel) :stopped)))
    channel))

(defmethod enchiridion.channel:channel-stop ((channel http-channel))
  "Mark CHANNEL stopped, stop the acceptor, and wait for the turns in flight."
  (setf (http-channel-stopped-p channel) t)
  (setf (enchiridion.channel:channel-live-p channel) nil
        (enchiridion.channel:channel-state channel) :stopped)
  (stop-http-acceptor channel)
  channel)

(defmethod enchiridion.channel:channel-status ((channel http-channel))
  "Return CHANNEL's state."
  (enchiridion.channel:channel-state channel))

;;;; Entry points.

(declaim (ftype (function (&key (:turn t) (:health t) (:usage t) (:token t)
                                (:bind string) (:port integer) (:body-limit integer)
                                (:followups-p boolean) (:name string))
                          (values http-channel &rest t))
                start-http))

(defun start-http (&key turn health usage token (bind "127.0.0.1") (port 8787)
                        (body-limit +http-body-limit+) (followups-p nil) (name "http"))
  "Create and start an HTTP-CHANNEL with these options; blocks until STOP-HTTP."
  (let ((channel (make-http-channel
                  :name name
                  :service (make-http-service :turn turn :health health :usage usage
                                              :token token :bind bind :port port
                                              :body-limit body-limit
                                              :followups-p followups-p))))
    (enchiridion.channel:channel-start channel)
    channel))

(declaim (ftype (function (http-channel) (values http-channel &rest t)) stop-http))

(defun stop-http (channel)
  "Stop CHANNEL and return it."
  (enchiridion.channel:channel-stop channel))

(declaim (ftype (function (http-channel) boolean) http-running-p))

(defun http-running-p (channel)
  "Return T while CHANNEL is accepting requests."
  (not (null (enchiridion.channel:channel-live-p channel))))
