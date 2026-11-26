;;;; http.lsp --- Shared HTTP transport, bounded response reading, and retry loop.

(in-package #:enchiridion.llm)

;;;; Small shared helpers.

(declaim (ftype (function (string) string) ensure-trailing-slash))

(defun ensure-trailing-slash (url)
  "Return URL with a trailing slash, appending one if missing."
  (if (and (plusp (length url))
           (char= (char url (1- (length url))) #\/))
      url
      (concatenate 'string url "/")))

(declaim (ftype (function () string) new-session-id))

(defun new-session-id ()
  "Return a 32-character uppercase hex session ID."
  (format nil "~32,'0X" (random (expt 2 128))))

(declaim (ftype (function (list list) list) merge-headers))

(declaim (ftype (function (t) list) beta-list))

(defun beta-list (value)
  "Normalize VALUE (comma-separated string or list of strings) into a list of
feature names."
  (cond
    ((null value) '())
    ((stringp value)
     (remove-if #'zerop
                (mapcar (lambda (beta) (string-trim '(#\Space #\Tab) beta))
                        (uiop:split-string value :separator ","))
                :key #'length))
    ((listp value) (remove-if-not #'stringp value))
    (t '())))

(declaim (ftype (function (list) list) header-pairs))

(defun header-pairs (headers)
  "Normalize HEADERS into an alist of (NAME . VALUE) conses for dexador, which
formats (NAME VALUE) lists with parentheses."
  (loop for header in headers
        when header
          collect (if (consp (cdr header))
                      (cons (car header) (cadr header))
                      header)))

(declaim (ftype (function (list list) list) merge-headers))

(defun merge-headers (base extra)
  "Merge EXTRA onto BASE case-insensitively (EXTRA wins), normalizing both sides
via HEADER-PAIRS."
  (let ((result (header-pairs base)))
    (dolist (header (header-pairs extra) result)
      (let ((name (car header)))
        (setf result
              (remove-if (lambda (candidate)
                           (string-equal (string (car candidate)) (string name)))
                         result))
        (push header result)))))

;;;; The request.

;; HEADERS must be an alist of (NAME . VALUE) conses for dexador.
(defstruct (http-request (:constructor make-http-request))
  (:url "" :type string)
  (:body "" :type string)
  (:headers '() :type list)
  (:timeout 60 :type (integer 1 *)))

;;;; The transport.

;; dexador uses :content, :read-timeout, and :connect-timeout, and signals
;; HTTP-REQUEST-FAILED on 4xx/5xx (status via RESPONSE-STATUS).
(defparameter *request-deadline-factor* 5
  "The wall-clock deadline as a multiple of one socket timeout.")

(defparameter +http-response-limit+ (* 16 1024 1024)
  "The maximum response body size in bytes.")

(defparameter *http-request-function* #'dexador:request
  "The low-level HTTP request function, replaced in transport tests.")

(defun bounded-response-text (body limit)
  "Return BODY as UTF-8 text, rejecting bodies larger than LIMIT bytes."
  (labels ((check-size (size)
             (when (> size limit)
               (error 'enchiridion.errors:transport-error
                      :detail (format nil "HTTP response exceeds ~D bytes" limit)))))
    (typecase body
      (string
       (check-size (length (enchiridion.compat:encode-utf8 body)))
       body)
      ((vector (unsigned-byte 8))
       (check-size (length body))
       (enchiridion.compat:decode-utf8 body))
      (stream
       (unwind-protect
            (let* ((octets (make-array (1+ limit) :element-type '(unsigned-byte 8)))
                   (count (read-sequence octets body)))
              (check-size count)
              (enchiridion.compat:decode-utf8 (subseq octets 0 count)))
         (close body)))
      (t (error 'enchiridion.errors:transport-error
                :detail "HTTP response is not text or a binary stream")))))

(defun bounded-http-request (request &key (method :post)
                                         (body-limit +http-response-limit+))
  "Send REQUEST with an overall deadline and a bounded response body."
  (let ((seconds (* *request-deadline-factor* (http-request-timeout request))))
    (enchiridion.compat:with-deadline
        (seconds :on-timeout
                 (error 'enchiridion.errors:transport-error
                        :detail (format nil "no reply within ~A seconds" seconds)))
      (handler-bind
          ((dexador.error:http-request-failed
             (lambda (failure)
               (setf (slot-value failure 'dexador.error::body)
                     (bounded-response-text (dexador.error:response-body failure)
                                            body-limit)))))
        (multiple-value-bind (body status)
            (funcall *http-request-function* (http-request-url request)
                     :method method
                     :headers (http-request-headers request)
                     :content (http-request-body request)
                     :read-timeout (http-request-timeout request)
                     :connect-timeout (http-request-timeout request)
                     :want-stream t :force-binary t
                     :keep-alive nil :use-connection-pool nil :max-redirects 0)
          (let ((text (bounded-response-text body body-limit)))
            (when (and status (not (<= 200 status 299)))
              (error 'enchiridion.errors:transport-error
                     :status status :detail "HTTP endpoint did not return success"))
            text))))))

(declaim (ftype (function (http-request) string) http-post))

(defun http-post (request)
  "POST REQUEST and return the reply text."
  (bounded-http-request request))

(defparameter *http-post-function* #'http-post
  "The function POST-WITH-RETRIES uses to make one HTTP request. Bound in tests.")

(defparameter *retry-delay* 2
  "Base retry backoff in seconds (attempt N sleeps N * *RETRY-DELAY*). Bound to 0 in tests.")

(declaim (ftype (function (string) (or null string)) provider-error-message))

(defun provider-error-message (payload)
  "Extract a provider error message from JSON PAYLOAD, or return a fallback note
if non-JSON."
  (handler-case
      (let* ((parsed (parse-json payload))
             (error-object (getf parsed :error)))
        (cond
          ((and (listp error-object) (stringp (getf error-object :message)))
           (getf error-object :message))
          ((stringp (getf parsed :error_description))
           (getf parsed :error_description))
          ((stringp error-object) error-object)
          ;; AWS and GCP use top-level message/Message without an error wrapper.
          ((stringp (getf parsed :message)) (getf parsed :message))
          ((stringp (getf parsed :Message)) (getf parsed :Message))
          (t (string-right-trim '(#\Space #\Newline #\Return) (or payload "")))))
    (error () "the provider replied with something that is not JSON")))

(declaim (ftype (function (function http-request (integer 0 *)) string)
                post-with-retries))

(defun post-with-retries (transport request retries)
  "Send REQUEST via TRANSPORT, retrying HTTP 429 and 5xx up to RETRIES times
with linear backoff (*RETRY-DELAY* * attempt). Each attempt has a wall-clock
deadline of *REQUEST-DEADLINE-FACTOR* * timeout; timeouts and other 4xx fail immediately."
  (let ((attempt 0)
        (deadline (* *request-deadline-factor* (http-request-timeout request))))
    (loop
      (handler-case
          (return (enchiridion.compat:with-deadline
                      (deadline :on-timeout
                                (error 'enchiridion.errors:transport-error
                                       :detail (format nil "no reply within ~A seconds"
                                                       deadline)))
                    (funcall transport request)))
        (dexador.error:http-request-failed (failure)
          (let ((status (dexador.error:response-status failure)))
            (if (and (integerp status)
                     (or (= status 429) (>= status 500))
                     (< attempt retries))
                (progn (incf attempt)
                       (sleep (* *retry-delay* attempt)))
                (error 'enchiridion.errors:transport-error
                       :status status
                       :detail (format nil "~D after ~D attempt~:P: ~A"
                                       status
                                       (1+ attempt)
                                       (provider-error-message
                                        (dexador.error:response-body failure)))))))))))

;;;; The one GET.

(defparameter +http-get-timeout+ 10
  "Seconds before one catalog or model-list request is abandoned.")

(defun http-get (url &key headers (timeout +http-get-timeout+))
  "GET URL and return the reply text."
  (bounded-http-request (make-http-request :url url :headers headers :timeout timeout)
                        :method :get))

(defparameter *http-get-function* #'http-get
  "HTTP GET function used by catalog and model listers. Bound in tests.")

(defun get-with-retries (request &optional (retries 2))
  "GET REQUEST through the shared deadline and retry policy."
  (post-with-retries
   (lambda (value)
     (bounded-response-text
      (funcall *http-get-function* (http-request-url value)
               :headers (http-request-headers value)
               :timeout (http-request-timeout value))
      +http-response-limit+))
   request retries))
