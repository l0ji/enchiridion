;;;; register.cl --- One place that registers every builtin.
;;;;
;;;; The aggregator lives after the files it names. A function body may name a
;;;; later function, but a warning about an undefined function is an error in
;;;; this tree, so the order is part of the build.

(in-package #:enchiridion.tools.builtin)

(defun register-builtin-tools ()
  "Register every built-in tool. Idempotent."
  (+ (register-file-tools)
     (register-shell-tools)
     (register-search-tools)
     (register-block-tools)
     (register-memory-tools)
     (register-meta-tools)
     (register-web-tools)))
