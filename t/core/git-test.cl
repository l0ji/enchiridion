;;;; git-test.cl --- The nested agent repository.
;;;;
;;;; The agent directory is its own repository, nested inside the checkout.
;;;; The properties that matter are the ones `journey` and `undo` stand on: a
;;;; commit is visible under the hash it returned, a clean tree is not an
;;;; error, a revert restores the text, and a plain directory inside a
;;;; repository is still not a repository of its own.
;;;;
;;;; Every call passes GIT-TEST-ENVIRONMENT, because the build sandbox has no
;;;; global git config: no identity, and no signing key to try.

(defpackage #:enchiridion-git-test
  (:use #:cl)
  (:import-from #:rove #:deftest #:ok #:ng #:testing #:signals)
  (:export #:run))

(in-package #:enchiridion-git-test)

(defun scratch-directory ()
  "Return a fresh directory under the directory this build may write."
  (uiop:ensure-directory-pathname
   (merge-pathnames
    (format nil "enchiridion-git-test-~D/" (random most-positive-fixnum))
    (uiop:ensure-directory-pathname *default-pathname-defaults*))))

(defmacro with-scratch-directory ((directory) &body body)
  "Bind DIRECTORY to a fresh scratch directory, then remove it."
  `(let ((,directory (scratch-directory)))
     (unwind-protect
          (progn ,@body)
       (uiop:delete-directory-tree ,directory
                                   :validate t
                                   :if-does-not-exist :ignore))))

(defun write-text (path text)
  "Write TEXT to PATH, making its directory first."
  (ensure-directories-exist path)
  (with-open-file (stream path :direction :output
                               :if-exists :supersede
                               :if-does-not-exist :create
                               :external-format :utf-8)
    (write-string text stream)))

(defun read-text (path)
  "Return PATH as text."
  (uiop:read-file-string path :external-format :utf-8))

(defun environment ()
  "Return the child environment every commit here uses."
  (enchiridion.git:git-test-environment))

(deftest git-answers ()
  (ok (enchiridion.git:git-available-p)))

(deftest init-creates-a-repository-with-an-ignore-file ()
  (with-scratch-directory (directory)
    (testing "a plain directory is not a repository"
      (ng (enchiridion.git:repository-p directory)))
    (enchiridion.git:git-init directory)
    (testing "and after init it is one, on main"
      (ok (enchiridion.git:repository-p directory))
      (ok (string= "main" (enchiridion.git:git-current-branch directory))))
    (testing "the ignore file holds the runtime names and not the seed files"
      (let ((text (read-text (merge-pathnames ".gitignore" directory))))
        (ok (search "state.json" text))
        (ok (search "memory.db" text))
        (ng (search "SOUL.md" text))))
    (testing "an operator edit to the ignore file survives a second init"
      (let ((path (merge-pathnames ".gitignore" directory)))
        (write-text path "my own rules\n")
        (enchiridion.git:git-init directory)
        (ok (string= "my own rules\n" (read-text path)))))))

(deftest a-commit-is-visible-under-the-hash-it-returned ()
  (with-scratch-directory (directory)
    (enchiridion.git:git-init directory)
    (write-text (merge-pathnames "SOUL.md" directory) "identity\n")
    (let ((hash (enchiridion.git:git-commit-all directory "Add the identity"
                                                :environment (environment))))
      (testing "the hash is a commit and it is HEAD"
        (ok (stringp hash))
        (ok (= 40 (length hash)))
        (ok (string= hash (enchiridion.git:git-head directory
                                                  :environment (environment)))))
      (testing "the log names it newest first"
        (let ((entry (first (enchiridion.git:git-log directory :limit 5))))
          (ok (string= hash (car entry)))
          (ok (string= "Add the identity" (cdr entry)))))
      (testing "nothing to commit is :none and not an error"
        (ok (eq :none (enchiridion.git:git-commit-all directory "again"
                                                      :environment (environment))))))))

(deftest a-plain-directory-inside-a-repository-is-not-one ()
  (with-scratch-directory (directory)
    (enchiridion.git:git-init directory)
    (let ((child (merge-pathnames "children/one/" directory)))
      (ensure-directories-exist child)
      (testing "the nesting rule is what keeps undo out of the harness history"
        (ok (enchiridion.git:repository-p directory))
        (ng (enchiridion.git:repository-p child))
        (ok (null (enchiridion.git:git-commit-all child "no"
                                                  :environment (environment))))))))

(deftest revert-restores-the-text ()
  (with-scratch-directory (directory)
    (enchiridion.git:git-init directory)
    (let ((path (merge-pathnames "WORLD.md" directory)))
      (write-text path "one\n")
      (enchiridion.git:git-commit-all directory "Record one"
                                      :environment (environment))
      (write-text path "two\n")
      (enchiridion.git:git-commit-all directory "Record two"
                                      :environment (environment))
      (enchiridion.git:git-revert directory "HEAD")
      (ok (string= "one\n" (read-text path))))))

(deftest show-and-diff-answer-without-signalling ()
  (with-scratch-directory (directory)
    (enchiridion.git:git-init directory)
    (write-text (merge-pathnames "a.md" directory) "a\n")
    (enchiridion.git:git-commit-all directory "Add a" :environment (environment))
    (ok (search "Add a" (enchiridion.git:git-show directory "HEAD")))
    (write-text (merge-pathnames "a.md" directory) "changed\n")
    (ok (search "changed" (enchiridion.git:git-diff directory)))
    (testing "a revision that does not exist is an empty answer, not a crash"
      (ok (string= "" (enchiridion.git:git-show directory "no-such-revision"))))))

(deftest a-repository-with-no-commits-has-an-empty-log ()
  (with-scratch-directory (directory)
    (enchiridion.git:git-init directory)
    (ok (null (enchiridion.git:git-log directory :limit 5)))
    (ok (null (enchiridion.git:git-head directory :environment (environment))))))
