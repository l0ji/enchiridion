;;;; file-test.cl --- File tools, starting with the index.
;;;;
;;;; The index is the first builtin because it is the token win. These tests
;;;; cover the line ranges, the read range, the unique edit, and the cap.

(defpackage #:enchiridion-file-test
  (:use #:cl)
  (:import-from #:rove #:deftest #:ok #:ng #:testing #:signals)
  (:export #:run))

(in-package #:enchiridion-file-test)

(defmacro with-scratch-directory ((name) &body body)
  "Bind NAME to a fresh directory under the current directory, then remove it."
  `(let ((,name (uiop:ensure-directory-pathname
                  (merge-pathnames
                   (format nil "enchiridion-file-test-~D/" (random most-positive-fixnum))
                   (uiop:ensure-directory-pathname *default-pathname-defaults*)))))
     (unwind-protect
          (progn ,@body)
       (uiop:delete-directory-tree ,name :validate t :if-does-not-exist :ignore))))

(defun write-text (path text)
  (ensure-directories-exist path)
  (with-open-file (stream path :direction :output
                               :if-exists :supersede
                               :if-does-not-exist :create
                               :external-format :utf-8)
    (write-string text stream)))

(deftest the-index-reports-forms-and-line-ranges ()
  (with-scratch-directory (scratch)
    (let* ((path (merge-pathnames "sample.cl" scratch))
           (text (format nil "(defun one ()~%  :one)~%~%(defun two ()~%  :two)~%")))
      (write-text path text)
      (let ((forms (enchiridion.tools.builtin:file-index-forms path)))
        (ok (= 2 (length forms)))
        (ok (= 1 (getf (first forms) :start)))
        (ok (search "defun one" (getf (first forms) :form)))
        (ok (search "defun two" (getf (second forms) :form))))
      (let ((index (enchiridion.tools.builtin:file-index path)))
        (ok (search "2 top level forms" index))
        (ok (search "defun one" index))))))

(deftest the-builtins-dispatch-through-the-registry ()
  (enchiridion.tools:clear-registry)
  (enchiridion.tools.builtin:register-builtin-tools)
  (unwind-protect
       (with-scratch-directory (scratch)
         (let* ((path (merge-pathnames "code.cl" scratch))
                (other (merge-pathnames "other.cl" scratch)))
           (write-text path (format nil "(defun one ()~%  :one)~%"))
           (ok (search "defun one"
                       (enchiridion.tools:dispatch "index" (list :path (namestring path)))))
           (ok (search "defun one"
                       (enchiridion.tools:dispatch
                        "read-file" (list :path (namestring path) :from 1 :to 1))))
           (enchiridion.tools:dispatch
            "write-file" (list :path (namestring other) :text "one two three"))
           (ok (string= "one two three" (uiop:read-file-string other)))
           (enchiridion.tools:dispatch
            "edit-file" (list :path (namestring other) :old "two" :new "TWO"))
           (ok (search "one TWO three" (uiop:read-file-string other)))
           (ok (signals (enchiridion.tools:dispatch
                         "edit-file" (list :path (namestring other) :old "not-there" :new "x"))
                        'enchiridion.errors:tool-error))
           (ok (search "other.cl"
                       (enchiridion.tools:dispatch
                        "glob" (list :pattern (namestring (merge-pathnames "*.cl" scratch))))))))
    (enchiridion.tools:clear-registry)))

(deftest a-large-result-is-capped-and-spilled ()
  (with-scratch-directory (scratch)
    (let* ((text (make-string 200 :initial-element #\x))
           (capped (enchiridion.tools.builtin:cap-result
                    text :cap 20 :spill-directory scratch)))
      (ok (search "truncated 180 characters" capped))
      (ok (search "full result at" capped)))))
