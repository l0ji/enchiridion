;;;; tiers.cl --- The three loading forms of one body of text.
;;;;
;;;; A block, a skill, or a stored memory is read in three steps: a one
;;;; sentence abstract to decide whether it matters (L0), an overview to plan
;;;; with (L1), and the whole body when it is finally needed (L2). The agent
;;;; starts at L0 and pulls the next tier only after an index read has missed,
;;;; twice, which is the rule that keeps a cold read rare without making a
;;;; needed read impossible.
;;;;
;;;; The derivation here is mechanical on purpose. A cheap model can write a
;;;; better abstract later and pass it in as L0 or L1; what matters now is that
;;;; the same body always yields the same three strings, because a tier that
;;;; changed bytes mid-session would invalidate the prefix cache. This file
;;;; never touches a compiled prompt: it hands text to the reader, and the
;;;; prompt keeps the bytes it was compiled with.

(in-package #:enchiridion.memory)

;;;; Limits and the rule.

(defparameter +l0-chars+ 400
  "About one hundred tokens at the four characters per token the ledger uses.
L0 answers one question: is this worth reading at all.")

(defparameter +l1-chars+ 8000
  "About two thousand tokens. L1 answers what the body is about and what shape
it has, which is what planning needs.")

(defparameter +misses-before-promotion+ 2
  "How many index reads must miss before a tier moves. One miss is a guess
that turned out wrong; two is a pattern, and the pattern is what pays for the
tokens the next tier costs.")

;;;; The value.

;; name is what the three forms belong to, the three text slots are the forms,
;; tier is the form currently in use, and misses counts index reads that came
;; back empty at that tier.
(defstruct (tiered (:constructor %make-tiered))
  (name "" :type string)
  (l0 "" :type string)
  (l1 "" :type string)
  (l2 "" :type string)
  (tier :l0 :type keyword)
  (misses 0 :type (integer 0 *)))

(declaim (ftype (function (tiered) string) tier-name))

(defun tier-name (tiered)
  "Return what TIERED is the three forms of."
  (tiered-name tiered))

(declaim (ftype (function (tiered) (integer 0 *)) tier-misses))

(defun tier-misses (tiered)
  "Return how many index reads have missed TIERED at its current tier."
  (tiered-misses tiered))

;;;; Deriving the shorter forms.

(defun first-paragraph (text)
  "Return TEXT up to its first blank line, or all of TEXT when it has none."
  (let ((end (search (format nil "~%~%") text)))
    (if end (subseq text 0 end) text)))

(defun cut-at-word (text limit)
  "Return TEXT cut to at most LIMIT characters, at a space when it can be.

Cutting at a space rather than at the limit is what keeps the abstract a
sentence instead of half a word, and the hole left by a missing space is one
character wide at worst."
  (if (<= (length text) limit)
      text
      (let ((space (position #\Space text :from-end t :end limit)))
        (subseq text 0 (or space limit)))))

(defun cut-at-line (text limit)
  "Return TEXT cut to at most LIMIT characters, at the last line break before
LIMIT so that the result holds whole lines. A body with no break inside the
limit is cut at the limit, which keeps the result within the budget either
way."
  (if (<= (length text) limit)
      text
      (let ((newline (position #\Newline text :from-end t :end limit)))
        (subseq text 0 (if newline (1+ newline) limit)))))

(defun build-tiers (name l2 &key l1 l0)
  "Return the three forms of L2 as a TIERED value whose current tier is L0.

L1 and L0 are derived from L2 when the caller does not pass them: L1 is L2 up
to the last line break inside +L1-CHARS+, and L0 is L2's first paragraph up to
a word boundary inside +L0-CHARS+. A caller that has a written abstract passes
it as L0 instead, which is how a cheap model's summary replaces the mechanical
one without changing anything else here."
  (check-type name string)
  (check-type l2 string)
  (%make-tiered :name name
                :l2 l2
                :l1 (or l1 (cut-at-line l2 +l1-chars+))
                :l0 (or l0 (cut-at-word (first-paragraph l2) +l0-chars+))
                :tier :l0
                :misses 0))

;;;; Reading and moving.

(declaim (ftype (function (tiered &optional keyword) string) tier-for))

(defun tier-for (tiered &optional (tier (tiered-tier tiered)))
  "Return the text of TIERED at TIER, which defaults to the tier in use.

The argument exists so that a caller can pull one specific tier, and the
default exists so that the common caller never names one at all."
  (ecase tier
    (:l0 (tiered-l0 tiered))
    (:l1 (tiered-l1 tiered))
    (:l2 (tiered-l2 tiered))))

(declaim (ftype (function (tiered) (integer 0 *)) note-tier-miss))

(defun note-tier-miss (tiered)
  "Record one index read that came back empty and return the new count.

Recording a miss does not promote anything. The caller decides when to ask,
and PROMOTE-TIER is the only thing that moves a tier."
  (incf (tiered-misses tiered)))

(declaim (ftype (function (tiered) (integer 0 *)) reset-tier-misses))

(defun reset-tier-misses (tiered)
  "Forget the misses without touching the tier, and return 0.

A caller that learned what it needed from the current tier resets the count,
so that two old misses cannot promote a tier that nothing is missing."
  (setf (tiered-misses tiered) 0))

(declaim (ftype (function (tiered) keyword) promote-tier))

(defun promote-tier (tiered)
  "Move TIERED one tier up and return the tier it is on now.

The move needs +MISSES-BEFORE-PROMOTION+ misses, so one bad guess does not
cost the tokens of a full body. A successful move forgets the count: the two
misses are spent. L2 is the top, and asking at the top clears the count and
returns :L2 rather than signalling, because a caller that reads the whole body
and then asks again has done nothing wrong."
  (let ((tier (tiered-tier tiered)))
    (cond
      ((< (tiered-misses tiered) +misses-before-promotion+)
       tier)
      ((eq tier :l0)
       (setf (tiered-tier tiered) :l1)
       (reset-tier-misses tiered)
       :l1)
      ((eq tier :l1)
       (setf (tiered-tier tiered) :l2)
       (reset-tier-misses tiered)
       :l2)
      (t
       (reset-tier-misses tiered)
       :l2))))
