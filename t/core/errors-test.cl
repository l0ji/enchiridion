;;;; errors-test.cl --- The condition hierarchy.
;;;;
;;;; The tests that matter here are the ones that ask a condition a question.
;;;; A formatted string cannot be recovered from; a condition can, and the
;;;; block overflow report is the case that decides whether an agent can
;;;; consolidate in the same call or has to guess.

(defpackage #:enchiridion-errors-test
  (:use #:cl)
  (:import-from #:rove #:deftest #:ok #:ng #:testing #:signals)
  (:export #:run))

(in-package #:enchiridion-errors-test)

(defparameter *leaves*
  ;; A condition type, and the initargs it needs to exist at all. A slot
  ;; declared with :initarg and no :initform is a required initarg, so
  ;; (make-condition 'not-found) signals instead of constructing. These are
  ;; deliberately required: a lookup that fails without a name to look for is
  ;; a bug, and the report of a bug should not paper over it. The table
  ;; carries the arguments so the tests below exercise real conditions.
  '((enchiridion.errors:configuration-error nil)
    (enchiridion.errors:usage-error        (:argument "chat"))
    (enchiridion.errors:missing-command    (:name "nope"))
    (enchiridion.errors:backend-error      nil)
    (enchiridion.errors:transport-error    (:status 503))
    (enchiridion.errors:tool-error         (:tool "file-read"))
    (enchiridion.errors:schema-error       (:tool "file-read" :path '(:path)))
    (enchiridion.errors:block-frozen       (:label :world))
    (enchiridion.errors:bootstrap-pending  (:label :soul))
    (enchiridion.errors:duplicate-message  (:id "m-1"))
    (enchiridion.errors:not-found          (:kind "skill" :name "welcome"))
    (enchiridion.errors:unauthorized       nil))
  "Every leaf condition, paired with the initargs that construct it.")

(defparameter *leaves-with-slots*
  '((enchiridion.errors:block-overflow (:label :persona :current 1 :wanted 2))
    (enchiridion.errors:budget-exceeded (:spent 1 :cap 2)))
  "The two leaves that are about numbers rather than about a name.")

(deftest every-condition-is-an-enchiridion-error ()
  (dolist (row (append *leaves* *leaves-with-slots*))
    (destructuring-bind (condition-type initargs) row
      (testing (format nil "~A descends from enchiridion-error" condition-type)
        ;; apply, not a bare call: MAKE-CONDITION takes &rest initargs, so a
        ;; plist held in a variable has to be splatted. Passed whole it
        ;; arrives as one argument and the condition is built wrong.
        (ok (typep (apply #'make-condition condition-type initargs)
                   'enchiridion.errors:enchiridion-error))
        ;; And from error, so that an unhandled one still lands somewhere sane.
        (ok (typep (apply #'make-condition condition-type initargs) 'error)))))
  (testing "and so does the root"
    (ok (typep (make-condition 'enchiridion.errors:enchiridion-error)
               'error))))

(deftest a-constructed-condition-still-prints ()
  ;; Whatever a condition actually says, printing it must not signal. A report
  ;; method that raises turns a failure into a crash inside the crash handler,
  ;; which is the worst place to find a second bug.
  (dolist (row (append *leaves* *leaves-with-slots*))
    (destructuring-bind (condition-type initargs) row
      (testing (format nil "~A reports" condition-type)
        (ok (plusp (length (princ-to-string
                            (apply #'make-condition condition-type initargs))))))))
  (testing "the root, with and without a detail"
    (ok (search "a note"
                (princ-to-string (make-condition 'enchiridion.errors:enchiridion-error
                                                 :detail "a note"))))
    (ok (plusp (length (princ-to-string
                       (make-condition 'enchiridion.errors:enchiridion-error)))))))

(deftest a-report-never-calls-a-slot-reader-with-nothing ()
  ;; The leaves above all have an :initform for every slot, so a caller that
  ;; wants the report of a condition it caught still gets one after the values
  ;; have gone out of scope. This is the same property as the test above and it
  ;; is checked separately because it is the one that has actually broken.
  (dolist (row '((enchiridion.errors:backend-error)
                 (enchiridion.errors:transport-error)
                 (enchiridion.errors:unauthorized)))
    (destructuring-bind (condition-type) row
      (testing (format nil "~A needs no arguments" condition-type)
        (ok (plusp (length (princ-to-string (make-condition condition-type)))))))))

(deftest block-overflow-carries-the-shortfall ()
  (let* ((condition (make-condition 'enchiridion.errors:block-overflow
                                    :label :persona
                                    :current 1180
                                    :wanted 1400))
         (report (princ-to-string condition)))
    (testing "the label is in the report"
      ;; Uppercased, because ~A prints a symbol under *print-case*. Looking for
      ;; PERSONA and not persona is not pedantry: it is what the report says.
      (ok (search "PERSONA" report)))
    (testing "the exact numbers are in the report"
      (ok (search "1180" report))
      (ok (search "1400" report)))
    (testing "how much to free is in the report, not left to the caller"
      (ok (search "220" report)))
    (testing "and the report is a sentence, not a stack trace"
      (ok (search "characters" report)))))

(deftest block-overflow-reports-zero-when-it-fits ()
  ;; The overflow condition should never fire when current is under wanted,
  ;; but a caller that constructs one by hand must not be told to free a
  ;; negative number of characters.
  (ok (search "0 must go" (princ-to-string (make-condition 'enchiridion.errors:block-overflow
                                                            :label :world
                                                            :current 100
                                                            :wanted 40)))))

(deftest an-unhandled-enchiridion-error-is-still-an-error ()
  (ok (signals (error 'enchiridion.errors:not-found
                      :kind "skill"
                      :name "missing")
               'enchiridion.errors:enchiridion-error)))

(deftest unauthorized-names-the-channel-when-it-knows ()
  (let ((without (princ-to-string (make-condition 'enchiridion.errors:unauthorized)))
        (with (princ-to-string (make-condition 'enchiridion.errors:unauthorized :channel :fluxer))))
    (ok (plusp (length without)))
    (ok (search "FLUXER" with))))

(deftest condition-report-line-is-one-line ()
  (let ((text (enchiridion.errors:condition-report-line
                (make-condition 'enchiridion.errors:block-overflow
                                :label :operator
                                :current 900
                                :wanted 1000))))
    (ok (search "OPERATOR" text))
    (ng (search (format nil "~%") text) "a report line is a line")))