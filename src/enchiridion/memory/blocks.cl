;;;; blocks.cl --- Memory blocks, their limits, and the write scan.
;;;;
;;;; A block is one named piece of the agent's memory. The first three are
;;;; backed by Markdown files, so personality evolution is a git diff. The
;;;; prompt is a compiled view of the blocks, taken once per session. A write
;;;; updates the block and, when it has a file, the file; it never changes a
;;;; prompt that was already compiled.
;;;;
;;;; Every write is scanned first. Invisible Unicode can hide an instruction
;;;; from the operator while the model still reads it, and a line that tells
;;;; the model to ignore its instructions or to exfiltrate a secret is not
;;;; memory. The scan is deliberately small and readable: a pattern list that
;;;; is easy to audit beats a classifier that cannot explain itself.

(in-package #:enchiridion.memory)

;;;; Limits.

(defparameter *default-block-limits*
  '(:persona 1200 :operator 800 :world 1500 :session 400 :ledger 250)
  "Character limits per block, as the plan fixes them. Raising a limit raises
the fixed token cost of every prompt, which is why they live in one place.")

(declaim (ftype (function (t) (integer 1 *)) default-block-limit))

(defun default-block-limit (label)
  "Return the configured limit for LABEL, or 1200 for a new label."
  (or (getf *default-block-limits* label) 1200))

;;;; The scan.

(declaim (ftype (function (character) boolean) invisible-character-p))

(defun invisible-character-p (character)
  "Return T for a code point that renders as nothing but reaches the model.
Zero width spaces, bidi overrides, the word joiner, the byte order mark, and
the tag characters are the ones that can hide text in a block."
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
  "Text that asks the model to abandon its instructions or to move a secret.
The list is intentionally short: every pattern is a sentence the operator can
read and disagree with, and a false positive is a write that did not happen
rather than a personality that was rewritten.")

(defparameter +injection-scanners+
  (mapcar (lambda (pattern)
            (cl-ppcre:create-scanner pattern :case-insensitive-mode t))
          +injection-patterns+)
  "The compiled form of +INJECTION-PATTERNS+. SCAN does not take a
case-insensitivity argument; CREATE-SCANNER does. Building the scanners once
also keeps the per-write cost to one match attempt per pattern.")

(declaim (ftype (function (t string) string) scan-block-text))

(defun scan-block-text (label text)
  "Return TEXT when it is safe to store, or signal a configuration error.
LABEL names the block in the report. The caller gets the label and the reason,
not a generic validation failure."
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

;; label is a keyword, text is the body, limit is the character cap, file is
;; the Markdown file that backs it or NIL, and writable-p says whether this
;; agent may change it. The primary agent never gets a writable persona.
(defstruct (block (:constructor %make-block))
  (label :persona :type keyword)
  (text "" :type string)
  (limit 1200 :type (integer 1 *))
  (file nil :type (or null pathname))
  (writable-p t :type boolean))

(defun make-block (&key label (text "") limit file (writable-p t))
  "Return a BLOCK named LABEL holding TEXT.

LIMIT defaults from *DEFAULT-BLOCK-LIMITS*. FILE is the Markdown file the
block reads from and writes to, or NIL for a block that has no file yet. The
text is scanned here, so no constructor can build a block that was never
checked."
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
  "Return the character count of BLOCK. The name follows the plan's accessor;
the unit is characters, which is what the limits count."
  (length (block-text block)))

(declaim (ftype (function (block) boolean) block-full-p))

(defun block-full-p (block)
  "Return T when BLOCK has no room left."
  (>= (block-bytes block) (block-limit block)))

(declaim (ftype (function (block) integer) block-slack))

(defun block-slack (block)
  "Return the characters BLOCK can still take. Negative only when a file was
loaded over its limit, which set-block-text never allows."
  (- (block-limit block) (block-bytes block)))

(declaim (ftype (function (block string) string) set-block-text))

(defun set-block-text (block text)
  "Replace BLOCK's text with TEXT after the scan and the limit check.

An exact duplicate is refused: a write that changes nothing is a turn spent
for no memory. A write over the limit signals BLOCK-OVERFLOW with the limit as
CURRENT and the attempted length as WANTED, so the report names the exact
number of characters to free. The file is written last, and only if the block
has one."
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
  (setf (block-text block) text)
  (when (block-file block)
    (ensure-directories-exist (block-file block))
    (with-open-file (stream (block-file block)
                            :direction :output
                            :if-exists :supersede
                            :if-does-not-exist :create
                            :external-format :utf-8)
      (write-string text stream)))
  text)

;;;; Compilation.

(declaim (ftype (function (list) string) block-summary))

(defun block-summary (blocks)
  "Return one line per block with its character count and limit. This is the
capacity line the plan puts in the prompt, so the agent knows before it writes."
  (with-output-to-string (stream)
    (dolist (block blocks)
      (format stream "~(~A~) ~D/~D~%"
              (block-label block)
              (block-bytes block)
              (block-limit block)))))

(declaim (ftype (function (list) string) compile-blocks))

(defun compile-blocks (blocks)
  "Return BLOCKS as prompt text. The output depends on the block list and its
text only, never on the time or on a hash table order: compiling the same
blocks twice must yield identical bytes for the prefix cache."
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
