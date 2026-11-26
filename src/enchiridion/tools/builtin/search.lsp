;;;; search.lsp --- Full-text search over SQLite store (FTS5) and agent text files.

(in-package #:enchiridion.tools.builtin)

(defparameter +search-extensions+ '("md" "txt" "lsp" "lisp" "json" "org")
  "Allowed text file extensions for file search (.env deliberately excluded).")

(defparameter +search-file-limit+ 2000
  "Maximum number of files visited by one file search.")

(defparameter +search-hit-chars+ 400
  "Maximum characters shown per store search hit.")

;;;; Arguments both scopes check the same way.

(defun check-query (query)
  "Return QUERY or signal SCHEMA-ERROR if it is not a non-empty string."
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
        (seen 0)
        ;; Track visited directory truenames to prevent symlink loops.
        (visited (make-hash-table :test #'equal)))
    (labels ((walk (directory)
               (when (and (< seen +search-file-limit+)
                          (not (skipped-directory-p directory))
                          (let ((key (namestring (or (ignore-errors (truename directory))
                                                     directory))))
                            (unless (gethash key visited)
                              (setf (gethash key visited) t))))
                 (dolist (file (uiop:directory-files directory))
                   (when (and (searchable-file-p file) (< seen +search-file-limit+))
                     (incf seen)
                     (push file files)))
                 (dolist (sub (uiop:subdirectories directory))
                   (walk sub)))))
      (if (uiop:directory-exists-p path)
          (walk (uiop:ensure-directory-pathname path))
          (when (searchable-file-p path)
            (incf seen)
            (push path files))))
    (nreverse files)))

(defun search-file (path query limit results)
  "Add matching lines from PATH to RESULTS, up to LIMIT."
  (handler-case
      (let ((text (read-file-bounded path)))
        (loop for line in (split-lines text)
              for number from 1
              when (search query line :test #'char-equal)
                do (push (format nil "~A:~D: ~A" (namestring path) number line) results)
                   (when (>= (length results) limit)
                     (return))))
    (file-error () nil)
    (enchiridion.errors:tool-error () nil))
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
  "Replace newlines, carriage returns, and tabs in TEXT with spaces."
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

(defun search-memory-run (args scope)
  "Search stored sessions and memories for QUERY, returning one line per hit.
Only opens the store if it already exists as a database (never creates one)."
  (let* ((query (check-query (argument args "query")))
         (limit (check-limit (or (argument args "limit") 20)))
         (path (or enchiridion.memory.store:*store-path*
                   (enchiridion.memory.store:default-store-path)))
         (results '()))
    (when (enchiridion.memory.store:store-file-p path)
      (let ((store (enchiridion.memory.store:open-store :path path)))
        (unwind-protect
             (progn
               (unless (string= scope "memories")
                 (dolist (row (enchiridion.memory.store:search-sessions store query :limit limit))
                 (push (hit-line (format nil "[ref episode-~D] session ~A ~A"
                                          (enchiridion.memory.store:turn-row-id row)
                                          (enchiridion.memory.store:turn-row-session row)
                                         (enchiridion.memory.store:turn-row-role row))
                                 (enchiridion.memory.store:turn-row-body row))
                         results)))
               (unless (string= scope "sessions")
                 (dolist (row (enchiridion.memory.store:search-memories store query :limit limit))
                 (push (hit-line (format nil "[ref episode-~D] memory ~A" (getf row :id) (getf row :name))
                                 (getf row :body))
                         results))))
          (enchiridion.memory.store:close-store store))))
    (cap-result
     (if results
         (format nil "~{~A~^~%~}" (nreverse results))
         "no matches"))))

;;;; The tool.

(declaim (ftype (function (t) string) search-run))

(defun search-run (args)
  "Search the store (scope \"memory\", \"sessions\", \"memories\") or files (scope \"files\").
Passing PATH always selects file search regardless of SCOPE."
  (let ((scope (string-downcase (or (argument args "scope") "memory")))
        (path (argument args "path")))
    (cond
      (path (search-files-run args))
      ((string= scope "files") (search-files-run args))
      ((member scope '("memory" "sessions" "memories") :test #'string=)
       (search-memory-run args scope))
      (t (error 'enchiridion.errors:schema-error
                :detail (format nil "Unknown search scope ~A. Use memory, sessions, memories, or files." scope))))))

(defparameter +search-tools+
  (list
   (enchiridion.tools:make-tool
    :name "search"
    :description "Search by scope: memory (sessions and memories, default), sessions, memories, or files. A path selects files."
    :schema '(:object :required (:query)
              :properties ((:query :string) (:scope :string)
                           (:path :string) (:limit :integer)))
    :handler #'search-run)))

(defun register-search-tools ()
  "Register the search tool. Idempotent."
  (dolist (tool +search-tools+)
    (enchiridion.tools:register-tool tool))
  (length +search-tools+))
