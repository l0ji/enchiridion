;;;; log.lsp --- Shared thread-safe, level-filtered, secret-scrubbed logging.
;;;;
;;;; Writes single-line UTC-timestamped plaintext entries to *LOG-STREAM*
;;;; (defaulting dynamically to *STANDARD-OUTPUT* for container/Docker logs).
;;;; Secrets are scrubbed via *SCRUBBER* once enchiridion.llm.secrets loads.

(in-package #:enchiridion.log)

(defparameter *log-level* :warn
  "Minimum severity emitted (:DEBUG, :INFO, :WARN, :ERROR, or :OFF).")

(defparameter *log-stream* nil
  "Optional output stream override. NIL writes to *STANDARD-OUTPUT*.")

(defparameter *scrubber* nil
  "Optional (STRING -> STRING) secret scrubber installed by the secrets module.")

(defparameter *log-lock* (bordeaux-threads:make-lock "enchiridion log")
  "Serializes writes across supervisor, heartbeat, channel, and broker threads.")

(defparameter +level-ranks+
  '((:debug . 0)
    (:info  . 1)
    (:warn  . 2)
    (:error . 3)
    (:off   . 4))
  "Ordered severity ranks; messages with rank >= *LOG-LEVEL* rank are emitted.")

(declaim (ftype (function (keyword) (integer 0 4)) level-rank))

(defun level-rank (level)
  "Return the numeric rank of LEVEL, defaulting to :WARN rank if unrecognized."
  (or (cdr (assoc level +level-ranks+ :test #'eq)) 2))

(declaim (ftype (function (t &optional keyword) keyword) parse-log-level))

(defun parse-log-level (value &optional (default :warn))
  "Normalize VALUE (keyword or string) to a log level keyword, or DEFAULT."
  (cond
    ((null value) default)
    ((and (keywordp value) (assoc value +level-ranks+ :test #'eq)) value)
    ((or (stringp value) (symbolp value))
     (let ((name (string-downcase
                  (string-trim '(#\Space #\Tab #\Newline #\Return)
                               (string value)))))
       (cond
         ((string= name "debug") :debug)
         ((string= name "info") :info)
         ((or (string= name "warn") (string= name "warning")) :warn)
         ((string= name "error") :error)
         ((or (string= name "off") (string= name "none") (string= name "quiet")) :off)
         (t default))))
    (t default)))

(declaim (ftype (function (keyword) boolean) level-enabled-p))

(defun level-enabled-p (level)
  "Return T when LEVEL meets or exceeds *LOG-LEVEL* (and *LOG-LEVEL* is not :OFF)."
  (let ((threshold (level-rank *log-level*)))
    (and (< threshold 4)
         (>= (level-rank level) threshold))))

(declaim (ftype (function (keyword) string) level-label))

(defun level-label (level)
  "Return a fixed-width uppercase label for LEVEL."
  (case level
    (:debug "DEBUG")
    (:info  "INFO ")
    (:warn  "WARN ")
    (:error "ERROR")
    (t      "LOG  ")))

(declaim (ftype (function (&optional integer) string) utc-timestamp))

(defun utc-timestamp (&optional (universal-time (get-universal-time)))
  "Format UNIVERSAL-TIME as an ISO-8601 UTC timestamp."
  (multiple-value-bind (second minute hour day month year)
      (decode-universal-time universal-time 0)
    (format nil "~4,'0D-~2,'0D-~2,'0DT~2,'0D:~2,'0D:~2,'0DZ"
            year month day hour minute second)))

(declaim (ftype (function (string) string) sanitize-log-text))

(defun sanitize-log-text (text)
  "Flatten control whitespace to prevent log-line injection and scrub secrets."
  (let* ((flat (map 'string
                    (lambda (character)
                      (if (or (char= character #\Newline)
                              (char= character #\Return)
                              (char= character #\Tab))
                          #\Space
                          character))
                    text))
         (scrubber *scrubber*))
    (if scrubber
        (handler-case (funcall scrubber flat)
          (error () flat))
        flat)))

(declaim (ftype (function (keyword t string &rest t) null) log-event))

(defun log-event (level subsystem control &rest arguments)
  "Format and emit one plaintext log line to stdout (or *LOG-STREAM*) if LEVEL is enabled. Never signals."
  (when (level-enabled-p level)
    (let* ((raw (handler-case (apply #'format nil control arguments)
                  (error () (format nil "~A (format error)" control))))
           (body (sanitize-log-text raw))
           (tag (string-downcase (string subsystem)))
           (line (format nil "~A ~A [~A] ~A"
                         (utc-timestamp) (level-label level) tag body))
           (stream (or *log-stream* *standard-output*)))
      (bordeaux-threads:with-lock-held (*log-lock*)
        (when stream
          (ignore-errors
            (write-line line stream)
            (finish-output stream))))))
  nil)

(defmacro log-debug (subsystem control &rest arguments)
  "Emit a :DEBUG log line for SUBSYSTEM if debug logging is enabled."
  `(when (level-enabled-p :debug)
     (log-event :debug ,subsystem ,control ,@arguments)))

(defmacro log-info (subsystem control &rest arguments)
  "Emit an :INFO log line for SUBSYSTEM if info logging is enabled."
  `(when (level-enabled-p :info)
     (log-event :info ,subsystem ,control ,@arguments)))

(defmacro log-warn (subsystem control &rest arguments)
  "Emit a :WARN log line for SUBSYSTEM if warn logging is enabled."
  `(when (level-enabled-p :warn)
     (log-event :warn ,subsystem ,control ,@arguments)))

(defmacro log-error (subsystem control &rest arguments)
  "Emit an :ERROR log line for SUBSYSTEM if error logging is enabled."
  `(when (level-enabled-p :error)
     (log-event :error ,subsystem ,control ,@arguments)))

(declaim (ftype (function (&key (:config t) (:default-level keyword)) keyword)
                configure-logging))

(defun configure-logging (&key config (default-level :warn))
  "Configure *LOG-LEVEL* from ENCHIRIDION_LOG_LEVEL, :LOGGING config, or DEFAULT-LEVEL."
  (let ((env-level (uiop:getenv "ENCHIRIDION_LOG_LEVEL"))
        (cfg-level (and config
                        (enchiridion:config-section-value config :logging :level nil))))
    (setf *log-level*
          (cond
            ((and (stringp env-level) (plusp (length env-level)))
             (parse-log-level env-level default-level))
            (cfg-level
             (parse-log-level cfg-level default-level))
            (t (parse-log-level default-level :warn))))
    *log-level*))
