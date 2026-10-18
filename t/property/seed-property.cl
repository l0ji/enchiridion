;;;; seed-property.cl --- Property tests over the seed templates.
;;;;
;;;; Property 2 of the plan: a block value under its limit survives a write
;;;; and a read with its text intact. The seed files are the first block
;;;; values this system ever holds, so the property is checked on them here,
;;;; where a round trip failure costs one turn instead of a personality.

(defpackage #:enchiridion-seed-property
  (:use #:cl)
  (:import-from #:rove #:deftest #:ok #:ng #:testing)
  (:export #:run))

(in-package #:enchiridion-seed-property)

;; Scratch lives under *DEFAULT-PATHNAME-DEFAULTS*, the current directory, and
;; not under TMPDIR. In a nix build the sandbox mounts /nix/store read only and
;; has no /nix/var/nix/builds, so TMPDIR names a path that cannot be created
;; and every property here fails before it reaches the code under test. The
;; build directory is writable, because that is where the gate already writes
;; its fasl cache.

(defun scratch-base ()
  "Return the directory these tests scribble in, which exists."
  (uiop:ensure-directory-pathname *default-pathname-defaults*))

(defun scratch-path (name)
  "Return a fresh path for NAME under the scratch base. The name is made safe
and a random suffix is added so that two cases never collide."
  (let ((safe (substitute #\- #\/ name)))
    (merge-pathnames (concatenate 'string safe "-"
                                  (format nil "~D" (random most-positive-fixnum))
                                  ".txt")
                     (uiop:ensure-directory-pathname
                      (merge-pathnames "enchiridion-property/" (scratch-base))))))

(defun scratch-root ()
  "Return a directory under the scratch base that exists."
  (uiop:ensure-directory-pathname
   (merge-pathnames "enchiridion-property-agents/" (scratch-base))))

(deftest every-seed-template-survives-a-write-and-read ()
  ;; The row is a name followed by a plist, so it is not destructured into
  ;; four positional values and the contents are fetched by name: :contents
  ;; holds the symbol +GUIDE+, and writing that symbol would put
  ;; ENCHIRIDION.MEMORY::+GUIDE+ into the agent's own file.
  ;;
  ;; The list is bound to a variable first. Written as a bare symbol in
  ;; DOLIST's list position, (dolist (name enchiridion.memory:seed-file-names))
  ;; raises UNBOUND-VARIABLE on this SBCL, while the identical call with one
  ;; more pair of parentheses around it works and FUNCALL works. Binding it
  ;; first says what is meant and does not depend on which of those it is.
  (let ((names (enchiridion.memory:seed-file-names)))
    (dolist (name names)
      (testing name
        (let ((contents (enchiridion.memory:seed-template name))
              (path (scratch-path name)))
          (uiop:delete-file-if-exists path)
          (ok (eq (enchiridion.memory:write-if-absent path contents) :created))
          (ok (equal (uiop:read-file-string path) contents))
          ;; And writing again changes nothing, which is the same invariant
          ;; the template table promises.
          (ok (eq (enchiridion.memory:write-if-absent path "something else") :kept))
          (ok (equal (uiop:read-file-string path) contents))
          (delete-file path))))))

(deftest text-under-the-limit-keeps-its-text ()
  ;; Property 2, applied to the shapes a block can actually hold. A block
  ;; that gains or loses a character on the way to disk is a personality that
  ;; drifts by one character a night.
  (dolist (contents (list ""
                          " "
                          (string #\Newline)
                          "a"
                          (format nil "a~%b")
                          (make-string 100 :initial-element #\x)
                          "SOUL.md with a table, a heading, and ~~strike~~"
                          "unicode: héllo ☃ 🜁"
                          "trailing spaces   "
                          (format nil "tabs~Cand~Cmore" #\Tab #\Tab)))
    (testing (format nil "~S" contents)
      (let ((path (scratch-path "block")))
        (uiop:delete-file-if-exists path)
        (ok (eq (enchiridion.memory:write-if-absent path contents) :created))
        (ok (equal (uiop:read-file-string path) contents))
        (delete-file path)))))

(deftest a-seed-file-is-left-alone-no-matter-how-many-times-init-runs ()
  ;; The invariant the whole bootstrap rests on, stated once more as a
  ;; property rather than as a single example. Every file is seeded with the
  ;; operator's own text first, so what is being tested is init refusing to
  ;; overwrite, not init creating.
  (let ((root (scratch-root)))
    (unwind-protect
         (let ((directory (merge-pathnames "agents/default/" root))
               (names (enchiridion.memory:seed-file-names)))
           (dolist (name names)
             (testing name
               (let ((path (merge-pathnames name directory)))
                 (ensure-directories-exist path)
                 (with-open-file (stream path
                                         :direction :output
                                         :if-exists :supersede
                                         :external-format :utf-8)
                   (write-string "the operator's own text" stream))
                 (dotimes (attempt 3)
                   (enchiridion.memory:init-agent directory))
                 (ok (equal (uiop:read-file-string path) "the operator's own text"))))))
      (uiop:delete-directory-tree root
                                  :validate t
                                  :if-does-not-exist :ignore))))

(deftest bootstrap-completeness-is-exactly-every-step-done ()
  ;; Property 7 of the plan: the bootstrap is complete when every step is
  ;; done, and at no other time. The done set is generated rather than written
  ;; out, because the interesting case is a step missing from the middle, and
  ;; a hand-written fixture almost never has one.
  (let ((root (scratch-root))
        (template (enchiridion.memory:seed-template "BOOTSTRAP.md")))
    (unwind-protect
         (loop repeat 25
               do (let* ((directory (merge-pathnames
                                      (format nil "case-~D/" (random most-positive-fixnum))
                                      root))
                         (boot (merge-pathnames "BOOTSTRAP.md" directory)))
                    (ensure-directories-exist boot)
                    (with-open-file (stream boot
                                            :direction :output
                                            :if-exists :supersede
                                            :if-does-not-exist :create
                                            :external-format :utf-8)
                      (write-string template stream))
                    (let* ((steps (enchiridion.memory:bootstrap-steps directory))
                           (subset (remove-if (lambda (step)
                                                (declare (ignore step))
                                                (zerop (random 2)))
                                              steps)))
                      (dolist (step subset)
                        (enchiridion.memory:mark-bootstrap-step directory (car step)))
                      (testing (format nil "~D of ~D steps done" (length subset) (length steps))
                        (ok (eq (enchiridion.memory:bootstrap-complete-p directory)
                                (= (length subset) (length steps))))))))
      (uiop:delete-directory-tree root
                                  :validate t
                                  :if-does-not-exist :ignore))))