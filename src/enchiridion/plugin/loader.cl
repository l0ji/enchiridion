;;;; loader.cl --- Generations, the fresh package per generation, and reload.
;;;;
;;;; Agent code is loaded into a package named for its generation, so a rename
;;;; leaves no stale symbol behind: SBCL never uninterns a symbol while its
;;;; package exists, and generation N+1 gets a package of its own.
;;;;
;;;; A generation that fails verification changes nothing. The last good code
;;;; keeps serving, the report goes back to whoever asked, and the cost is one
;;;; turn rather than a dead agent.

(in-package #:enchiridion.plugin)

;; VERIFY-DIRECTORY and PLUGIN-MANIFESTS live in files that load after this
;; one. The declarations are bare FUNCTION and they are the only proclamations
;; for those names anywhere: a bare one and a specific one for the same name
;; disagree, and SBCL turns that disagreement into a fatal warning here.
(declaim (ftype function verify-directory verify-ok-p verify-report
                  plugin-manifests))

(defparameter *generation* 0
  "The agent generation this process loaded. 0 means none: every builtin is
stamped generation 0, so a fresh process holds only builtins.")

(defparameter *plugins* '()
  "Every plugin this process loaded, newest first.")

(defparameter *generation-history* '()
  "Every load attempt this process made, newest first.")

;; name is the string the registry and the status file use, tool is the
;; descriptor the model sees, handler is what runs, self-test is what
;; verification calls, and generation is when it arrived.
(defstruct (plugin (:constructor make-plugin))
  (name "" :type string)
  (tool nil :type t)
  (handler nil :type t)
  (self-test nil :type t)
  (generation 0 :type integer))

(declaim (ftype (function () list) plugin-registry))

(defun plugin-registry ()
  "Return the plugins this process loaded, newest first."
  *plugins*)

(declaim (ftype (function () integer) current-generation))

(defun current-generation ()
  "Return the generation that is loaded, or 0 when only builtins are."
  *generation*)

(declaim (ftype (function () list) generation-history))

(defun generation-history ()
  "Return every load attempt this process made, newest first."
  *generation-history*)

(declaim (ftype (function (integer) string) package-name-for-generation))

(defun package-name-for-generation (generation)
  "Return the package name generation GENERATION loads into."
  (format nil "ENCHIRIDION.DYN.~D" generation))

(declaim (ftype (function (integer) t) ensure-generation-package))

(defun ensure-generation-package (generation)
  "Return the package generation GENERATION loads into, making it when it is
absent. The package uses CL and nothing else, so a file that forgets its
IN-PACKAGE interns into a package of its own generation."
  (let ((name (package-name-for-generation generation)))
    (or (find-package name)
        (make-package name :use (list (find-package :cl))))))

(declaim (ftype (function (t &key (:extensions list)) list) files-under))

(defun files-under (directory &key (extensions '("cl")))
  "Return files with EXTENSIONS directly in DIRECTORY, sorted by name.

A directory that does not exist has no files, and that is not an error: an
agent that has written no skill yet is a normal agent on its first turn."
  (let ((path (uiop:ensure-directory-pathname directory)))
    (when (probe-file path)
      (sort (remove-if-not
             (lambda (file)
               (let ((name (file-namestring file)))
                 (and (plusp (length name))
                      (not (char= #\. (char name 0)))
                      (member (string-downcase (or (pathname-type file) ""))
                              extensions :test #'string=))))
             (uiop:directory-files path))
            #'string< :key #'file-namestring))))

(declaim (ftype (function (t) list) agent-source-files))

(defun agent-source-files (directory)
  "Return the agent's Lisp files: skills first, then tools, each sorted.

The order is the load order, and it is stable, so the same directory always
produces the same generation."
  (let ((root (uiop:ensure-directory-pathname directory)))
    (append (files-under (merge-pathnames "skills/" root))
            (files-under (merge-pathnames "tools/" root)))))

(declaim (ftype (function (t) list) skill-files reference-skill-files))

(defun skill-files (directory)
  "Return the Lisp and markdown files in DIRECTORY's skills directory."
  (files-under (merge-pathnames "skills/"
                                (uiop:ensure-directory-pathname directory))
               :extensions '("cl" "md")))

(defun reference-skill-files (directory)
  "Return DIRECTORY's markdown reference skills, which are never compiled."
  (files-under (merge-pathnames "skills/"
                                (uiop:ensure-directory-pathname directory))
               :extensions '("md")))

(declaim (ftype (function (t) string) read-reference-skill))

(defun read-reference-skill (path)
  "Return the markdown reference skill at PATH as UTF-8 text."
  (unless (string-equal "md" (or (pathname-type (pathname path)) ""))
    (error 'enchiridion.errors:schema-error
           :detail "A reference skill must be a markdown file."))
  (uiop:read-file-string (pathname path) :external-format :utf-8))

;;;; The source snapshot.
;;;;
;;;; The supervisor reads manifests, verifies in a child, and only then asks the
;;;; broker child to load. That is three reads of one directory, seconds apart,
;;;; and a file that changes between them would install a proxy for a handler
;;;; the child never loaded. A snapshot is the digest of every compiled source,
;;;; taken at the first of those reads, carried across the process boundary as
;;;; one string, and checked again before anything becomes visible.

(defparameter +source-file-limit+ (* 1024 1024)
  "The largest agent file a snapshot digests, in bytes. The manifest reader
refuses a file above its own smaller limit, so this bound is for the snapshot
itself: reading a file of any size into memory is the cost this refuses.")

;; directory is the tree the snapshot describes, files is one pair of relative
;; path and hex digest per compiled source in load order, and digest is the one
;; string those pairs produce.
(defstruct (source-snapshot (:constructor %make-source-snapshot))
  (directory nil :type t)
  (files '() :type list)
  (digest "" :type string))

(declaim (ftype (function (t) (vector (unsigned-byte 8))) source-file-octets))

(defun source-file-octets (path)
  "Return PATH as octets, refusing a file above the snapshot limit.
The length is read first and the bytes second, so a file that shrank in between
returns the bytes it actually has and not a buffer of trailing zeroes."
  (with-open-file (stream path :direction :input
                               :element-type '(unsigned-byte 8))
    (let* ((length (file-length stream))
           (buffer (make-array length :element-type '(unsigned-byte 8))))
      (when (> length +source-file-limit+)
        (error 'enchiridion.errors:configuration-error
               :key :plugin
               :detail (format nil "~A is larger than ~D bytes."
                               (file-namestring path) +source-file-limit+)))
      (let ((end (read-sequence buffer stream)))
        (if (= end length) buffer (subseq buffer 0 end))))))

(declaim (ftype (function ((vector (unsigned-byte 8))) string) octets-digest))

(defun octets-digest (octets)
  "Return the SHA-256 of OCTETS as lowercase hex."
  (ironclad:byte-array-to-hex-string (ironclad:digest-sequence :sha256 octets)))

(declaim (ftype (function (t) string) file-digest))

(defun file-digest (path)
  "Return the SHA-256 of the bytes of PATH as lowercase hex."
  (octets-digest (source-file-octets path)))

(declaim (ftype (function (list) string) source-list-digest))

(defun source-list-digest (files)
  "Return the digest of FILES, a list of pairs of relative path and digest.

Each pair is written as one PATH=DIGEST line, so the digest covers which digest
belongs to which name: two trees cannot reach the same digest by swapping two
files, and a renamed file is a different tree."
  (format nil "sha256:~A"
          (octets-digest
           (sb-ext:string-to-octets
            (with-output-to-string (stream)
              (dolist (pair files)
                (format stream "~A=~A~%" (car pair) (cdr pair))))
            :external-format :utf-8))))

(declaim (ftype (function (t) source-snapshot) snapshot-sources))

(defun snapshot-sources (directory)
  "Return the SOURCE-SNAPSHOT of the compiled sources under DIRECTORY.
The file list is the load list in load order, so the snapshot describes exactly
what a generation of DIRECTORY would run."
  (let* ((root (uiop:ensure-directory-pathname directory))
         (files (loop for path in (agent-source-files root)
                      collect (cons (enough-namestring path root)
                                    (file-digest path)))))
    (%make-source-snapshot :directory root
                           :files files
                           :digest (source-list-digest files))))

(declaim (ftype (function (t) t) source-digest-value))

(defun source-digest-value (designator)
  "Return DESIGNATOR as a digest string, or NIL.
DESIGNATOR is a SOURCE-SNAPSHOT, a digest string with or without its sha256
prefix, or NIL for a caller that has no expectation of its own."
  (typecase designator
    (source-snapshot (source-snapshot-digest designator))
    (string
     (let ((text (string-downcase
                  (string-trim '(#\Space #\Tab #\Newline #\Return) designator))))
       (if (and (> (length text) 7) (string= "sha256:" (subseq text 0 7)))
           text
           (concatenate 'string "sha256:" text))))
    (t (if designator
           (error 'enchiridion.errors:configuration-error
                  :key :plugin
                  :detail "A source digest is a snapshot or a digest string.")
           nil))))

(declaim (ftype (function (t t) list) source-changes))

(defun source-changes (before after)
  "Return one line per file that differs between BEFORE and AFTER, sorted."
  (let ((changes '()))
    (dolist (pair (source-snapshot-files before))
      (let ((other (assoc (car pair) (source-snapshot-files after) :test #'string=)))
        (cond ((null other)
               (push (format nil "~A removed" (car pair)) changes))
              ((not (string= (cdr pair) (cdr other)))
               (push (format nil "~A changed" (car pair)) changes)))))
    (dolist (pair (source-snapshot-files after))
      (unless (assoc (car pair) (source-snapshot-files before) :test #'string=)
        (push (format nil "~A added" (car pair)) changes)))
    (sort changes #'string<)))

(declaim (ftype (function (t t) t) source-mismatch))

(defun source-mismatch (expected actual)
  "Return why EXPECTED and ACTUAL disagree, or NIL when they agree.
EXPECTED is a snapshot, a digest string, or NIL for a caller with no
expectation. A snapshot names every file that differs, and a digest string that
crossed a process says only that the source changed, because that is all one
string can say."
  (let ((digest (source-digest-value expected)))
    (when (and digest
               (not (string= digest (source-snapshot-digest actual))))
      (if (source-snapshot-p expected)
          (format nil "the agent source changed since it was read: ~{~A~^, ~}"
                  (source-changes expected actual))
          "the agent source changed since it was verified"))))

(declaim (ftype (function (t) t) record-plugin))

(defun record-plugin (plugin)
  "Add PLUGIN to this generation's registry and return it."
  (push plugin *plugins*)
  plugin)

(declaim (ftype (function (t) t) tool-form-parts))

(defun tool-form-parts (argument)
  "Return three values, the name, the description and the schema ARGUMENT
declares. ARGUMENT is a (TOOL \"name\" \"description\" schema) form, which is
the documented surface, or a plain :NAME/:DESCRIPTION/:SCHEMA property list,
which is what a hand written agent file usually produces."
  (cond
    ((and (consp argument) (keywordp (first argument)))
     (values (getf argument :name) (getf argument :description)
             (getf argument :schema)))
    ((consp argument)
     (values (second argument) (third argument) (fourth argument)))
    (t (values nil nil nil))))

(declaim (ftype (function (t t) t) normalize-plugin-tool))

(defun normalize-plugin-tool (argument name)
  "Return ARGUMENT as a tool struct, or NIL.

The three spellings arrive here and leave as one shape, so neither the
registry nor the manifest reader has to guess which one a file used."
  (cond
    ((null argument) nil)
    ((typep argument 'enchiridion.tools:tool) argument)
    ((consp argument)
     (multiple-value-bind (tool-name description schema) (tool-form-parts argument)
       (enchiridion.tools:make-tool
        :name (string-downcase (string (or tool-name name)))
        :description (if (stringp description) description "")
        :schema (or schema '(:object :properties ())))))
    (t nil)))

(declaim (ftype (function (t) t) register-plugin-tool))

(defun register-plugin-tool (plugin)
  "Put PLUGIN's tool into the tool registry under PLUGIN's generation.

The handler is attached here rather than in the TOOL form, because the two
halves arrive separately and a tool with no handler would be a tool the model
can call and nothing can answer. The tool is normalised first, and the plugin
keeps the normalised struct so a caller that inspects the registry sees the
same object the tool registry holds."
  (let ((tool (normalize-plugin-tool (plugin-tool plugin) (plugin-name plugin))))
    (when tool
      (setf (plugin-tool plugin) tool)
      (setf (enchiridion.tools:tool-generation tool) (plugin-generation plugin))
      (when (plugin-handler plugin)
        (setf (enchiridion.tools:tool-handler tool) (plugin-handler plugin)))
      (enchiridion.tools:register-tool tool)
      tool)))

(defmacro tool (name description schema)
  "Return the tool descriptor a DEFINE-PLUGIN form carries.

The schema is quoted: it is one declaration that drives the model-facing JSON
and the argument validation, and it is kept as a form so a reader can inspect
it without a parse."
  `(enchiridion.tools:make-tool :name ,name
                                :description ,description
                                :schema ',schema))

(defmacro define-plugin (name &key tool handler self-test)
  "Define a plugin: its tool, its handler, and its self-test.

The self-test returns true when the file still does what its description says.
Verification runs it before the generation loads, so a file that broke is
refused while the previous generation keeps serving."
  (let ((instance (gensym "PLUGIN")))
    `(let ((,instance (make-plugin
                       :name ,(string-downcase (string name))
                       :tool ,tool
                       :handler ,handler
                       :self-test ,self-test
                       :generation (current-generation))))
       (register-plugin-tool ,instance)
       (record-plugin ,instance)
       ,instance)))

(declaim (ftype (function (hash-table) hash-table) copy-tool-registry))

(defun copy-tool-registry (registry)
  "Return a shallow copy of REGISTRY for an unpublished generation."
  (let ((copy (make-hash-table :test (hash-table-test registry)
                               :size (hash-table-size registry))))
    (maphash (lambda (name tool) (setf (gethash name copy) tool)) registry)
    copy))

(declaim (ftype (function (integer) integer) discard-generation))

(defun discard-generation (generation)
  "Remove every tool and plugin of GENERATION and return GENERATION.

Only agent generations are touched. A builtin carries generation 0 and the
guard says so, which is what keeps `reload` from unregistering read-file."
  (dolist (name (enchiridion.tools:tool-names))
    (let ((tool (enchiridion.tools:find-tool name)))
      (when (and tool
                 (plusp generation)
                 (= generation (enchiridion.tools:tool-generation tool)))
        (enchiridion.tools:unregister-tool name))))
  (setf *plugins* (remove generation *plugins* :key #'plugin-generation))
  generation)

(defparameter *reload-lock* (bordeaux-threads:make-lock "enchiridion reload")
  "Serializes a reload from its snapshot through its publication.

Two reloads that overlapped would compute the same next generation and publish
the second over the first one's registry, and the loser's tools would be live
under a number the supervisor never recorded. Dispatch does not take this lock:
a tool call reads the registry and never waits on a reload.")

(defmacro with-reload-lock (() &body body)
  "Run BODY holding the reload lock, and release it on any exit."
  `(bordeaux-threads:with-lock-held (*reload-lock*)
     ,@body))

(declaim (ftype (function (t t t) integer) publish-generation))

(defun publish-generation (registry plugins generation)
  "Make REGISTRY, PLUGINS, and GENERATION live, and return GENERATION.

REGISTRY is a complete table that no reader has seen yet, and one setf replaces
the special with that table, so a dispatch sees every tool of the old
generation or every tool of the new one. Nothing here mutates a table a reader
may hold. The three setfs are sequential, so a reader of two of them could see one new
value beside one old one. No reader does that: dispatch reads the registry, the
status reads the generation, and the one place that needs all three is the
reload, which holds the reload lock."
  (setf enchiridion.tools::*registry* registry
        *plugins* plugins
        *generation* generation)
  generation)

(declaim (ftype (function (t &key (:generation t) (:package t)) list)
                load-agent-code))

(defun load-agent-code (directory &key (generation (current-generation)) package)
  "Load every agent file in DIRECTORY into the generation package and return
the loaded pathnames.

*PACKAGE* is bound for the whole load, and *READ-EVAL* is NIL: agent code is
read as data by every path that is not the deliberate one."
  (let* ((package (or package (ensure-generation-package generation)))
         (loaded '()))
    (dolist (path (agent-source-files directory))
      (let ((*package* package)
            (*read-eval* nil))
        (load path :verbose nil :print nil)
        (push path loaded)))
    (nreverse loaded)))

;; ok-p says a generation loaded, report is why it did or did not, generation
;; is the number that is live after the call, loaded and manifests describe
;; what arrived, and digests is the source snapshot the attempt read.
(defstruct (generation-result (:constructor %make-generation-result))
  (ok-p nil :type boolean)
  (report "" :type string)
  (generation 0 :type integer)
  (loaded '() :type list)
  (manifests '() :type list)
  (reference-skills '() :type list)
  (digests nil :type t))

(declaim (ftype (function (string integer t) generation-result)
                refused-generation))

(defun refused-generation (report live snapshot)
  "Return a refused GENERATION-RESULT that leaves the live generation alone."
  (%make-generation-result :ok-p nil
                           :report report
                           :generation live
                           :digests snapshot))

(declaim (ftype (function (t) string) condition-line))

(defun condition-line (condition)
  "Return CONDITION as one line: its report, then its detail when it has one.
A CONFIGURATION-ERROR reports only its key, so a refusal that printed the report
alone would say the plugin configuration is wrong and not which file."
  (let ((detail (and (typep condition 'enchiridion.errors:enchiridion-error)
                     (enchiridion.errors:error-detail condition))))
    (if (stringp detail)
        (format nil "~A ~A" condition detail)
        (princ-to-string condition))))

(declaim (ftype (function (t t t) t) source-change-refusal))

(defun source-change-refusal (snapshot directory live)
  "Return a refusal when DIRECTORY no longer matches SNAPSHOT, or NIL."
  (let ((changes (source-changes snapshot (snapshot-sources directory))))
    (when changes
      (refused-generation
       (format nil "the agent source changed while it loaded: ~{~A~^, ~}" changes)
       live snapshot))))

(declaim (ftype (function (t t t) t) private-generation))

(defun private-generation (directory generation live)
  "Load DIRECTORY into copies of the registry, the plugins, and the counter.
Return three values: the loaded pathnames, the private registry, and the private
plugin list. Nothing here is visible to a reader."
  (let ((enchiridion.tools::*registry*
          (copy-tool-registry (enchiridion.tools:registry)))
        (*plugins* (copy-list *plugins*))
        (*generation* generation))
    (let ((loaded (load-agent-code directory :generation generation)))
      ;; The old generation is discarded only in the private registry, after
      ;; the new code loaded.
      (discard-generation live)
      (values loaded enchiridion.tools::*registry* *plugins*))))

(declaim (ftype (function (t t t t t) generation-result) activate-generation))

(defun activate-generation (directory generation snapshot live manifests)
  "Load GENERATION into private copies, check SNAPSHOT once more, and publish."
  (multiple-value-bind (loaded registry plugins)
      (private-generation directory generation live)
    (let ((refusal (source-change-refusal snapshot directory live)))
      (if refusal
          refusal
          (progn
            (publish-generation registry plugins generation)
            (%make-generation-result
             :ok-p t
             :report (format nil "generation ~D loaded, ~D file~:P"
                             generation (length loaded))
             :generation generation
             :loaded loaded
             :manifests manifests
             :reference-skills (reference-skill-files directory)
             :digests snapshot))))))

(declaim (ftype (function (t t t t t) generation-result)
                load-verified-generation))

(defun load-verified-generation (directory generation verify snapshot live)
  "Verify and activate GENERATION of DIRECTORY, or return a refusal.

SNAPSHOT is checked after verification and again after the load, so a file that
changed while either one ran is refused before anything becomes visible. The new
generation is built in private copies of the registry and the plugin list, so no
reader sees it until PUBLISH-GENERATION."
  (let* ((sources (agent-source-files directory))
         ;; Read every manifest before verification can create a package or
         ;; register even a staged tool.
         (manifests (plugin-manifests sources))
         (verified (and verify (verify-directory directory
                                                 :generation generation
                                                 :source-digests snapshot))))
    (if (and verified (not (verify-ok-p verified)))
        (refused-generation (verify-report verified) live snapshot)
        (let ((refusal (source-change-refusal snapshot directory live)))
          (if refusal
              refusal
              (activate-generation directory generation snapshot live
                                   manifests))))))

(declaim (ftype (function (t t t t) generation-result) attempt-generation))

(defun attempt-generation (directory generation verify source-digests)
  "Load the next generation of DIRECTORY, or return why it was refused.

Every path returns a GENERATION-RESULT, a refusal included, and the caller
records it: a generation that failed verification is part of the record of what
this process was asked to do."
  (let ((live (current-generation))
        (generation (or generation (1+ (current-generation)))))
    (handler-case
        (let* ((directory (uiop:ensure-directory-pathname directory))
               (snapshot (snapshot-sources directory))
               (mismatch (source-mismatch source-digests snapshot)))
          (if mismatch
              (refused-generation mismatch live snapshot)
              (let ((sources (agent-source-files directory)))
                (if (and (null sources) (null (reference-skill-files directory)))
                    ;; An empty directory is a request to unload: the supervisor
                    ;; asked for this number and dropped the old proxies with it,
                    ;; so a child that kept its tools would answer with what the
                    ;; model can no longer see. The private copy is built and
                    ;; published like any other generation, with no manifests.
                    (activate-generation directory generation snapshot live '())
                    (load-verified-generation directory generation verify
                                              snapshot live)))))
      (serious-condition (condition)
        (refused-generation
         (format nil "generation ~D refused: ~A" generation
                 (condition-line condition))
         live nil)))))

(declaim (ftype function load-generation reload))

(defun load-generation (directory &key (generation nil) (verify t)
                                   (broker nil) (environment nil)
                                   (source-digests nil))
  "Verify and load the next generation of DIRECTORY. Return a
GENERATION-RESULT and never signal for a bad edit.

This is the in-process path: tests use it and a broker child uses it after a
separate verification child said yes. A running supervisor does not call it
with VERIFY T, because the process that holds the secrets must not compile
what the agent wrote.

An empty directory publishes an empty generation: the builtins stay and the
tools and plugins of the previous generation go, because a supervisor that asked
for this generation and removed the proxies of the last one must not leave a
child answering with tools the model cannot see.

SOURCE-DIGESTS is the source as its caller read it: a SOURCE-SNAPSHOT, or the
digest string that crossed a process. A tree that no longer matches it is
refused before anything is published, and so is a tree that changes during the
load, because a generation verified from one tree and loaded from another is
the mismatch the snapshot exists to stop.

BROKER and ENVIRONMENT are accepted so a caller can pass its context through;
the socket round trip lives in ENCHIRIDION.TOOLS.BROKER."
  (declare (ignore broker environment))
  (with-reload-lock ()
    (let ((result (attempt-generation directory generation verify source-digests)))
      (push result *generation-history*)
      result)))


(defun reload (&key directory (verify t) (broker nil) (environment nil))
  "Load the next generation of DIRECTORY, or of the current one."
  (load-generation (or directory (uiop:getcwd))
                   :generation (1+ (current-generation))
                   :verify verify
                   :broker broker
                   :environment environment))
