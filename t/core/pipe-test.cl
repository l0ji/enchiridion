;;;; pipe-test.cl --- The filter sandbox.
;;;;
;;;; A filter is one expression over one line. It saves tokens only if it is
;;;; cheap and safe to run; the tests are about the second half.

(defpackage #:enchiridion-pipe-test
  (:use #:cl)
  (:import-from #:rove #:deftest #:ok #:ng #:testing #:signals)
  (:export #:run))

(in-package #:enchiridion-pipe-test)

(defparameter +listing+
  (format nil "a b c d 150~%a b c d 50~%a b c d 200~%"))

(deftest a-filter-keeps-the-lines-that-pass ()
  (let ((output (enchiridion.tools.pipe:pipe-eval
                 +listing+
                 "(filter (> (nth4 $) 100))")))
    (ok (search "a b c d 150" output))
    (ok (search "a b c d 200" output))
    (ng (search "a b c d 50" output))))

(deftest a-string-search-filter-works ()
  (let ((output (enchiridion.tools.pipe:pipe-eval
                 (format nil "foo one~%bar two~%foo three~%")
                 "(filter (search \"foo\" $))")))
    (ok (search "foo one" output))
    (ok (search "foo three" output))
    (ng (search "bar two" output))))

(deftest an-empty-input-is-an-empty-result ()
  (ok (string= "" (enchiridion.tools.pipe:pipe-eval "" "(filter t)"))))

(deftest a-sensitive-symbol-is-rejected-before-eval ()
  (ok (signals (enchiridion.tools.pipe:read-filter
                "(filter (system \"echo owned\"))")
               'enchiridion.errors:schema-error))
  (ok (signals (enchiridion.tools.pipe:read-filter
                "(filter (load \"x\"))")
               'enchiridion.errors:schema-error))
  (ok (signals (enchiridion.tools.pipe:read-filter
                "(filter t) (filter nil)")
               'enchiridion.errors:schema-error)))

(deftest a-sandbox-is-a-package ()
  (ok (packagep (enchiridion.tools.pipe:make-sandbox)))
  (ok (consp (enchiridion.tools.pipe:read-filter "(filter t)"))))

(deftest a-filter-form-is-unwrapped ()
  (let* ((form (enchiridion.tools.pipe:filter-form
                (enchiridion.tools.pipe:read-filter "(filter (> (nth4 $) 100))")))
         (text (prin1-to-string form)))
    (ok (consp form))
    (ok (search "NTH4" text))
    (ok (search "$" text))))
