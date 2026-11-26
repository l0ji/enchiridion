;;;; tiers.lsp --- Deterministic L0/L1/L2 progressive text tiers.
;;;;
;;;; Entries start at L0 (abstract) and promote to L1 (overview) then L2 (full body)
;;;; after +MISSES-BEFORE-PROMOTION+ index misses.

(in-package #:enchiridion.memory)

;;;; Limits and the rule.

(defparameter +l0-chars+ 400
  "Character budget for L0 abstracts (~100 tokens).")

(defparameter +l1-chars+ 8000
  "Character budget for L1 overviews (~2000 tokens).")

(defparameter +misses-before-promotion+ 2
  "Index misses required before promoting a tiered entry to the next level.")

;;;; The value.

;; Holds L0/L1/L2 forms, current tier, and miss count for one named entry.
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
  "Truncate TEXT to at most LIMIT characters, preferring the last space boundary."
  (if (<= (length text) limit)
      text
      (let ((space (position #\Space text :from-end t :end limit)))
        (subseq text 0 (or space limit)))))

(defun cut-at-line (text limit)
  "Truncate TEXT to at most LIMIT characters, preferring the last newline boundary."
  (if (<= (length text) limit)
      text
      (let ((newline (position #\Newline text :from-end t :end limit)))
        (subseq text 0 (if newline (1+ newline) limit)))))

(defun build-tiers (name l2 &key l1 l0)
  "Build a TIERED entry starting at :L0 from L2, deriving L1 and L0 unless supplied."
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
  "Return the text of TIERED at TIER (defaulting to its current tier)."
  (ecase tier
    (:l0 (tiered-l0 tiered))
    (:l1 (tiered-l1 tiered))
    (:l2 (tiered-l2 tiered))))

(declaim (ftype (function (tiered) (integer 0 *)) note-tier-miss))

(defun note-tier-miss (tiered)
  "Increment and return the miss count for TIERED without promoting it."
  (incf (tiered-misses tiered)))

(declaim (ftype (function (tiered) (integer 0 *)) reset-tier-misses))

(defun reset-tier-misses (tiered)
  "Reset the miss count of TIERED to 0 without changing its tier."
  (setf (tiered-misses tiered) 0))

(declaim (ftype (function (tiered) keyword) promote-tier))

(defun promote-tier (tiered)
  "Promote TIERED one level (:L0 -> :L1 -> :L2) when misses reach +MISSES-BEFORE-PROMOTION+,
resetting misses. At :L2, resets misses and returns :L2."
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
