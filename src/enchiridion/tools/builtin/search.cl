;;;; search.cl --- Full text search over what the agent said and remembered.
;;;;
;;;; The store backs this tool, so it answers from SQLite:
;;;; the raw turns and the raw memories, with FTS5 doing the matching and no
;;;; model call in the path. Nothing is summarised, because a summary costs
;;;; tokens and can be wrong about the one line that mattered.
;;;;
;;;; The directory walk stays as the files scope. A checkout with no store
;;;; yet, and an operator who wants the Markdown, both still get an answer,
;;;; and a PATH argument means files without the caller having to say so.

(in-package #:enchiridion.tools.builtin)

(defparameter +search-extensions+ '("md" "txt" "cl" "lisp" "json" "org")
  "File types the file walk reads. A binary or a secret store is not text to
this tool, and .env is deliberately absent.")

(defparameter +search-file-limit+ 2000
  "The maximum files one search visits. A runaway directory should cost a
bounded walk, not an unbounded turn.")

(defparameter +search-hit-chars+ 400
  "How much of one stored body a hit shows. The whole turn is in the store and
the agent can go and read it; this is a result line, not a transcript.")

;;;; Arguments both scopes check the same way.

(defun check-query (query)
  "Signal a schema error unless QUERY is a string with something in it, and
return it. An empty query matches every line of every file, which is a search
that answered a question nobody asked."
  (unless (and (stringp query) (plusp (length query)))
    (error 'enchiridion.errors:schema-error
           :detail "query must be a non-empty string."))
  query)

(defun check-limit (limit)
  "Signal a schema error unless LIMIT is a positive integer, and return it."
  (unless (and (integerp limit) (plusp limit))
    (error 'enchiridion.errors:schema-error
           :detail "limit must be a positive integer."))
  limit)

;;;; The file walk.

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

(defun search-files-run (args)
  "Search the agent's text files for QUERY and return PATH:LINE: TEXT lines."
  (let* ((query (check-query (argument args "query")))
         (limit (check-limit (or (argument args "limit") 40)))
         (path (search-root args))
         (results '()))
    (dolist (file (collect-search-files path))
      (setf results (search-file file query limit results))
      (when (>= (length results) limit)
        (return)))
    (cap-result
     (if results
         (format nil "~{~A~^~%~}" (nreverse results))
         "no matches"))))

;;;; The store.

(defun one-line (text)
  "Return TEXT with every line break and tab written as a space, so that one
hit is one line of output and a result cannot forge a second line."
  (map 'string (lambda (character)
                 (if (member character '(#\Newline #\Return #\Tab))
                     #\Space
                     character))
       text))

(defun hit-line (prefix text)
  "Return one result line: PREFIX, then TEXT flattened and cut to fit."
  (let ((flat (one-line text)))
    (format nil "~A: ~A~@[ ...~]"
            prefix
            (if (> (length flat) +search-hit-chars+)
                (subseq flat 0 +search-hit-chars+)
                flat)
            (when (> (length flat) +search-hit-chars+) t))))

(defun search-memory-run (args)
  "Search stored sessions and memories for QUERY and return one line per hit.

The store is opened only when the file is already a database. Opening one
creates it, and a search is not a reason to write to disk or to adopt a stray
file as the agent's memory."
  (let* ((query (check-query (argument args "query")))
         (limit (check-limit (or (argument args "limit") 20)))
         (path (or enchiridion.memory.store:*store-path*
                   (enchiridion.memory.store:default-store-path)))
         (results '()))
    (when (enchiridion.memory.store:store-file-p path)
      (let ((store (enchiridion.memory.store:open-store :path path)))
        (unwind-protect
             (progn
               (dolist (row (enchiridion.memory.store:search-sessions store query :limit limit))
                 (push (hit-line (format nil "session ~A ~A"
                                         (enchiridion.memory.store:turn-row-session row)
                                         (enchiridion.memory.store:turn-row-role row))
                                 (enchiridion.memory.store:turn-row-body row))
                       results))
               (dolist (row (enchiridion.memory.store:search-memories store query :limit limit))
                 (push (hit-line (format nil "memory ~A" (getf row :name))
                                 (getf row :body))
                       results)))
          (enchiridion.memory.store:close-store store))))
    (cap-result
     (if results
         (format nil "~{~A~^~%~}" (nreverse results))
         "no matches"))))

;;;; The tool.

(declaim (ftype (function (t) string) search-run))

(defun search-run (args)
  "Search stored sessions and memories, or the agent's files.

SCOPE selects the store, which is \"memory\" and the default, or the directory
walk, which is \"files\". A PATH argument means files whatever the scope says:
a caller that named a directory has already said what it wants walked."
  (let ((scope (string-downcase (or (argument args "scope") "memory")))
        (path (argument args "path")))
    (cond
      (path (search-files-run args))
      ((string= scope "files") (search-files-run args))
      ((string= scope "memory") (search-memory-run args))
      (t (error 'enchiridion.errors:schema-error
                :detail (format nil "Unknown search scope ~A." scope))))))

(defparameter +search-tools+
  (list
   (enchiridion.tools:make-tool
    :name "search"
    :description "Search stored sessions and memories, or the agent's files."
    :schema '(:object :required (:query)
              :properties ((:query :string) (:scope :string)
                           (:path :string) (:limit :integer)))
    :handler #'search-run)))

(defun register-search-tools ()
  "Register the search tool. Idempotent."
  (dolist (tool +search-tools+)
    (enchiridion.tools:register-tool tool))
  (length +search-tools+))
