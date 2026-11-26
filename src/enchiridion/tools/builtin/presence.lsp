;;;; presence.lsp --- Public custom status proposal tool.

(in-package #:enchiridion.tools.builtin)

(declaim (ftype (function (t) t) presence-run))

(defun presence-run (args)
  "Validate a custom status proposal (TEXT or CLEAR); the Fluxer channel enforces limits and publishing."
  (let ((text (argument args "text"))
        (clear (argument args "clear")))
    (cond
      ((and (not (null clear)) (stringp text))
       (error 'enchiridion.errors:schema-error
              :detail "Give text or clear, not both."))
      ((and (null clear) (not (stringp text)))
       (error 'enchiridion.errors:schema-error
              :detail "Give the status text as a string, or clear true."))
      ((and (stringp text)
            (zerop (length (string-trim '(#\Space #\Tab #\Newline #\Return)
                                        text))))
       (error 'enchiridion.errors:schema-error
              :detail "The status text is blank."))
      ((not (null clear))
       "Proposed clearing the Fluxer custom status.")
      (t
       "Proposed a Fluxer custom status. The channel decides whether to show it."))))

(defparameter +presence-tools+
  (list
   (enchiridion.tools:make-tool
    :name "presence"
    :description "Propose a short, public custom status for the agent's Fluxer presence, or clear it. One line, at most 128 characters. The Fluxer channel validates, rate limits, deduplicates and expires it; never propose private reasoning, message content, or secrets."
    :schema '(:object :properties ((:text :string) (:clear :boolean)))
    :handler #'presence-run)))

(defun register-presence-tools ()
  "Register the presence tool. Idempotent."
  (dolist (tool +presence-tools+)
    (enchiridion.tools:register-tool tool))
  (length +presence-tools+))
