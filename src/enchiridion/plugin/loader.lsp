;;;; loader.lsp --- Generations, fresh package per generation, and reload.
;;;;
;;;; Each generation loads into ENCHIRIDION.DYN.<N> so renames leave no stale
;;;; symbols. Failed verification leaves the previous generation active.

(in-package #:enchiridion.plugin)

;; Forward declarations for functions defined in later files. Bare FUNCTION
;; avoids SBCL ftype redefinition warnings.
(declaim (ftype function verify-directory verify-ok-p verify-report
                  plugin-manifests))

(defparameter *generation* 0
  "Current loaded agent generation; 0 means builtins only.")

(defparameter *plugins* '()
  "Every plugin this process loaded, newest first.")

(defparameter *generation-history* '()
  "Every load attempt this process made, newest first.")

;; Registered plugin record (name, tool descriptor, handler, self-test, generation).
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
  "Return or create the package for GENERATION (uses CL only)."
  (let ((name (package-name-for-generation generation)))
    (or (find-package name)
        (make-package name :use (list (find-package :cl))))))

(declaim (ftype (function (t &key (:extensions list)) list) files-under))

(defun files-under (directory &key (extensions '("lsp")))
  "Return files with EXTENSIONS directly in DIRECTORY, sorted by name, or NIL
if DIRECTORY does not exist."
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
  "Return agent Lisp files in stable load order: skills/ then tools/, each sorted."
  (let ((root (uiop:ensure-directory-pathname directory)))
    (append (files-under (merge-pathnames "skills/" root))
            (files-under (merge-pathnames "tools/" root)))))

(declaim (ftype (function (t) list) skill-files reference-skill-files))

(defun skill-files (directory)
  "Return the Lisp and markdown files in DIRECTORY's skills directory."
  (files-under (merge-pathnames "skills/"
                                (uiop:ensure-directory-pathname directory))
               :extensions '("lsp" "md")))

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

;;;; Source snapshot: SHA-256 digest over compiled sources in load order,
;;;; checked across manifest read, verification, and load to prevent TOCTOU drift.

(defparameter +source-file-limit+ (* 1024 1024)
  "Maximum agent file size in bytes accepted by snapshot digesting.")

;; Snapshot of compiled sources under DIRECTORY: (relpath . sha256) pairs and combined digest.
(defstruct (source-snapshot (:constructor %make-source-snapshot))
  (directory nil :type t)
  (files '() :type list)
  (digest "" :type string))

(declaim (ftype (function (t) (vector (unsigned-byte 8))) source-file-octets))

(defun source-file-octets (path)
  "Return PATH bytes, rejecting files over +SOURCE-FILE-LIMIT+ and trimming
short reads if the file shrank."
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
  "Return sha256:<hex> over PATH=DIGEST lines for FILES so names and contents
are both bound."
  (format nil "sha256:~A"
          (octets-digest
           (sb-ext:string-to-octets
            (with-output-to-string (stream)
              (dolist (pair files)
                (format stream "~A=~A~%" (car pair) (cdr pair))))
            :external-format :utf-8))))

(declaim (ftype (function (t) source-snapshot) snapshot-sources))

(defun snapshot-sources (directory)
  "Return a SOURCE-SNAPSHOT of compiled sources under DIRECTORY in load order."
  (let* ((root (uiop:ensure-directory-pathname directory))
         (files (loop for path in (agent-source-files root)
                      collect (cons (enough-namestring path root)
                                    (file-digest path)))))
    (%make-source-snapshot :directory root
                           :files files
                           :digest (source-list-digest files))))

(declaim (ftype (function (t) t) source-digest-value))

(defun source-digest-value (designator)
  "Normalize DESIGNATOR (SOURCE-SNAPSHOT, digest string, or NIL) to \"sha256:...\" or NIL."
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
  "Return a mismatch description if EXPECTED and ACTUAL disagree, or NIL.
A SOURCE-SNAPSHOT lists differing files; a digest string reports a generic change."
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
  "Extract (values name description schema) from a (TOOL ...) form or plist."
  (cond
    ((and (consp argument) (keywordp (first argument)))
     (values (getf argument :name) (getf argument :description)
             (getf argument :schema)))
    ((consp argument)
     (values (second argument) (third argument) (fourth argument)))
    (t (values nil nil nil))))

(declaim (ftype (function (t t) t) normalize-plugin-tool))

(defun normalize-plugin-tool (argument name)
  "Normalize ARGUMENT (tool struct, (TOOL ...) form, or plist) to a tool struct or NIL."
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
  "Normalize PLUGIN's tool, attach its handler and generation, and register it."
  (let ((tool (normalize-plugin-tool (plugin-tool plugin) (plugin-name plugin))))
    (when tool
      (setf (plugin-tool plugin) tool)
      (setf (enchiridion.tools:tool-generation tool) (plugin-generation plugin))
      (when (plugin-handler plugin)
        (setf (enchiridion.tools:tool-handler tool) (plugin-handler plugin)))
      (enchiridion.tools:register-tool tool)
      tool)))

(defmacro tool (name description schema)
  "Build a tool descriptor for DEFINE-PLUGIN; SCHEMA is quoted as data."
  `(enchiridion.tools:make-tool :name ,name
                                :description ,description
                                :schema ',schema))

(defmacro define-plugin (name &key tool handler self-test)
  "Define and register a plugin with optional TOOL, HANDLER, and SELF-TEST."
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
  "Unregister tools and plugins for GENERATION (> 0; builtins at 0 are preserved)."
  (dolist (name (enchiridion.tools:tool-names))
    (let ((tool (enchiridion.tools:find-tool name)))
      (when (and tool
                 (plusp generation)
                 (= generation (enchiridion.tools:tool-generation tool)))
        (enchiridion.tools:unregister-tool name))))
  (setf *plugins* (remove generation *plugins* :key #'plugin-generation))
  generation)

(defparameter *reload-lock* (bordeaux-threads:make-lock "enchiridion reload")
  "Serializes reload from snapshot through publication; dispatch reads lock-free.")

(defmacro with-reload-lock (() &body body)
  "Run BODY holding the reload lock, and release it on any exit."
  `(bordeaux-threads:with-lock-held (*reload-lock*)
     ,@body))

(declaim (ftype (function (t t t) integer) publish-generation))

(defun publish-generation (registry plugins generation)
  "Publish pre-built REGISTRY, PLUGINS, and GENERATION as live and return GENERATION.
Callers hold *RELOAD-LOCK*; REGISTRY is replaced atomically without mutating the old table."
  (setf enchiridion.tools::*registry* registry
        *plugins* plugins
        *generation* generation)
  generation)

(declaim (ftype (function (t &key (:generation t) (:package t)) list)
                load-agent-code))

(defun load-agent-code (directory &key (generation (current-generation)) package)
  "Load agent Lisp files in DIRECTORY into GENERATION's package with *READ-EVAL* NIL."
  (let* ((package (or package (ensure-generation-package generation)))
         (loaded '()))
    (dolist (path (agent-source-files directory))
      (let ((*package* package)
            (*read-eval* nil))
        (load path :verbose nil :print nil)
        (push path loaded)))
    (nreverse loaded)))

;; Result of a generation load attempt (success flag, report, live generation, manifests, snapshot).
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
  (enchiridion.log:log-warn :plugin "generation refused (staying on ~D): ~A" live report)
  (%make-generation-result :ok-p nil
                           :report report
                           :generation live
                           :digests snapshot))

(declaim (ftype (function (t) string) condition-line))

(defun condition-line (condition)
  "Format CONDITION as one line, appending ERROR-DETAIL when present."
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
  "Load DIRECTORY into private copies of registry/plugins and discard LIVE in them.
Returns (values loaded-paths private-registry private-plugins)."
  (let ((enchiridion.tools::*registry*
          (copy-tool-registry (enchiridion.tools:registry)))
        (*plugins* (copy-list *plugins*))
        (*generation* generation))
    (let ((loaded (load-agent-code directory :generation generation)))
      ;; Discard LIVE only in the private copy after loading the new code.
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
            (enchiridion.log:log-info :plugin "generation ~D published (~D file~:P)"
                                      generation (length loaded))
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
  "Read manifests, optionally verify, re-check SNAPSHOT, and activate GENERATION."
  (let* ((sources (agent-source-files directory))
         ;; Read manifests before verification can create packages or stage tools.
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
  "Attempt to verify and load GENERATION of DIRECTORY; always returns a GENERATION-RESULT."
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
                    ;; Empty directory unloads prior agent tools while keeping builtins.
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
  "Verify and load the next generation of DIRECTORY, returning a GENERATION-RESULT.
Refuses if SOURCE-DIGESTS mismatches or files change during load. An empty directory
unloads prior agent tools. BROKER and ENVIRONMENT are accepted for caller compatibility."
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
