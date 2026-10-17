;;;; search.cl --- Search the agent's text files until the FTS5 store arrives.
;;;;
;;;; The plan's store is SQLite FTS5. That store is milestone 4. This search is
;;;; a directory walk over the agent's own files, so the tool exists now and the
;;;; later change replaces one function rather than adding a tool the model has
;;;; already learned to call.

(in-package #:enchiridion.tools.builtin)

(defparameter +search-extensions+ '("md" "txt" "cl" "lisp" "json" "org")
  "File types the search reads. A binary or a secret store is not text to
this tool, and .env is deliberately absent.")

(defparameter +search-file-limit+ 2000
  "The maximum files one search visits. A runaway directory should cost a
bounded walk, not an unbounded turn.")

(defun search-root (args)
  "Return the directory or file SEARCH should visit."
  (let ((path (argument args "path")))
    (cond
      (path (pathname path))
      ((uiop:getenv "ENCHIRIDION_HOME")
       (merge-pathnames "agents/default/"
                        (uiop:ensure-directory-pathname
                         (uiop:getenv "ENCHIRIDION_HOME"))))
      (t (uiop:ensure-directory-pathname *default-pathname-defaults*)))))

(defun searchable-file-p (path)
  "Return T when PATH has one of the text extensions."
  (let ((type (pathname-type path)))
    (and type (member (string-downcase type) +search-extensions+ :test #'string=))))

(defun skipped-directory-p (directory)
  "Return T for a directory that is never searchable."
  (let ((name (car (last (pathname-directory directory)))))
    (and name (member name '(".git" "node_modules" "run" "cache") :test #'string=))))

(defun collect-search-files (path)
  "Return the searchable files under PATH, with a bounded walk."
  (let ((files '())
        (seen 0))
    (labels ((walk (directory)
               (when (and (< seen +search-file-limit+)
                          (not (skipped-directory-p directory)))
                 (dolist (file (uiop:directory-files directory))
                   (when (and (searchable-file-p file) (< seen +search-file-limit+))
                     (incf seen)
                     (push file files)))
                 (dolist (sub (uiop:subdirectories directory))
                   (walk sub)))))
      (if (uiop:directory-exists-p path)
          (walk (uiop:ensure-directory-pathname path))
          (when (searchable-file-p path) (list path))))
    (nreverse files)))

(defun search-file (path query limit results)
  "Add matching lines from PATH to RESULTS, up to LIMIT."
  (handler-case
      (let ((text (uiop:read-file-string path :external-format :utf-8)))
        (loop for line in (split-lines text)
              for number from 1
              when (search query line :test #'char-equal)
                do (push (format nil "~A:~D: ~A" (namestring path) number line) results)
                   (when (>= (length results) limit)
                     (return))))
    (file-error () nil))
  results)

(declaim (ftype (function (t) string) search-run))

(defun search-run (args)
  "Search the agent's text files for QUERY and return PATH:LINE: TEXT lines."
  (let* ((query (argument args "query"))
         (limit (or (argument args "limit") 40))
         (path (search-root args))
         (results '()))
    (unless (and (stringp query) (plusp (length query)))
      (error 'enchiridion.errors:schema-error :detail "query must be a non-empty string."))
    (unless (and (integerp limit) (plusp limit))
      (error 'enchiridion.errors:schema-error :detail "limit must be a positive integer."))
    (dolist (file (collect-search-files path))
      (setf results (search-file file query limit results))
      (when (>= (length results) limit)
        (return)))
    (cap-result
     (if results
         (format nil "~{~A~^~%~}" (nreverse results))
         "no matches"))))

(defparameter +search-tools+
  (list
   (enchiridion.tools:make-tool
    :name "search"
    :description "Search the agent's text files for a literal query."
    :schema '(:object :required (:query)
              :properties ((:query :string) (:path :string) (:limit :integer)))
    :handler #'search-run)))

(defun register-search-tools ()
  "Register the search tool. Idempotent."
  (dolist (tool +search-tools+)
    (enchiridion.tools:register-tool tool))
  (length +search-tools+))
