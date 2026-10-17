;;;; config.cl --- Reading the operator configuration.
;;;;
;;;; config.example.cl writes a sectioned list: :LLM is followed by a list of
;;;; (key value) entries, then :CHANNELS by one entry per channel, and so on.
;;;; That is not a property list. GETF on it reads the first section name and
;;;; its first entry, then treats every later entry as a key, so a configured
;;;; model silently becomes the default. The reader below is the one place
;;;; that knows the difference.
;;;;
;;;; A flat property list is still accepted. The tests and a small config are
;;;; easier to read that way, and the flat shape was the only shape the first
;;;; adapter understood. The sectioned shape wins when both could match.

(in-package #:enchiridion)

(defparameter +config-sections+
  '(:llm :channels :budget :sandbox :memory :sleep)
  "The top-level section names. A sectioned config is one of these keywords,
followed by a list of (key value ...) entries, until the next section name.")

(declaim (ftype (function (t) boolean) sectioned-config-p))

(defun sectioned-config-p (config)
  "Return T when CONFIG uses the sectioned shape from config.example.cl."
  (and (consp config)
       (member (first config) +config-sections+ :test #'eq)
       (consp (second config))))

(declaim (ftype (function (t keyword) list) config-section))

(defun config-section (config name)
  "Return the entries under section NAME, each a (key value ...) list.
Return NIL when the section is absent or CONFIG is flat."
  (when (sectioned-config-p config)
    (let ((tail (member name config :test #'eq)))
      (when tail
        (loop for entry in (cdr tail)
              while (consp entry)
              collect entry)))))

(declaim (ftype (function (t keyword &optional t) t) config-value))

(defun config-value (config key &optional default)
  "Return KEY from CONFIG, or DEFAULT.
CONFIG is either the sectioned shape from config.example.cl or a flat
property list. The sectioned shape is tried first. The flat shape is the
fallback, so a one-line config still reads the way it looks."
  (let ((entry (assoc key (config-section config :llm) :test #'eq)))
    (cond
      (entry (second entry))
      ((sectioned-config-p config) default)
      (t (getf config key default)))))
