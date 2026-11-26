;;;; blocks.lsp --- Named memory blocks, character limits, and write-time injection scan.
;;;;
;;;; Writes are scanned for invisible Unicode and prompt-injection patterns before
;;;; updating the backing file atomically.

(in-package #:enchiridion.memory)

;;;; Limits.

;; Limits are configured via *BLOCK-LIMITS* and *UNLISTED-BLOCK-LIMIT* in settings.lsp.

(defparameter +block-label-aliases+ '((:soul . :persona))
  "Alias-to-canonical block label map (e.g. :SOUL -> :PERSONA) used for limit lookups.")

(declaim (ftype (function (t) keyword) canonical-block-label))

(defun canonical-block-label (label)
  "Return the keyword LABEL names, with an alias resolved to its block."
  (let ((label (if (keywordp label)
                   label
                   (intern (string-upcase (string label)) :keyword))))
    (or (cdr (assoc label +block-label-aliases+ :test #'eq)) label)))

(declaim (ftype (function (t) (integer 1 *)) default-block-limit))

(defun default-block-limit (label)
  "Return the configured character limit for LABEL (resolving aliases), or *UNLISTED-BLOCK-LIMIT*."
  (or (getf *block-limits* (canonical-block-label label)) *unlisted-block-limit*))

;;;; The scan.

(declaim (ftype (function (character) boolean) invisible-character-p))

(defun invisible-character-p (character)
  "Return T for zero-width, bidi-override, BOM, or tag code points that hide text from operators."
  (let ((code (char-code character)))
    (or (<= #x200B code #x200F)
        (<= #x202A code #x202E)
        (<= #x2060 code #x2064)
        (<= #x2066 code #x2069)
        (<= #xE0000 code #xE007F)
        (= code #xFEFF)
        (= code #x00AD)
        (= code #x061C)
        (= code #x180E))))

(defparameter +injection-patterns+
  '("ignore\\s+(?:all\\s+)?(?:the\\s+)?(?:previous|prior|above)\\s+instructions"
    "disregard\\s+(?:all\\s+)?(?:the\\s+)?(?:previous|prior|above)\\s+instructions"
    "reveal\\s+(?:your\\s+)?(?:system\\s+)?prompt"
    "print\\s+(?:your\\s+)?(?:system\\s+)?prompt"
    "repeat\\s+(?:your\\s+)?(?:system\\s+)?prompt"
    "you\\s+are\\s+now\\s+(?:a|an|the)\\b"
    "exfiltrate"
    "send\\s+(?:the\\s+)?(?:secret|token|key|password)\\s+to")
  "Regex patterns for prompt-injection or secret-exfiltration text rejected on block writes.")

(defparameter +injection-scanners+
  (mapcar (lambda (pattern)
            (cl-ppcre:create-scanner pattern :case-insensitive-mode t))
          +injection-patterns+)
  "Pre-compiled case-insensitive scanners for +INJECTION-PATTERNS+.")

(declaim (ftype (function (t string) string) scan-block-text))

(defun scan-block-text (label text)
  "Return TEXT if free of invisible Unicode and injection patterns, else signal CONFIGURATION-ERROR."
  (loop for character across text
        when (invisible-character-p character)
          do (error 'enchiridion.errors:configuration-error
                    :key :block
                    :detail (format nil "Block ~A contains invisible Unicode." label)))
  (dolist (scanner +injection-scanners+)
    (when (cl-ppcre:scan scanner text)
      (error 'enchiridion.errors:configuration-error
             :key :block
             :detail (format nil "Block ~A contains a prompt injection or exfiltration pattern."
                             label))))
  text)

;;;; The block.

;; Named memory block with character cap, optional backing file, and writability flag.
(defstruct (block (:constructor %make-block))
  (label :persona :type keyword)
  (text "" :type string)
  (limit *unlisted-block-limit* :type (integer 1 *))
  (file nil :type (or null pathname))
  (writable-p t :type boolean))

(defun make-block (&key label (text "") limit file (writable-p t))
  "Construct a BLOCK for LABEL and TEXT, scanning TEXT and defaulting LIMIT from *BLOCK-LIMITS*."
  (let ((label (if (keywordp label)
                   label
                   (intern (string-upcase (string label)) :keyword))))
    (check-type text string)
    (let ((limit (or limit (default-block-limit label))))
      (check-type limit (integer 1 *))
      (scan-block-text label text)
      (%make-block :label label
                   :text text
                   :limit limit
                   :file (and file (pathname file))
                   :writable-p writable-p))))

(declaim (ftype (function (block) (integer 0 *)) block-bytes))

(defun block-bytes (block)
  "Return the character count of BLOCK."
  (length (block-text block)))

(declaim (ftype (function (block) boolean) block-full-p))

(defun block-full-p (block)
  "Return T when BLOCK has no room left."
  (>= (block-bytes block) (block-limit block)))

(declaim (ftype (function (block) integer) block-slack))

(defun block-slack (block)
  "Return remaining character capacity of BLOCK (negative if loaded over limit)."
  (- (block-limit block) (block-bytes block)))

(defun absolute-block-file (path)
  "Return PATH against the current directory, so a relative block path works."
  (merge-pathnames (pathname path) (uiop:getcwd)))

(defun followed-block-file (path)
  "Resolve a final symlink on PATH relative to the link's directory, or return PATH."
  (let ((target (enchiridion.compat:symlink-target path)))
    (if target
        (merge-pathnames (pathname target)
                         (uiop:pathname-directory-pathname path))
        path)))

(declaim (ftype (function (t string) string) write-block-file))

(defun write-block-file (path text)
  "Atomically replace PATH with TEXT via temp file and rename.
Follows a final symlink, checks writability on existing targets, and preserves file mode."
  (let* ((path (absolute-block-file path))
         (target (followed-block-file path))
         (mode (enchiridion.compat:file-mode target)))
    (when (probe-file target)
      (with-open-file (stream target :direction :output
                                     :if-exists :append
                                     :if-does-not-exist nil)
        (declare (ignorable stream))))
    (ensure-directories-exist target)
    (uiop:with-temporary-file (:stream stream :pathname temporary
                               :directory (uiop:pathname-directory-pathname target)
                               :type "tmp" :external-format :utf-8)
      (write-string text stream)
      (finish-output stream)
      (close stream)
      (when mode
        (enchiridion.compat:set-file-mode temporary mode))
      (uiop:rename-file-overwriting-target temporary target))
    text))

(declaim (ftype (function (block string) string) set-block-text))

(defun set-block-text (block text)
  "Validate, scan, and replace BLOCK's text (writing its backing file first).
Refuses frozen blocks, exact duplicates, and writes exceeding the block limit."
  (check-type text string)
  (unless (block-writable-p block)
    (error 'enchiridion.errors:block-frozen :label (block-label block)))
  (scan-block-text (block-label block) text)
  (when (string= text (block-text block))
    (error 'enchiridion.errors:configuration-error
           :key :block
           :detail (format nil "Block ~A already holds that text." (block-label block))))
  (when (> (length text) (block-limit block))
    (error 'enchiridion.errors:block-overflow
           :label (block-label block)
           :current (block-limit block)
           :wanted (length text)))
  (when (block-file block)
    (write-block-file (block-file block) text))
  (setf (block-text block) text))

;;;; Compilation.

(declaim (ftype (function (list) string) block-summary))

(defun block-summary (blocks)
  "Return one '<label> <used>/<limit>' line per block."
  (with-output-to-string (stream)
    (dolist (block blocks)
      (format stream "~(~A~) ~D/~D~%"
              (block-label block)
              (block-bytes block)
              (block-limit block)))))

(declaim (ftype (function (list) string) compile-blocks))

(defun compile-blocks (blocks)
  "Render BLOCKS deterministically as prompt text for prefix caching."
  (with-output-to-string (stream)
    (format stream "Memory blocks:~%~A" (block-summary blocks))
    (dolist (block blocks)
      (format stream "~%## ~(~A~) (~D/~D characters)~%~A~%"
              (block-label block)
              (block-bytes block)
              (block-limit block)
              (block-text block)))))

(declaim (ftype (function (list) list) block-descriptions))

(defun block-descriptions (blocks)
  "Return a plist per block for a status command or a tool schema."
  (loop for block in blocks
        collect (list :label (block-label block)
                      :characters (block-bytes block)
                      :limit (block-limit block)
                      :slack (block-slack block)
                      :writable-p (block-writable-p block)
                      :file (block-file block))))
