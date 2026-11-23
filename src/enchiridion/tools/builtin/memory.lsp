;;;; memory.lsp --- Named memories and shadow canary proposals.
;;;;
;;;; The store has held memories since the first session, and the model had no
;;;; way to write one. This tool is the turn-surface half of SAVE-MEMORY: the
;;;; name and body go through the same scrub and duplicate checks as any Lisp
;;;; caller, and the store is opened only for the write.

(in-package #:enchiridion.tools.builtin)

(defun memory-store-path ()
  "Return the store path for the memory tool."
  (or enchiridion.memory.store:*store-path*
      (enchiridion.memory.store:default-store-path)))

(defun memory-run (args)
  "Save NAME with TEXT and return one line about what was stored."
  (let ((name (argument args "name"))
        (text (argument args "text")))
    (unless (and (stringp name)
                 (plusp (length (string-trim '(#\Space #\Tab #\Newline #\Return)
                                             name))))
      (error 'enchiridion.errors:schema-error
             :detail "name must be a non-empty string."))
    (unless (stringp text)
      (error 'enchiridion.errors:schema-error
             :detail "text must be a string."))
    (let ((store (enchiridion.memory.store:open-store
                  :path (memory-store-path))))
      (unwind-protect
           (let ((id (enchiridion.memory.store:save-memory store name text)))
             (format nil "saved memory ~A as ~D" name id))
        (enchiridion.memory.store:close-store store)))))

(defun canary-run (args)
  "Propose a shadow canary from a stored episode."
  (let ((store (enchiridion.memory.store:open-store :path (memory-store-path))))
    (unwind-protect
         (format nil "Proposed shadow canary ~A. Only the operator can make it blocking."
                 (enchiridion.memory:propose-canary
                  store (argument args "family") (argument args "cue")
                  (argument args "expect") (argument args "episode")
                  :stale (argument args "stale")))
      (enchiridion.memory.store:close-store store))))

(defparameter +memory-tools+
  (list
   (enchiridion.tools:make-tool
    :name "canary"
    :description "Propose a nonblocking memory retrieval check. Cite a stored episode containing expect verbatim. Families: retrieval, update, safety, tail. For safety, expect is the text that must stay out. Only update takes stale."
    :schema '(:object :required (:family :cue :expect :episode)
              :properties ((:family :string) (:cue :string) (:expect :string)
                           (:episode :integer) (:stale :string)))
    :handler #'canary-run)
   (enchiridion.tools:make-tool
    :name "memory"
    :description "Save a named memory with the text the model wants to keep."
    :schema '(:object :required (:name :text)
              :properties ((:name :string) (:text :string)))
    :handler #'memory-run)))

(defun register-memory-tools ()
  "Register the memory tools. Idempotent."
  (dolist (tool +memory-tools+)
    (enchiridion.tools:register-tool tool))
  (length +memory-tools+))
