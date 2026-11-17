;;;; loader-test.lsp --- Generations, verification, and manifests.
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

(declaim (ftype (function (list list integer) null) restore-loader-state))

(defun restore-loader-state (tools plugins generation)
  "Restore all mutable loader state after a generation test."
  (restore-registry tools)
  (setf enchiridion.plugin:*generation* generation
        enchiridion.plugin::*plugins* plugins)
  nil)

(defmacro with-loader-state (() &body body)
  "Run BODY and restore tools, plugins, and the current generation."
  (let ((tools (gensym "TOOLS"))
        (plugins (gensym "PLUGINS"))
        (generation (gensym "GENERATION")))
    `(let ((,tools (enchiridion.tools:list-tools))
           (,plugins (copy-list (enchiridion.plugin:plugin-registry)))
           (,generation (enchiridion.plugin:current-generation)))
       (unwind-protect
            (progn ,@body)
         (restore-loader-state ,tools ,plugins ,generation)))))

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

(defparameter +accepted-then-failing-load-source+
  "(defpackage #:loader-test-load-failure (:use #:cl))
(in-package #:loader-test-load-failure)
(defvar *load-count* 0)
(incf *load-count*)
(when (= *load-count* 2)
  (error \"the accepted generation fails on its second load\"))
(enchiridion.plugin:define-plugin loader-test-last-good
  :tool (enchiridion.tools:make-tool
         :name \"loader-test-last-good\"
         :description \"The replacement must not go live.\"
         :schema '(:object :properties ()))
  :handler #'identity
  :self-test #'(lambda () t))
"
  "A clean verification followed by a failure during the real load.")

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

(declaim (ftype (function (string string) string) source-named))

(defun source-named (source name)
  "Return SOURCE with its plugin and package identifiers replaced by NAME."
  (ppcre:regex-replace-all "loader-test-last-good" source name))

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
    (let* ((path (write-source directory "tools/echo.lsp" +manifest-source+))
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
             (write-source directory "tools/good.lsp" +good-source+)
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
             (write-source good "tools/last-good.lsp" +last-good-source+)
             (ok (enchiridion.plugin:generation-result-ok-p
                  (enchiridion.plugin:load-generation good)))
             (let ((before (enchiridion.plugin:current-generation)))
               (write-source broken "tools/broken.lsp" +broken-source+)
               (let ((result (enchiridion.plugin:load-generation broken)))
                 (ng (enchiridion.plugin:generation-result-ok-p result))
                 (ok (= before (enchiridion.plugin:current-generation)))
                 (ok (not (null (enchiridion.tools:find-tool "loader-test-last-good")))))))
        (restore-registry saved)))))

(deftest an-accepted-generation-that-fails-to-load-keeps-last-good ()
  (with-scratch-directory (directory)
    (with-loader-state ()
      (let ((good (merge-pathnames "good/" directory))
            (broken (merge-pathnames "broken/" directory)))
        (write-source good "tools/last-good.lsp"
                      (source-named +last-good-source+ "loader-test-load-refusal"))
        (ok (enchiridion.plugin:generation-result-ok-p
             (enchiridion.plugin:load-generation good)))
        (let ((generation (enchiridion.plugin:current-generation))
              (tool (enchiridion.tools:find-tool "loader-test-load-refusal")))
          (write-source broken "tools/load-failure.lsp"
                        (source-named +accepted-then-failing-load-source+
                                      "loader-test-load-refusal"))
          (let ((result (enchiridion.plugin:load-generation broken)))
            (ng (enchiridion.plugin:generation-result-ok-p result))
            (ok (search "second load"
                        (enchiridion.plugin:generation-result-report result)))
            (ok (= generation (enchiridion.plugin:current-generation)))
            (ok (eq tool (enchiridion.tools:find-tool "loader-test-load-refusal")))))))))

(deftest an-oversized-manifest-keeps-last-good ()
  (with-scratch-directory (directory)
    (with-loader-state ()
      (let ((good (merge-pathnames "good/" directory))
            (oversized (merge-pathnames "oversized/" directory)))
        (write-source good "tools/last-good.lsp"
                      (source-named +last-good-source+ "loader-test-oversized-good"))
        (ok (enchiridion.plugin:generation-result-ok-p
             (enchiridion.plugin:load-generation good)))
        (let ((generation (enchiridion.plugin:current-generation))
              (tool (enchiridion.tools:find-tool "loader-test-oversized-good")))
          (write-source oversized "tools/too-large.lsp"
                        (make-string (1+ enchiridion.plugin::+manifest-file-limit+)
                                     :initial-element #\;))
          (let ((result (enchiridion.plugin:load-generation oversized)))
            (ng (enchiridion.plugin:generation-result-ok-p result))
            (ok (plusp (length (enchiridion.plugin:generation-result-report result))))
            (ok (= generation (enchiridion.plugin:current-generation)))
            (ok (eq tool (enchiridion.tools:find-tool "loader-test-oversized-good")))))))))

(deftest a-failing-self-test-refuses-the-generation ()
  (with-scratch-directory (directory)
    (let ((saved (enchiridion.tools:list-tools))
          (before (enchiridion.plugin:current-generation)))
      (unwind-protect
           (progn
             (write-source directory "tools/bad-test.lsp" +failing-self-test-source+)
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
    (write-source directory "skills/zeta.lsp" "(in-package #:cl-user)\n")
    (write-source directory "skills/alpha.lsp" "(in-package #:cl-user)\n")
    (write-source directory "tools/beta.lsp" "(in-package #:cl-user)\n")
    (write-source directory "skills/notes.txt" "not lisp\n")
    (write-source directory "tools/README.md" "not lisp\n")
    (ok (equal '("alpha.lsp" "zeta.lsp" "beta.lsp")
               (mapcar #'file-namestring
                       (enchiridion.plugin:agent-source-files directory))))
    (ng (enchiridion.plugin:agent-source-files (merge-pathnames "absent/" directory)))))

(deftest a-manifest-that-will-not-read-is-an-error ()
  (with-scratch-directory (directory)
    (let ((path (write-source directory "tools/unreadable.lsp" +unreadable-source+)))
      (ok (signals (enchiridion.plugin:plugin-manifests (list path))
                   'enchiridion.errors:configuration-error)))))

(deftest the-supervisor-refuses-reader-tricks-in-an-agent-file ()
  ;; The supervisor reads these files as root. A circular plist used to hang
  ;; GETF for good, and #S built whatever structure the file named.
  (with-scratch-directory (directory)
    (dolist (text '("(define-plugin loop . #1=(:tool (tool \"x\" \"y\" :string) . #1#))"
                    "(define-plugin made :tool #S(enchiridion.tools::tool))"
                    "(define-plugin big :tool #99999999*1)"))
      (let ((path (write-source directory "tools/tricky.lsp" text)))
        (ok (signals (enchiridion.plugin:plugin-manifests (list path))
                     'enchiridion.errors:configuration-error)
            text)))
    (testing "an ordinary plugin still reads"
      (let ((path (write-source directory "tools/plain.lsp"
                                "(define-plugin plain :tool (tool \"plain\" \"A tool.\" (:object :properties ((:text :string)))))")))
        (ok (string= "plain"
                     (enchiridion.plugin:manifest-name
                      (first (enchiridion.plugin:plugin-manifests (list path))))))))
    (testing "and nothing it named was interned in the plugin package"
      (ok (null (find-symbol "MADE" :enchiridion.plugin))))))

;;;; The source snapshot and the publication point.

(defparameter +target-source+
  "(defpackage #:loader-test-target (:use #:cl))
(in-package #:loader-test-target)

(defun target-run (arguments)
  \"Return the arguments unchanged.\"
  arguments)

(enchiridion.plugin:define-plugin loader-test-target
  :tool (enchiridion.tools:make-tool
         :name \"loader-test-target\"
         :description \"The file the mutator rewrites.\"
         :schema '(:object :properties ()))
  :handler #'target-run
  :self-test #'(lambda () t))
"
  "A plugin the mutator rewrites while the generation around it loads.")

(declaim (ftype (function (pathname) string) mutating-source))

(defun mutating-source (target)
  "Return a plugin file whose load rewrites TARGET, a sibling source.

The rewrite lands in the middle of the same load: skills load before tools, so
the mutator runs first and the file it rewrites is read afterwards. That is the
window the snapshot has to close, and a file that changes before the load starts
would not prove it."
  (format nil
          "(defpackage #:loader-test-mutator (:use #:cl))
(in-package #:loader-test-mutator)

(defun mutate ()
  \"Rewrite a sibling source during the load.\"
  (with-open-file (stream ~S :direction :output :if-exists :supersede
                             :if-does-not-exist :create :external-format :utf-8)
    (write-string \"(defun rewritten () :changed)~%\" stream))
  t)

(enchiridion.plugin:define-plugin loader-test-mutator
  :tool (enchiridion.tools:make-tool
         :name \"loader-test-mutator\"
         :description \"A plugin that changes the tree it loads from.\"
         :schema '(:object :properties ()))
  :handler #'mutate
  :self-test #'(lambda () t))

(mutate)
"
          (namestring target)))

(deftest a-snapshot-covers-the-sources-in-load-order ()
  (with-scratch-directory (directory)
    (write-source directory "tools/beta.lsp" "(in-package #:cl-user)\n")
    (write-source directory "skills/alpha.lsp" "(in-package #:cl-user)\n")
    (let* ((snapshot (enchiridion.plugin:snapshot-sources directory))
           (files (enchiridion.plugin:source-snapshot-files snapshot)))
      (testing "the relative paths are the load order"
        (ok (equal '("skills/alpha.lsp" "tools/beta.lsp") (mapcar #'car files)))
        (ok (every (lambda (pair) (= 64 (length (cdr pair)))) files)))
      (testing "and one string covers the whole list"
        (ok (search "sha256:" (enchiridion.plugin:source-snapshot-digest snapshot)))
        (ok (string= (enchiridion.plugin:source-snapshot-digest snapshot)
                     (enchiridion.plugin:source-snapshot-digest
                      (enchiridion.plugin:snapshot-sources directory)))))
      (testing "a changed file changes the digest and is named"
        (write-source directory "tools/beta.lsp" "(in-package #:cl-user)\n; changed\n")
        (let ((after (enchiridion.plugin:snapshot-sources directory)))
          (ng (string= (enchiridion.plugin:source-snapshot-digest snapshot)
                       (enchiridion.plugin:source-snapshot-digest after)))
          (ok (equal '("tools/beta.lsp changed")
                     (enchiridion.plugin:source-changes snapshot after)))))
      (testing "a renamed file is two changes, not none"
        (let ((before (enchiridion.plugin:snapshot-sources directory)))
          (write-source directory "tools/gamma.lsp" "(in-package #:cl-user)\n")
          (delete-file (merge-pathnames "tools/beta.lsp" directory))
          (ok (equal '("tools/beta.lsp removed" "tools/gamma.lsp added")
                     (enchiridion.plugin:source-changes
                      before (enchiridion.plugin:snapshot-sources directory)))))))))

(deftest a-digest-that-crossed-a-process-is-accepted-when-it-matches ()
  (with-scratch-directory (directory)
    (with-loader-state ()
      (let ((good (merge-pathnames "good/" directory)))
        (write-source good "tools/last-good.lsp"
                      (source-named +last-good-source+ "loader-test-digest"))
        (let* ((snapshot (enchiridion.plugin:snapshot-sources good))
               (wire (enchiridion.plugin:source-snapshot-digest snapshot)))
          (testing "the string alone is enough to pin the source"
            (ok (enchiridion.plugin:generation-result-ok-p
                 (enchiridion.plugin:load-generation good :source-digests wire)))
            (ok (enchiridion.tools:find-tool "loader-test-digest")))
          (testing "and a bare hex digest is the same digest"
            (ok (string= wire
                         (enchiridion.plugin:source-digest-value (subseq wire 7)))))
          (testing "a digest that is neither fails loudly instead of checking nothing"
            (ok (signals (enchiridion.plugin:source-digest-value 42)
                         'enchiridion.errors:configuration-error))))))))

(deftest a-source-changed-after-it-was-read-is-refused ()
  (with-scratch-directory (directory)
    (with-loader-state ()
      (let ((good (merge-pathnames "good/" directory)))
        (write-source good "tools/last-good.lsp"
                      (source-named +last-good-source+ "loader-test-changed"))
        (let ((snapshot (enchiridion.plugin:snapshot-sources good))
              (generation (enchiridion.plugin:current-generation)))
          (write-source good "tools/last-good.lsp"
                        (source-named +last-good-source+ "loader-test-changed-twice"))
          (let ((result (enchiridion.plugin:load-generation
                         good :source-digests snapshot)))
            (ng (enchiridion.plugin:generation-result-ok-p result))
            (ok (search "tools/last-good.lsp changed"
                        (enchiridion.plugin:generation-result-report result)))
            (ok (= generation (enchiridion.plugin:current-generation)))
            (ng (enchiridion.tools:find-tool "loader-test-changed-twice"))
            (ok (enchiridion.plugin:generation-result-digests result))))))))

(deftest a-source-changed-during-the-load-is-refused-before-publication ()
  (with-scratch-directory (directory)
    (with-loader-state ()
      (let* ((target (write-source directory "tools/99-target.lsp" +target-source+))
             (generation (enchiridion.plugin:current-generation)))
        (write-source directory "tools/00-mutator.lsp" (mutating-source target))
        (let* ((snapshot (enchiridion.plugin:snapshot-sources directory))
               (result (enchiridion.plugin:load-generation
                        directory :verify nil :source-digests snapshot)))
          (testing "the load ran and the mutator really did rewrite the file"
            (ok (search "rewritten" (uiop:read-file-string target))))
          (testing "and the generation was refused with the file named"
            (ng (enchiridion.plugin:generation-result-ok-p result))
            (ok (search "tools/99-target.lsp changed"
                        (enchiridion.plugin:generation-result-report result))))
          (testing "so neither plugin is live and the generation stands still"
            (ok (= generation (enchiridion.plugin:current-generation)))
            (ng (enchiridion.tools:find-tool "loader-test-mutator"))
            (ng (enchiridion.tools:find-tool "loader-test-target"))
            (ok (null (find "loader-test-mutator"
                            (enchiridion.plugin:plugin-registry)
                            :key #'enchiridion.plugin:plugin-name
                            :test #'equal)))))))))

(deftest a-source-too-large-to-snapshot-is-refused ()
  (with-scratch-directory (directory)
    (with-loader-state ()
      (write-source directory "tools/huge.lsp"
                    (make-string (1+ enchiridion.plugin::+source-file-limit+)
                                 :initial-element #\;))
      (ok (signals (enchiridion.plugin:snapshot-sources directory)
                   'enchiridion.errors:configuration-error))
      (let ((result (enchiridion.plugin:load-generation directory)))
        (ng (enchiridion.plugin:generation-result-ok-p result))
        (ok (search "larger than"
                    (enchiridion.plugin:generation-result-report result)))))))

(deftest verification-refuses-a-source-that-changed-under-it ()
  (with-scratch-directory (directory)
    (with-loader-state ()
      (write-source directory "tools/last-good.lsp"
                    (source-named +last-good-source+ "loader-test-verify-changed"))
      (let ((snapshot (enchiridion.plugin:snapshot-sources directory))
            (tools (length (enchiridion.tools:list-tools))))
        (write-source directory "tools/last-good.lsp"
                      (source-named +last-good-source+ "loader-test-verify-twice"))
        (let ((result (enchiridion.plugin:verify-directory
                       directory :generation 1 :source-digests snapshot)))
          (ng (enchiridion.plugin:verify-ok-p result))
          (ok (search "changed since it was read"
                      (enchiridion.plugin:verify-report result)))
          (testing "nothing was compiled into the live registry"
            (ok (= tools (length (enchiridion.tools:list-tools))))
            (ng (enchiridion.tools:find-tool "loader-test-verify-twice"))))))))

(deftest every-attempt-is-recorded-including-a-verification-refusal ()
  (with-scratch-directory (directory)
    (with-loader-state ()
      (write-source directory "tools/bad-test.lsp" +failing-self-test-source+)
      (let* ((attempts (length (enchiridion.plugin:generation-history)))
             (result (enchiridion.plugin:load-generation directory))
             (history (enchiridion.plugin:generation-history)))
        (ng (enchiridion.plugin:generation-result-ok-p result))
        (ok (= (1+ attempts) (length history)))
        (ok (eq result (first history)))))))

(deftest a-generation-replaces-the-registry-wholesale ()
  (with-scratch-directory (directory)
    (with-loader-state ()
      (let ((first (merge-pathnames "first/" directory))
            (second (merge-pathnames "second/" directory)))
        (write-source first "tools/replaced.lsp"
                      (source-named +last-good-source+ "loader-test-replaced"))
        (write-source first "tools/only-in-first.lsp"
                      (source-named +last-good-source+ "loader-test-only-in-first"))
        (ok (enchiridion.plugin:generation-result-ok-p
             (enchiridion.plugin:load-generation first :verify nil)))
        (let ((registry (enchiridion.tools:registry))
              (count (hash-table-count (enchiridion.tools:registry)))
              (tool (enchiridion.tools:find-tool "loader-test-replaced")))
          (ok tool)
          (ok (enchiridion.tools:find-tool "loader-test-only-in-first"))
          (write-source second "tools/replaced-again.lsp"
                        (source-named +last-good-source+ "loader-test-replaced"))
          (write-source second "tools/new.lsp"
                        (source-named +last-good-source+ "loader-test-new"))
          (ok (enchiridion.plugin:generation-result-ok-p
               (enchiridion.plugin:load-generation second :verify nil)))
          (testing "the live registry is a new table holding the new generation"
            (ok (not (eq registry (enchiridion.tools:registry))))
            (ok (enchiridion.tools:find-tool "loader-test-replaced"))
            (ok (not (eq tool (enchiridion.tools:find-tool "loader-test-replaced"))))
            (ok (enchiridion.tools:find-tool "loader-test-new"))
            (ng (enchiridion.tools:find-tool "loader-test-only-in-first")))
          (testing "and the table the last generation published is untouched"
            (ok (eq tool (gethash "loader-test-replaced" registry)))
            (ok (= count (hash-table-count registry)))))))))

(deftest a-reader-never-sees-a-partly-published-registry ()
  (with-scratch-directory (directory)
    (with-loader-state ()
      (let ((one (merge-pathnames "one/" directory))
            (two (merge-pathnames "two/" directory)))
        (write-source one "tools/race.lsp"
                      (source-named +last-good-source+ "loader-test-race"))
        (write-source two "tools/race.lsp"
                      (source-named +last-good-source+ "loader-test-race"))
        (ok (enchiridion.plugin:generation-result-ok-p
             (enchiridion.plugin:load-generation one :verify nil)))
        (let ((missed (make-array 8 :initial-element nil))
              (readers '()))
          (dotimes (index 8)
            (let ((slot index))
              (push (bordeaux-threads:make-thread
                     (lambda ()
                       (dotimes (pass 2000)
                         (unless (and (enchiridion.tools:find-tool "loader-test-race")
                                      (member "loader-test-race"
                                              (enchiridion.tools:tool-names)
                                              :test #'string=))
                           (setf (aref missed slot) t)
                           (return)))))
                    readers)))
          (dotimes (round 8)
            (enchiridion.plugin:load-generation (if (evenp round) two one)
                                                :verify nil))
          (mapc #'bordeaux-threads:join-thread readers)
          (ok (notany #'identity missed)))))))

(deftest an-empty-directory-unloads-the-generation-before-it ()
  (with-scratch-directory (directory)
    (with-loader-state ()
      (let ((agent (merge-pathnames "agent/" directory))
            (builtins (hash-table-count (enchiridion.tools:registry))))
        (write-source agent "tools/last-good.lsp"
                      (source-named +last-good-source+ "loader-test-unloaded"))
        (ok (enchiridion.plugin:generation-result-ok-p
             (enchiridion.plugin:load-generation agent :verify nil)))
        (ok (enchiridion.tools:find-tool "loader-test-unloaded"))
        (let ((requested (1+ (enchiridion.plugin:current-generation))))
          (delete-file (merge-pathnames "tools/last-good.lsp" agent))
          (let ((result (enchiridion.plugin:load-generation agent :verify nil)))
            (testing "an empty tree publishes the generation it was asked for"
              (ok (enchiridion.plugin:generation-result-ok-p result))
              (ok (= requested (enchiridion.plugin:generation-result-generation result)))
              (ok (= requested (enchiridion.plugin:current-generation)))
              (ok (search "0 files"
                          (enchiridion.plugin:generation-result-report result))))
            (testing "and the tools and plugins of the old generation go"
              (ng (enchiridion.tools:find-tool "loader-test-unloaded"))
              (ok (null (find "loader-test-unloaded"
                              (enchiridion.plugin:plugin-registry)
                              :key #'enchiridion.plugin:plugin-name
                              :test #'equal)))
              (ok (= builtins (hash-table-count (enchiridion.tools:registry)))))))))))
