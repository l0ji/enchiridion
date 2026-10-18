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

(declaim (ftype (function (t) list) files-under))

(defun files-under (directory)
  "Return the Lisp files directly in DIRECTORY, sorted by name.

A directory that does not exist has no files, and that is not an error: an
agent that has written no skill yet is a normal agent on its first turn."
  (let ((path (uiop:ensure-directory-pathname directory)))
    (when (probe-file path)
      (sort (remove-if-not
             (lambda (file)
               (let ((name (file-namestring file)))
                 (and (plusp (length name))
                      (not (char= #\. (char name 0)))
                      (equal "cl" (string-downcase (or (pathname-type file) ""))))))
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
;; what arrived.
(defstruct (generation-result (:constructor %make-generation-result))
  (ok-p nil :type boolean)
  (report "" :type string)
  (generation 0 :type integer)
  (loaded '() :type list)
  (manifests '() :type list))

(declaim (ftype function load-generation reload))

(defun load-generation (directory &key (generation nil) (verify t)
                                   (broker nil) (environment nil))
  "Verify and load the next generation of DIRECTORY. Return a
GENERATION-RESULT and never signal for a bad edit.

This is the in-process path: tests use it and a broker child uses it after a
separate verification child said yes. A running supervisor does not call it
with VERIFY T, because the process that holds the secrets must not compile
what the agent wrote.

BROKER and ENVIRONMENT are accepted so a caller can pass its context through;
the socket round trip lives in ENCHIRIDION.TOOLS.BROKER."
  (declare (ignore broker environment))
  (let* ((directory (uiop:ensure-directory-pathname directory))
         (generation (or generation (1+ (current-generation))))
         (sources (agent-source-files directory))
         (result
           (if (null sources)
               (%make-generation-result
                :ok-p t
                :report "no agent files to load"
                :generation (current-generation))
               (let ((ok-p t)
                     (report "not verified"))
                 (when verify
                   (let ((verified (verify-directory directory
                                                     :generation generation)))
                     (setf ok-p (verify-ok-p verified)
                           report (verify-report verified))))
                 (if (not ok-p)
                     (progn
                       (discard-generation generation)
                       (%make-generation-result
                        :ok-p nil
                        :report report
                        :generation (current-generation)))
                     (progn
                       (discard-generation (current-generation))
                       (let* ((manifests (handler-case (plugin-manifests sources)
                                           (error () '())))
                              (loaded (let ((*generation* generation))
                                        (load-agent-code directory
                                                         :generation generation))))
                         (setf *generation* generation)
                         (%make-generation-result
                          :ok-p t
                          :report (format nil "generation ~D loaded, ~D file~:P"
                                          generation (length loaded))
                          :generation generation
                          :loaded loaded
                          :manifests manifests))))))))
    (push result *generation-history*)
    result))

(defun reload (&key directory (verify t) (broker nil) (environment nil))
  "Load the next generation of DIRECTORY, or of the current one."
  (load-generation (or directory (uiop:getcwd))
                   :generation (1+ (current-generation))
                   :verify verify
                   :broker broker
                   :environment environment))
