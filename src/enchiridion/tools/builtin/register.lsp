;;;; register.lsp --- Aggregator registering all built-in tools.
;;;; Loaded last because undefined-function warnings are build errors.

(in-package #:enchiridion.tools.builtin)

(defun register-builtin-tools ()
  "Register every built-in tool. Idempotent."
  (+ (register-file-tools)
     (register-shell-tools)
     (register-search-tools)
     (register-block-tools)
     (register-memory-tools)
     (register-meta-tools)
     (register-presence-tools)
     (register-web-tools)))
