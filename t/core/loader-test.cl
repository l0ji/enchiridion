;;;; loader-test.cl --- Generations, verification, and manifests.
;;;;
;;;; The loader is the one place where agent-written text becomes running code.
;;;; Every test here is about the promise around that: a good generation
;;;; arrives with its tool and its plugin, a bad one changes nothing at all, and
;;;; a discarded generation takes its tools with it. Manifests are read and
;;;; never evaluated, because reading is what lets the supervisor show the
;;;; model a tool it has not compiled.
;;;;
;;;; Scratch lives under *DEFAULT-PATHNAME-DEFAULTS* and not under TMPDIR. A nix
;;;; build sandbox has no writable /tmp, so a test that asks for one there fails
;;;; before it ever reaches the code under test.

(defpackage #:enchiridion-loader-test
  (:use #:cl)
  (:import-from #:rove #:deftest #:ok #:ng #:testing #:signals)
  (:export #:run))

(in-package #:enchiridion-loader-test)

;;;; Scratch directories and the files the tests load.

(defmacro with-scratch-directory ((name) &body body)
  "Bind NAME to a fresh directory under the build directory, run BODY, and
remove the directory afterwards."
  `(let ((,name (uiop:ensure-directory-pathname
                 (merge-pathnames
                  (format nil "enchiridion-loader-test-~D/" (random most-positive-fixnum))
                  (uiop:ensure-directory-pathname *default-pathname-defaults*)))))
     (unwind-protect
          (progn ,@body)
       (uiop:delete-directory-tree ,name :validate t :if-does-not-exist :ignore))))

(declaim (ftype (function (t string string) pathname) write-source))

(defun write-source (directory relative text)
  "Write TEXT to RELATIVE under DIRECTORY and return the pathname."
  (let ((path (merge-pathnames relative (uiop:ensure-directory-pathname directory))))
    (ensure-directories-exist path)
    (with-open-file (stream path
                            :direction :output
                            :if-exists :supersede
                            :if-does-not-exist :create
                            :external-format :utf-8)
      (write-string text stream))
    path))

(declaim (ftype (function (list) null) restore-registry))

(defun restore-registry (tools)
  "Clear the tool registry and put TOOLS back, so that a test cannot leak a tool
into the next one. Every test that registers a tool calls this in an
unwind-protect, which is also what keeps a failed assertion from leaking."
  (enchiridion.tools:clear-registry)
  (dolist (tool tools)
    (enchiridion.tools:register-tool tool))
  nil)

;;;; The plugin files the tests load and read.

(defparameter +good-source+
  "(defpackage #:loader-test-good (:use #:cl))
(in-package #:loader-test-good)

(defun good-run (arguments)
  \"Return the arguments unchanged.\"
  arguments)

(defun good-self-test ()
  \"Return T when the file still does what its description says.\"
  t)

(enchiridion.plugin:define-plugin loader-test-good
  :tool (enchiridion.tools:make-tool
         :name \"loader-test-good\"
         :description \"A good test plugin.\"
         :schema '(:object :properties ((:text :string))))
  :handler #'good-run
  :self-test #'good-self-test)
"
  "A plugin file that compiles, loads, and passes its own self-test.")

(defparameter +last-good-source+
  "(defpackage #:loader-test-last-good (:use #:cl))
(in-package #:loader-test-last-good)

(defun last-good-run (arguments)
  \"Return the arguments unchanged.\"
  arguments)

(defun last-good-self-test ()
  \"Return T when the file still does what its description says.\"
  t)

(enchiridion.plugin:define-plugin loader-test-last-good
  :tool (enchiridion.tools:make-tool
         :name \"loader-test-last-good\"
         :description \"The last good test plugin.\"
         :schema '(:object :properties ((:text :string))))
  :handler #'last-good-run
  :self-test #'last-good-self-test)
"
  "A second good plugin file, so a refused generation has something to keep.")

(defparameter +failing-self-test-source+
  "(defpackage #:loader-test-bad-test (:use #:cl))
(in-package #:loader-test-bad-test)

(defun bad-test-run (arguments)
  \"Return the arguments unchanged.\"
  arguments)

(defun bad-test ()
  \"Return NIL: this file is broken on purpose.\"
  nil)

(enchiridion.plugin:define-plugin loader-test-bad-test
  :tool (enchiridion.tools:make-tool
         :name \"loader-test-bad-test\"
         :description \"A plugin whose self-test fails.\"
         :schema '(:object :properties ((:text :string))))
  :handler #'bad-test-run
  :self-test #'bad-test)
"
  "A plugin file that compiles and loads but whose self-test says no.")

(defparameter +broken-source+
  "(defun broken (
"
  "A file the reader cannot finish, so no compiler ever sees a completed form.")

(defparameter +manifest-source+
  "(in-package #:example-echo)

(defun echo-anything (arguments)
  \"This file is read, never run.\"
  arguments)

(error \"the manifest reader evaluated this file\")

(define-plugin echo
  :tool (tool \"echo\" \"Echo.\" (:object :required (:text) :properties ((:text :string))))
  :handler #'identity
  :self-test #'identity)
"
  "A plugin file whose only purpose is to be read as data. The ERROR form is the
tripwire: a manifest reader that evaluates the file fails on it.")

(defparameter +unreadable-source+
  "(define-plugin unfinished
"
  "A manifest file the reader cannot finish either.")

;;;; The tests.

(deftest define-plugin-registers-a-tool-and-a-plugin ()
  (let ((saved (enchiridion.tools:list-tools))
        (generation (enchiridion.plugin:current-generation)))
    (unwind-protect
         (progn
           (enchiridion.plugin:define-plugin loader-test-direct
             :tool (enchiridion.tools:make-tool
                    :name "loader-test-direct"
                    :description "A plugin defined without a file."
                    :schema '(:object :properties ((:text :string))))
             :handler #'identity
             :self-test #'identity)
           (let ((tool (enchiridion.tools:find-tool "loader-test-direct"))
                 (plugin (find "loader-test-direct"
                               (enchiridion.plugin:plugin-registry)
                               :key #'enchiridion.plugin:plugin-name
                               :test #'equal)))
             (ok (not (null tool)))
             (ok (not (null plugin)))
             (ok (= generation (enchiridion.plugin:current-generation)))
             (ok (= (enchiridion.tools:tool-generation tool)
                    (enchiridion.plugin:plugin-generation plugin)))
             (ok (= (enchiridion.plugin:plugin-generation plugin) generation))))
      (restore-registry saved))))

(deftest manifests-come-from-a-read-file-and-not-an-evaluated-one ()
  (with-scratch-directory (directory)
    (let* ((path (write-source directory "tools/echo.cl" +manifest-source+))
           (manifests (enchiridion.plugin:plugin-manifests (list path))))
      (testing "the file is read as data"
        (ok (= 1 (length manifests)))
        (let ((manifest (first manifests)))
          (ok (equal "echo" (enchiridion.plugin:manifest-name manifest)))
          (ok (equal "Echo." (enchiridion.plugin:manifest-description manifest)))
          (ok (equal '(:object :required (:text) :properties ((:text :string)))
                     (enchiridion.plugin:manifest-schema manifest))))))))

(deftest a-good-generation-registers-its-tool-and-bumps-the-generation ()
  (with-scratch-directory (directory)
    (let ((saved (enchiridion.tools:list-tools))
          (before (enchiridion.plugin:current-generation)))
      (unwind-protect
           (progn
             (write-source directory "tools/good.cl" +good-source+)
             (let ((result (enchiridion.plugin:load-generation directory)))
               (ok (enchiridion.plugin:generation-result-ok-p result))
               (ok (= (1+ before) (enchiridion.plugin:current-generation)))
               (ok (= (enchiridion.plugin:current-generation)
                      (enchiridion.plugin:generation-result-generation result)))
               (ok (not (null (enchiridion.tools:find-tool "loader-test-good"))))
               (ok (member "loader-test-good"
                           (mapcar #'enchiridion.plugin:plugin-name
                                   (enchiridion.plugin:plugin-registry))
                           :test #'equal))))
        (restore-registry saved)))))

(deftest a-file-that-will-not-read-keeps-the-last-generation ()
  (with-scratch-directory (directory)
    (let ((saved (enchiridion.tools:list-tools)))
      (unwind-protect
           (let ((good (merge-pathnames "good/" directory))
                 (broken (merge-pathnames "broken/" directory)))
             (write-source good "tools/last-good.cl" +last-good-source+)
             (ok (enchiridion.plugin:generation-result-ok-p
                  (enchiridion.plugin:load-generation good)))
             (let ((before (enchiridion.plugin:current-generation)))
               (write-source broken "tools/broken.cl" +broken-source+)
               (let ((result (enchiridion.plugin:load-generation broken)))
                 (ng (enchiridion.plugin:generation-result-ok-p result))
                 (ok (= before (enchiridion.plugin:current-generation)))
                 (ok (not (null (enchiridion.tools:find-tool "loader-test-last-good")))))))
        (restore-registry saved)))))

(deftest a-failing-self-test-refuses-the-generation ()
  (with-scratch-directory (directory)
    (let ((saved (enchiridion.tools:list-tools))
          (before (enchiridion.plugin:current-generation)))
      (unwind-protect
           (progn
             (write-source directory "tools/bad-test.cl" +failing-self-test-source+)
             (let ((result (enchiridion.plugin:load-generation directory)))
               (ng (enchiridion.plugin:generation-result-ok-p result))
               (ok (= before (enchiridion.plugin:current-generation)))
               (ng (enchiridion.tools:find-tool "loader-test-bad-test"))))
        (restore-registry saved)))))

(deftest discard-generation-removes-its-tools-and-spares-a-builtin ()
  (let ((saved (enchiridion.tools:list-tools)))
    (unwind-protect
         (progn
           (enchiridion.tools:register-tool
            (enchiridion.tools:make-tool :name "loader-test-builtin"
                                         :description "A frozen builtin."
                                         :schema '(:object :properties ())
                                         :generation 0))
           (enchiridion.tools:register-tool
            (enchiridion.tools:make-tool :name "loader-test-agent"
                                         :description "An agent tool."
                                         :schema '(:object :properties ())
                                         :generation 1))
           (enchiridion.plugin:discard-generation 1)
           (ok (not (null (enchiridion.tools:find-tool "loader-test-builtin"))))
           (ng (enchiridion.tools:find-tool "loader-test-agent")))
      (restore-registry saved))))

(deftest package-name-for-generation-is-stable ()
  (ok (equal "ENCHIRIDION.DYN.7" (enchiridion.plugin:package-name-for-generation 7)))
  (ok (equal (enchiridion.plugin:package-name-for-generation 7)
             (enchiridion.plugin:package-name-for-generation 7))))

(deftest agent-source-files-are-the-skills-then-the-tools ()
  (with-scratch-directory (directory)
    (write-source directory "skills/zeta.cl" "(in-package #:cl-user)\n")
    (write-source directory "skills/alpha.cl" "(in-package #:cl-user)\n")
    (write-source directory "tools/beta.cl" "(in-package #:cl-user)\n")
    (write-source directory "skills/notes.txt" "not lisp\n")
    (write-source directory "tools/README.md" "not lisp\n")
    (ok (equal '("alpha.cl" "zeta.cl" "beta.cl")
               (mapcar #'file-namestring
                       (enchiridion.plugin:agent-source-files directory))))
    (ng (enchiridion.plugin:agent-source-files (merge-pathnames "absent/" directory)))))

(deftest a-manifest-that-will-not-read-is-an-error ()
  (with-scratch-directory (directory)
    (let ((path (write-source directory "tools/unreadable.cl" +unreadable-source+)))
      (ok (signals (enchiridion.plugin:plugin-manifests (list path))
                   'enchiridion.errors:configuration-error)))))
