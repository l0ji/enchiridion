;;;; prompt-property.cl --- The frozen prompt has to be byte stable.
;;;;
;;;; Property 4 of the plan: compiling the prompt twice from the same blocks
;;;; yields identical bytes. That is the one property that makes the prefix
;;;; cache work. A silent break here costs money on every turn, so it is
;;;; checked over many generated block values rather than one fixture.
;;;;
;;;; A second property covers the freeze itself: a write after compilation
;;;; changes the block and leaves the compiled prompt alone.

(defpackage #:enchiridion-prompt-property
  (:use #:cl)
  (:import-from #:rove #:deftest #:ok #:testing)
  (:export #:run))

(in-package #:enchiridion-prompt-property)

(defparameter +alphabet+
  "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 .,"
  "Characters a generated block can hold. No control characters, no Unicode
surprises, and no phrase that the injection scan would reject.")

(defun random-text (length)
  "Return LENGTH characters from +ALPHABET+, including the empty string."
  (with-output-to-string (stream)
    (loop repeat length
          do (write-char (char +alphabet+ (random (length +alphabet+))) stream))))

(deftest the-same-blocks-compile-to-identical-bytes ()
  (loop repeat 50
        do (let* ((text (random-text (random 300)))
           (blocks (list (enchiridion.memory:make-block
                          :label :persona
                          :text text
                          :limit 1000)
                         (enchiridion.memory:make-block
                          :label :world
                          :text (random-text (random 300))
                          :limit 1000))))
      (let ((one (enchiridion.kernel:compile-prompt blocks))
            (two (enchiridion.kernel:compile-prompt blocks)))
        (ok (string= (enchiridion.kernel:prompt-text one)
                     (enchiridion.kernel:prompt-text two)))
        (ok (= (enchiridion.kernel:prompt-tokens one)
               (enchiridion.kernel:prompt-tokens two)))))))

(deftest a-write-after-compilation-does-not-change-the-snapshot ()
  (let* ((block (enchiridion.memory:make-block
                 :label :persona :text "the first text" :limit 100
                 :writable-p t))
         (agent (enchiridion.kernel:make-agent :blocks (list block)))
         (before (enchiridion.kernel:prompt-text
                  (enchiridion.kernel:agent-snapshot agent))))
    (enchiridion.memory:set-block-text block "the second text")
    (ok (string= "the second text" (enchiridion.memory:block-text block)))
    (ok (string= before
                 (enchiridion.kernel:prompt-text
                  (enchiridion.kernel:agent-snapshot agent))))))
