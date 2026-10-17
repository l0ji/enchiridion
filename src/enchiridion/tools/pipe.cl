;;;; pipe.cl --- The Lisp filter sandbox.
;;;;
;;;; Shell output is expensive to put in a transcript. A filter is one Lisp
;;;; expression that keeps or drops lines, so the same work costs no tokens.
;;;;
;;;; The filter is not arbitrary Lisp. A form may use only the names in
;;;; +ALLOWED-SYMBOLS+ and the line variable $. The walker runs before EVAL, so
;;;; a form that names SYSTEM, LOAD, EVAL, or any other door is rejected even
;;;; though the sandbox package has the CL functions the allowed names use.

(in-package #:enchiridion.tools.pipe)

(defparameter +allowed-symbols+
  '("$" "FILTER" "NTH4" "NTH" "FIRST" "SECOND" "THIRD" "LENGTH" "SUBSEQ"
    "SEARCH" "PARSE-INTEGER" "STRING-UPCASE" "STRING-DOWNCASE" "STRING="
    "STRING<" "STRING>" "PRINC-TO-STRING" "FORMAT" "LIST" "IDENTITY"
    "IF" "AND" "OR" "NOT" "NULL" "T" "NIL" "=" "/=" ">" "<" ">=" "<=" "+" "-" "*" "/")
  "Every symbol a filter form may contain, by name. Symbols from any package
compare by name here, so a form read before the sandbox existed is still
checked against one list.")

(defparameter +allowed-operators+
  '("+" "-" "*" "/" "=" "/=" ">" "<" ">=" "<=")
  "Function names that are also operators. The walker treats them as allowed
because they are in the list above; this constant exists to make the intent
readable at the point that matters.")

(declaim (ftype (function (t) boolean) allowed-symbol-p))

(defun allowed-symbol-p (symbol)
  "Return T when SYMBOL is the line variable or one of the allowed names."
  (not (null (member (symbol-name symbol) +allowed-symbols+ :test #'string=))))

(declaim (ftype (function (t) t) check-form))

(defun check-form (form)
  "Walk FORM and signal when a symbol is outside the filter language.
Strings, numbers, and characters are data and pass. A cons is walked
recursively. Quoting and function definitions are not in the language."
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
  "Return a fresh package that holds $ and NTH4 for one filter.

The package uses CL, and the walker is what keeps a form out of the rest of
CL. A fresh package per filter means a later filter cannot see a binding or a
helper left by an earlier one."
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
  "Read one filter form from TEXT with *READ-EVAL* NIL.
The optional SANDBOX is where $ and NTH4 live. A string that holds a second
form is rejected: a filter is one expression, not a program."
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
  "Evaluate one allowed filter FORM with $ bound to LINE.
The caller normally gets FORM from READ-FILTER, which has already checked it.
This function checks again because a caller can hold a form that came from
somewhere else."
  (check-form form)
  (let* ((package (or sandbox (make-sandbox)))
         (dollar (intern "$" package))
         (*package* package))
    (progv (list dollar) (list line)
      (eval form))))

(declaim (ftype (function (string t) string) pipe-eval))

(defun pipe-eval (text filter)
  "Return TEXT with only the lines for which FILTER is true.

FILTER is a string read by READ-FILTER, a form from it, or a function of one
line. The line variable $ is bound for each line. The result is text with one
newline after each kept line, which is what the shell tool would have shown."
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
