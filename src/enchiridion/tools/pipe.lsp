;;;; pipe.lsp --- Restricted Lisp line-filter sandbox.
;;;; Forms are validated by CHECK-FORM against +ALLOWED-SYMBOLS+ before EVAL.

(in-package #:enchiridion.tools.pipe)

(defparameter +allowed-symbols+
  '("$" "FILTER" "NTH4" "NTH" "FIRST" "SECOND" "THIRD" "LENGTH" "SUBSEQ"
    "SEARCH" "PARSE-INTEGER" "STRING-UPCASE" "STRING-DOWNCASE" "STRING="
    "STRING<" "STRING>" "PRINC-TO-STRING" "FORMAT" "LIST" "IDENTITY"
    "IF" "AND" "OR" "NOT" "NULL" "T" "NIL" "=" "/=" ">" "<" ">=" "<=" "+" "-" "*" "/")
  "Symbol names permitted in filter forms (matched by SYMBOL-NAME across packages).")

(defparameter +allowed-operators+
  '("+" "-" "*" "/" "=" "/=" ">" "<" ">=" "<=")
  "Arithmetic and comparison operator names (subset of +ALLOWED-SYMBOLS+).")

(declaim (ftype (function (t) boolean) allowed-symbol-p))

(defun allowed-symbol-p (symbol)
  "Return T when SYMBOL is the line variable or one of the allowed names."
  (not (null (member (symbol-name symbol) +allowed-symbols+ :test #'string=))))

(declaim (ftype (function (t) t) check-form))

(defun check-form (form)
  "Recursively walk FORM and signal SCHEMA-ERROR on any symbol outside +ALLOWED-SYMBOLS+.
Literals (strings, numbers, characters) pass; quoting and definitions are excluded."
  (cond
    ((symbolp form)
     (unless (allowed-symbol-p form)
       (error 'enchiridion.errors:schema-error
              :detail (format nil "Filter symbol ~A is not allowed." form)))
     form)
    ((consp form)
     (dolist (part form)
       (check-form part))
     form)
    (t form)))

(declaim (ftype (function () package) make-sandbox))

(defun make-sandbox ()
  "Return a fresh package using :CL with special variable $ and helper function NTH4.
CHECK-FORM restricts evaluation to +ALLOWED-SYMBOLS+; per-filter packages isolate state."
  (let* ((name (format nil "ENCHIRIDION-FILTER-~D" (random most-positive-fixnum)))
         (package (make-package name :use '(:cl))))
    (let ((dollar (intern "$" package)))
      (proclaim `(special ,dollar))
      (setf (symbol-value dollar) ""))
    (setf (symbol-function (intern "NTH4" package))
          (lambda (text)
            (let ((field (nth 4 (split-fields text))))
              (or (and field (parse-integer field :junk-allowed t)) field))))
    package))

(defun split-fields (text)
  "Return the whitespace separated fields of TEXT."
  (let ((fields '())
        (start 0)
        (length (length text)))
    (loop for index from 0 to length
          when (or (= index length)
                   (member (char text index) '(#\Space #\Tab #\Newline)))
            do (when (> index start)
                 (push (subseq text start index) fields))
               (setf start (1+ index)))
    (nreverse fields)))

(defun read-filter (text &key (sandbox nil))
  "Read and validate a single filter form from TEXT with *READ-EVAL* NIL.
Uses SANDBOX (or a fresh one) for $ and NTH4; rejects empty or multi-form input."
  (let* ((package (or sandbox (make-sandbox)))
         (*package* package)
         (*read-eval* nil))
    (multiple-value-bind (form position)
        (read-from-string text nil :eof)
      (when (eq form :eof)
        (error 'enchiridion.errors:schema-error
               :detail "The filter is empty."))
      (let ((rest (string-trim '(#\Space #\Tab #\Newline #\Return)
                               (subseq text position))))
        (unless (zerop (length rest))
          (error 'enchiridion.errors:schema-error
                 :detail "The filter has more than one form.")))
      (check-form form)
      form)))

(declaim (ftype (function (t) t) filter-form))

(defun filter-form (form)
  "Return the expression inside (FILTER ...), or FORM when it is already one."
  (if (and (consp form)
           (symbolp (first form))
           (string= (symbol-name (first form)) "FILTER"))
      (second form)
      form))

(defun pipe-safe-eval (form &key (line "") (sandbox nil))
  "Re-validate and evaluate FORM with $ bound to LINE in SANDBOX (or a fresh sandbox)."
  (check-form form)
  (let* ((package (or sandbox (make-sandbox)))
         (dollar (intern "$" package))
         (*package* package))
    (progv (list dollar) (list line)
      (eval form))))

(declaim (ftype (function (string t) string) pipe-eval))

(defun pipe-eval (text filter)
  "Filter non-empty lines of TEXT using FILTER (string, form, or predicate function),
binding $ to each line and returning kept lines terminated by newlines."
  (let* ((sandbox (make-sandbox))
         (form (cond
                 ((stringp filter)
                  (filter-form (read-filter filter :sandbox sandbox)))
                 ((functionp filter) filter)
                 (t (filter-form filter)))))
    (with-output-to-string (stream)
      (dolist (line (uiop:split-string text :separator (list #\Newline)))
        (unless (zerop (length line))
          (let ((keep (if (functionp form)
                          (funcall form line)
                          (pipe-safe-eval form :line line :sandbox sandbox))))
            (when keep
              (write-string line stream)
              (terpri stream))))))))
