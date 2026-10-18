;;;; seed-test.cl --- The seed files and the first launch.
;;;;
;;;; The invariant under test is the one the whole bootstrap depends on: a
;;;; seed file is created when absent and never overwritten. If that breaks,
;;;; a rerun of init destroys the operator's work or the agent's personality,
;;;; and nothing else in the system notices.

(defpackage #:enchiridion-seed-test
  (:use #:cl)
  (:import-from #:rove #:deftest #:ok #:ng #:testing #:signals)
  (:export #:run))

(in-package #:enchiridion-seed-test)

(declaim (ftype (function (string) (unsigned-byte 64)) checksum))

(defun checksum (text)
  "Return a number derived from TEXT, so a test can tell one write from
another without holding the whole file in an expectation."
  (let ((total 0))
    (loop for character across text
          for code = (char-code character)
          do (incf total (mod (* total 31) code))
          do (incf total code))
    total))

(defun paren-balance (text)
  "Return how many parentheses TEXT opens that it does not close. Zero means it
balances. Neither example template holds a parenthesis inside a string, so a
plain count is the whole reader."
  (let ((balance 0))
    (loop for character across text
          do (cond ((char= character #\() (incf balance))
                   ((char= character #\)) (decf balance))))
    balance))

(defmacro with-scratch-directory ((name &key (prefix "enchiridion-test-"))
                                  &body body)
  "Bind NAME to a fresh temporary directory, run BODY, then remove it.

Scratch lives under *DEFAULT-PATHNAME-DEFAULTS*, the current directory, and
not under TMPDIR. In a nix build the sandbox mounts /nix/store read only and
has no /nix/var/nix/builds, so TMPDIR names a path that cannot be created and
every directory test fails on 'Can't create directory' before it reaches the
code under test. The build directory is writable, because that is where the
gate already writes its fasl cache.

Three UIOP details, all of which fail loudly rather than quietly.
ENSURE-DIRECTORY-PATHNAME makes a directory pathname; there is no
MAKE-DIRECTORY-PATHNAME. DELETE-DIRECTORY-TREE in ASDF 3.3 takes only &KEY and
demands :VALIDATE T, and signals unless the directory is really there, so
:IF-DOES-NOT-EXIST :IGNORE is what makes the cleanup safe to run twice."
  `(let ((,name (uiop:ensure-directory-pathname
                  (merge-pathnames
                   (format nil "~A~D" ,prefix (random most-positive-fixnum))
                   (uiop:ensure-directory-pathname *default-pathname-defaults*)))))
     (unwind-protect
          (progn ,@body)
       (uiop:delete-directory-tree ,name
                                   :validate t
                                   :if-does-not-exist :ignore))))

(deftest every-template-has-text-and-a-description ()
  (dolist (name (enchiridion.memory:seed-file-names))
    (testing name
      (ok (plusp (length (enchiridion.memory:seed-template name))))
      (ok (plusp (length (enchiridion.memory:seed-description name))))
      (ok (member (enchiridion.memory:seed-kind name) '(:markdown :lisp :json))))))

(deftest the-five-seed-files-are-present ()
  (let ((names (enchiridion.memory:seed-file-names)))
    (dolist (expected '("GUIDE.md" "SOUL.md" "OPERATOR.md" "WORLD.md" "BOOTSTRAP.md"))
      (ok (member expected names :test #'string=)))))

(deftest init-writes-every-file-onto-an-empty-directory ()
  (with-scratch-directory (scratch)
    ;; directory, not scratch: init is given the agent directory and writes
    ;; nothing above it. Probing the scratch root passes because the caller's
    ;; own file is there and looks like a seed file.
    (let* ((directory (merge-pathnames "agents/default/" scratch))
           (result (enchiridion.memory:init-agent directory)))
      (ok (equal (enchiridion.memory:init-created result)
                 (enchiridion.memory:seed-file-names)))
      (ok (null (enchiridion.memory:init-existing result)))
      (ok (null (enchiridion.memory:init-problems result)))
      (testing "every file is on disk after init"
        (dolist (name (enchiridion.memory:seed-file-names))
          (ok (probe-file (merge-pathnames name directory))))))))

(deftest init-never-overwrites ()
  ;; The one that matters. Seed a directory with an operator's edit, rerun
  ;; init, and check the edit survived byte for byte.
  (with-scratch-directory (scratch)
    (let ((soul (merge-pathnames "agents/default/SOUL.md" scratch)))
      (ensure-directories-exist soul)
      (with-open-file (stream soul :direction :output :if-exists :supersede)
        (write-string "the operator's own identity text" stream))
      (let ((before (checksum "the operator's own identity text"))
            (result (enchiridion.memory:init-agent
                     (merge-pathnames "agents/default/" scratch)))
            ;; soul, not scratch: scratch is the directory, and reading a
            ;; directory is an error rather than a short read.
            (after (with-open-file (stream soul :direction :input)
                     (let ((text (make-string (file-length stream))))
                       (read-sequence text stream)
                       text))))
        (ok (member "SOUL.md" (enchiridion.memory:init-existing result) :test #'string=))
        (ng (member "SOUL.md" (enchiridion.memory:init-created result) :test #'string=))
        (ok (= before (checksum after)))
        (ok (equal after "the operator's own identity text"))))))

(deftest init-completes-a-half-finished-setup ()
  ;; Delete one file from a populated directory and rerun. Exactly that one
  ;; comes back, and nothing else is rewritten.
  (with-scratch-directory (scratch)
    (let ((directory (merge-pathnames "agents/default/" scratch)))
      (enchiridion.memory:init-agent directory)
      (let ((world (merge-pathnames "agents/default/WORLD.md" scratch)))
        (with-open-file (stream world :direction :output :if-exists :supersede)
          (write-string "edited world" stream)))
      (delete-file (merge-pathnames "agents/default/OPERATOR.md" scratch))
      (let* ((result (enchiridion.memory:init-agent directory))
             (operator (with-open-file (stream (merge-pathnames
                                                "agents/default/OPERATOR.md" scratch)
                                               :direction :input)
                           (let ((text (make-string (file-length stream))))
                             (read-sequence text stream)
                             text)))
             (world (with-open-file (stream (merge-pathnames
                                            "agents/default/WORLD.md" scratch)
                                           :direction :input)
                       (let ((text (make-string (file-length stream))))
                         (read-sequence text stream)
                         text))))
        (ok (equal (enchiridion.memory:init-created result) '("OPERATOR.md")))
        (ok (= 7 (length (enchiridion.memory:init-existing result))))
        (ok (plusp (length operator)))
        (ok (equal world "edited world"))))))

(deftest write-if-absent-reports-what-it-did ()
  (with-scratch-directory (scratch)
    (let ((path (merge-pathnames "file.md" scratch)))
      (ok (eq (enchiridion.memory:write-if-absent path "one") :created))
      (ok (eq (enchiridion.memory:write-if-absent path "two") :kept))
      (ok (equal "one" (uiop:read-file-string path))))))

(deftest a-populated-directory-is-reported-as-populated ()
  (with-scratch-directory (scratch)
    (let ((directory (merge-pathnames "agents/default/" scratch)))
      (enchiridion.memory:init-agent directory)
      (let ((result (enchiridion.memory:init-agent directory)))
        (ok (enchiridion.memory:init-result-existed-p result))
        (ok (search "already has" (enchiridion.memory:init-status-line result)))))))

(deftest an-empty-directory-is-reported-as-new ()
  (with-scratch-directory (scratch)
    (let ((result (enchiridion.memory:init-agent
                    (merge-pathnames "agents/default/" scratch))))
      ;; ng on its own, and not (ok (ng ...)): rove's NG already records the
      ;; assertion, and wrapping it means OK is asked to judge the marker NG
      ;; returns rather than the value under test.
      (ng (enchiridion.memory:init-result-existed-p result))
      (ok (search "No agent directory found" (enchiridion.memory:init-status-line result))))))

(deftest agent-seeded-p-is-about-one-file-not-eight ()
  ;; A directory with one seed file is a seeded directory. Anything else and
  ;; a half finished setup looks like a first launch.
  (with-scratch-directory (scratch)
    ;; The agent directory is what is asked about, so it is what is written to.
    (let ((directory (merge-pathnames "agents/default/" scratch)))
      (ng (enchiridion.memory:agent-seeded-p directory))
      (ensure-directories-exist (merge-pathnames "SOUL.md" directory))
      (with-open-file (stream (merge-pathnames "SOUL.md" directory)
                              :direction :output :if-exists :supersede)
        (write-string "x" stream))
      (ok (enchiridion.memory:agent-seeded-p directory)))))

(deftest a-directory-that-cannot-be-made-is-a-result ()
  ;; The operator gets the path and the OS error in the problems list, not a
  ;; backtrace from ensure-directories-exist. A regular file standing where a
  ;; parent directory must go is the portable way to make that call fail.
  (with-scratch-directory (scratch)
    (ensure-directories-exist (merge-pathnames "x" scratch))
    (let* ((blocker (merge-pathnames "blocker" scratch))
           (directory (merge-pathnames
                       "child/" (uiop:ensure-directory-pathname blocker))))
      (with-open-file (stream blocker :direction :output
                                      :if-exists :supersede
                                      :if-does-not-exist :create)
        (write-string "not a directory" stream))
      (let ((result (enchiridion.memory:init-agent directory)))
        (ok (null (enchiridion.memory:init-created result)))
        (ok (assoc :directory (enchiridion.memory:init-problems result)))))))

(deftest the-example-skill-and-tool-are-plausible-lisp ()
  ;; Both files ship with the harness and the agent will read them before it
  ;; writes its own, and the tool loader compiles them. A template that does
  ;; not balance would fail on the agent's first attempt at using it, which is
  ;; the worst possible time to find out. Both are plugins now, so each one has
  ;; to carry the extension form and still keep its own package.
  (dolist (entry '("skills/example-welcome.cl" "tools/example-echo.cl"))
    (testing entry
      (let ((text (enchiridion.memory:seed-template entry)))
        (ok (search "defpackage" text))
        (ok (search "in-package" text))
        (ok (search "enchiridion.plugin:define-plugin" text))
        (ok (zerop (paren-balance text)))))))

(deftest the-example-tool-keeps-its-package-and-self-test ()
  (let ((text (enchiridion.memory:seed-template "tools/example-echo.cl")))
    (ok (search "(defpackage #:example-echo" text))
    (ok (search "(defun echo-self-test ()" text))))

(deftest the-guide-describes-the-nested-repository ()
  ;; The agent directory is its own repository inside the checkout, and the
  ;; guide is the operator's only written account of how to read its history.
  (let ((text (enchiridion.memory:seed-template "GUIDE.md")))
    (ok (search "own git repository" text))
    (ok (search "git -C agents/default log" text))))

;;;; Runtime state.

(deftest state-round-trips-through-the-file ()
  (with-scratch-directory (scratch)
    (let ((directory (merge-pathnames "agents/default/" scratch)))
      (enchiridion.memory:init-agent directory)
      (let ((state (enchiridion.memory:read-state directory)))
        (ok (zerop (enchiridion.memory:state-generation state)))
        (ok (= 7 (enchiridion.memory:set-state-generation state 7)))
        (ok (= 7 (enchiridion.memory:state-generation state)))
        (enchiridion.memory:write-state directory state))
      (ok (= 7 (enchiridion.memory:state-generation directory)))
      (ok (= 7 (enchiridion.memory:state-generation (enchiridion.memory:read-state directory)))))))

(deftest write-state-leaves-no-temporary-file-behind ()
  (with-scratch-directory (scratch)
    (let ((directory (merge-pathnames "agents/default/" scratch)))
      (enchiridion.memory:init-agent directory)
      (let ((state (enchiridion.memory:read-state directory)))
        (enchiridion.memory:write-state directory state)
        (enchiridion.memory:write-state directory state))
      (ok (probe-file (merge-pathnames "state.json" directory)))
      (ng (probe-file (merge-pathnames "state.json.new" directory))))))

(deftest a-missing-or-corrupt-state-file-reads-as-defaults ()
  (with-scratch-directory (scratch)
    (let ((directory (merge-pathnames "agents/default/" scratch)))
      (enchiridion.memory:init-agent directory)
      (let ((path (merge-pathnames "state.json" directory)))
        (dolist (contents (list "" "{ this is not json" "[]" "{\"generation\": \"nine\"}"))
          (testing (format nil "~S" contents)
            (with-open-file (stream path :direction :output
                                         :if-exists :supersede
                                         :if-does-not-exist :create
                                         :external-format :utf-8)
              (write-string contents stream))
            (let ((state (enchiridion.memory:read-state directory)))
              (ok (zerop (enchiridion.memory:state-generation state)))
              (ok (zerop (getf (enchiridion.memory:bootstrap-status directory) :step)))
              (ng (getf (enchiridion.memory:bootstrap-status directory) :complete))))))
      (delete-file (merge-pathnames "state.json" directory))
      (ok (zerop (enchiridion.memory:state-generation directory))))))

;;;; Bootstrap.

(deftest bootstrap-status-parses-the-shipped-template-steps ()
  (with-scratch-directory (scratch)
    (let ((directory (merge-pathnames "agents/default/" scratch)))
      (enchiridion.memory:init-agent directory)
      (let ((status (enchiridion.memory:bootstrap-status directory)))
        (ok (plusp (getf status :total)))
        (ok (= (getf status :total) (length (enchiridion.memory:bootstrap-steps directory))))
        (ok (zerop (getf status :step)))
        (ok (null (getf status :done)))
        (ng (getf status :complete))
        (ok (= (getf status :total) (length (getf status :remaining))))
        (ok (= 1 (car (first (getf status :remaining)))))
        (ok (stringp (cdr (first (getf status :remaining)))))
        (ok (search "Bootstrap step 1 of" (enchiridion.memory:bootstrap-status-line directory)))))))

(deftest mark-bootstrap-step-records-and-is-idempotent ()
  (with-scratch-directory (scratch)
    (let ((directory (merge-pathnames "agents/default/" scratch)))
      (enchiridion.memory:init-agent directory)
      (enchiridion.memory:mark-bootstrap-step directory 2)
      (enchiridion.memory:mark-bootstrap-step directory 1)
      (enchiridion.memory:mark-bootstrap-step directory 1)
      (let ((status (enchiridion.memory:bootstrap-status directory)))
        (ok (equal (getf status :done) '(1 2)))
        (ok (= 2 (getf status :step)))
        (ng (getf status :complete))
        (ok (equal (mapcar #'car (getf status :remaining))
                   '(3 4 5 6 7 8)))))))

(deftest marking-every-step-completes-and-archives-the-file ()
  (with-scratch-directory (scratch)
    (let ((directory (merge-pathnames "agents/default/" scratch)))
      (enchiridion.memory:init-agent directory)
      (dolist (step (enchiridion.memory:bootstrap-steps directory))
        (enchiridion.memory:mark-bootstrap-step directory (car step)))
      (ok (enchiridion.memory:bootstrap-complete-p directory))
      (ok (getf (enchiridion.memory:bootstrap-status directory) :complete))
      (ok (probe-file (merge-pathnames "BOOTSTRAP.done.md" directory)))
      (ng (probe-file (merge-pathnames "BOOTSTRAP.md" directory)))
      (ok (search "Bootstrap complete" (enchiridion.memory:bootstrap-status-line directory))))))

(deftest an-absent-bootstrap-file-means-complete ()
  (with-scratch-directory (scratch)
    (let ((directory (merge-pathnames "agents/default/" scratch)))
      (ok (enchiridion.memory:bootstrap-complete-p directory))
      (ng (enchiridion.memory:bootstrap-refuse-writes-p directory)))))

(deftest bootstrap-refuse-writes-p-toggles-at-handover ()
  (with-scratch-directory (scratch)
    (let ((directory (merge-pathnames "agents/default/" scratch)))
      (enchiridion.memory:init-agent directory)
      (ok (enchiridion.memory:bootstrap-refuse-writes-p directory))
      (dolist (step (enchiridion.memory:bootstrap-steps directory))
        (enchiridion.memory:mark-bootstrap-step directory (car step)))
      (ng (enchiridion.memory:bootstrap-refuse-writes-p directory)))))

(deftest blockops-refuses-a-seed-write-before-handover-and-allows-it-after ()
  (with-scratch-directory (scratch)
    (let ((directory (merge-pathnames "agents/default/" scratch)))
      (enchiridion.memory:init-agent directory)
      (ok (signals (enchiridion.tools.builtin:block-ops
                    (list :action "patch" :label "soul" :old "placeholder"
                          :new "mine now" :directory (namestring directory)))
                   'enchiridion.errors:bootstrap-pending))
      (ok (search "placeholder"
                  (uiop:read-file-string (merge-pathnames "SOUL.md" directory))))
      (dolist (step (enchiridion.memory:bootstrap-steps directory))
        (enchiridion.memory:mark-bootstrap-step directory (car step)))
      (enchiridion.tools.builtin:block-ops
       (list :action "patch" :label "soul" :old "placeholder"
             :new "mine now" :directory (namestring directory)))
      (ok (search "mine now" (uiop:read-file-string (merge-pathnames "SOUL.md" directory)))))))

(deftest reset-bootstrap-restores-the-first-steps ()
  (with-scratch-directory (scratch)
    (let ((directory (merge-pathnames "agents/default/" scratch)))
      (enchiridion.memory:init-agent directory)
      (dolist (step (enchiridion.memory:bootstrap-steps directory))
        (enchiridion.memory:mark-bootstrap-step directory (car step)))
      (ok (enchiridion.memory:bootstrap-complete-p directory))
      (enchiridion.memory:reset-bootstrap directory)
      (ok (probe-file (merge-pathnames "BOOTSTRAP.md" directory)))
      (ng (probe-file (merge-pathnames "BOOTSTRAP.done.md" directory)))
      (ng (enchiridion.memory:bootstrap-complete-p directory))
      (ok (enchiridion.memory:bootstrap-refuse-writes-p directory))
      (let ((status (enchiridion.memory:bootstrap-status directory)))
        (ok (zerop (getf status :step)))
        (ok (null (getf status :done)))
        (ok (string= "Bootstrap step 1 of 8: Read `SOUL.md`, `OPERATOR.md`, and `WORLD.md`."
                     (enchiridion.memory:bootstrap-status-line directory)))))))