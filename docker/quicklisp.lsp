;;;; quicklisp.lsp --- Install Quicklisp and pin the distribution.
;;;;
;;;; Usage: sbcl --script docker/quicklisp.lsp BOOTSTRAP PREFIX DIST-VERSION

(require :asdf)

(defparameter *arguments* (uiop:command-line-arguments))

(unless (and (first *arguments*) (second *arguments*) (third *arguments*))
  (error "usage: quicklisp.lsp BOOTSTRAP PREFIX DIST-VERSION"))

(defparameter *prefix* (uiop:ensure-directory-pathname (second *arguments*)))
(defparameter *version* (third *arguments*))

(load (first *arguments*))

(quicklisp-quickstart:install :path *prefix*)

(load (merge-pathnames "setup.lisp" *prefix*))

(ql-dist:install-dist
 (format nil "http://beta.quicklisp.org/dist/quicklisp/~A/distinfo.txt" *version*)
 :prompt nil
 :replace t)

(let ((installed (ql-dist:version (ql-dist:find-dist "quicklisp"))))
  (unless (equal installed *version*)
    (error "the quicklisp dist is ~A, not the pinned ~A" installed *version*))
  (with-open-file (stream (merge-pathnames "pinned-dist.txt" *prefix*)
                          :direction :output
                          :if-exists :supersede)
    (format stream "~A~%" installed)))
