;;;; tiers-test.cl --- L0, L1, L2, and the two miss rule.
;;;;
;;;; Two things matter here. The three forms must be a pure function of the
;;;; body, or the same blocks cannot compile to the same bytes twice. And a
;;;; promotion must never reach a compiled prompt, because a tier that changed
;;;; mid-session would invalidate the prefix cache and every cached token.

(defpackage #:enchiridion-tiers-test
  (:use #:cl)
  (:import-from #:rove #:deftest #:ok #:ng #:testing)
  (:export #:run))

(in-package #:enchiridion-tiers-test)

(defun many-lines (count)
  "Return COUNT numbered lines, long enough that the L1 cut has to happen."
  (with-output-to-string (stream)
    (loop for number from 1 to count
          do (format stream "line ~D of a body that keeps going~%" number))))

(deftest a-tiered-body-starts-at-l0 ()
  (let* ((body (format nil "First line of the abstract.~%~%Second paragraph.~%"))
         (tiers (enchiridion.memory:build-tiers "soul" body)))
    (ok (string= "soul" (enchiridion.memory:tier-name tiers)))
    (ok (string= body (enchiridion.memory:tiered-l2 tiers)))
    (testing "a body short enough is its own L1"
      (ok (string= body (enchiridion.memory:tiered-l1 tiers))))
    (testing "L0 is the first paragraph"
      (ok (string= "First line of the abstract."
                   (enchiridion.memory:tiered-l0 tiers))))
    (testing "and the tier in use reads as L0"
      (ok (string= (enchiridion.memory:tiered-l0 tiers)
                   (enchiridion.memory:tier-for tiers))))
    (testing "a tier can be pulled by name"
      (ok (string= body (enchiridion.memory:tier-for tiers :l2))))
    (testing "and it starts with no misses"
      (ok (zerop (enchiridion.memory:tier-misses tiers))))))

(deftest a-long-body-is-cut-at-a-line-and-at-a-word ()
  (let* ((body (many-lines 3000))
         (tiers (enchiridion.memory:build-tiers "world" body)))
    (testing "L1 is smaller than the body and inside its budget"
      (ok (< (length (enchiridion.memory:tiered-l1 tiers)) (length body)))
      (ok (<= (length (enchiridion.memory:tiered-l1 tiers)) 8000)))
    (testing "the cut keeps whole lines, so the last character is a break"
      (let ((l1 (enchiridion.memory:tiered-l1 tiers)))
        (ok (char= #\Newline (char l1 (1- (length l1)))))))
    (testing "L0 is short and is a prefix of L1"
      (ok (<= (length (enchiridion.memory:tiered-l0 tiers)) 400))
      (ok (eql 0 (search (enchiridion.memory:tiered-l0 tiers)
                         (enchiridion.memory:tiered-l1 tiers)))))))

(deftest a-written-abstract-replaces-the-derived-one ()
  (let ((tiers (enchiridion.memory:build-tiers "soul" "the whole body"
                                               :l0 "a written abstract"
                                               :l1 "a written overview")))
    (ok (string= "a written abstract" (enchiridion.memory:tiered-l0 tiers)))
    (ok (string= "a written overview" (enchiridion.memory:tiered-l1 tiers)))
    (ok (string= "the whole body" (enchiridion.memory:tiered-l2 tiers)))))

(deftest building-the-same-body-twice-is-byte-identical ()
  (let* ((body (many-lines 200))
         (one (enchiridion.memory:build-tiers "world" body))
         (two (enchiridion.memory:build-tiers "world" body)))
    (ok (string= (enchiridion.memory:tiered-l0 one)
                 (enchiridion.memory:tiered-l0 two)))
    (ok (string= (enchiridion.memory:tiered-l1 one)
                 (enchiridion.memory:tiered-l1 two)))))

(deftest a-tier-promotes-only-after-two-misses ()
  (let ((tiers (enchiridion.memory:build-tiers "soul" "the whole body of the block")))
    (testing "the first miss changes nothing"
      (ok (= 1 (enchiridion.memory:note-tier-miss tiers)))
      (ok (eq :l0 (enchiridion.memory:promote-tier tiers)))
      (ok (string= (enchiridion.memory:tiered-l0 tiers)
                   (enchiridion.memory:tier-for tiers))))
    (testing "the second miss moves it to L1 and spends the count"
      (enchiridion.memory:note-tier-miss tiers)
      (ok (eq :l1 (enchiridion.memory:promote-tier tiers)))
      (ok (zerop (enchiridion.memory:tier-misses tiers)))
      (ok (string= (enchiridion.memory:tiered-l1 tiers)
                   (enchiridion.memory:tier-for tiers))))
    (testing "one more miss is not enough from L1"
      (enchiridion.memory:note-tier-miss tiers)
      (ok (eq :l1 (enchiridion.memory:promote-tier tiers))))
    (testing "and the second moves it to the whole body"
      (enchiridion.memory:note-tier-miss tiers)
      (ok (eq :l2 (enchiridion.memory:promote-tier tiers)))
      (ok (string= "the whole body of the block"
                   (enchiridion.memory:tier-for tiers))))))

(deftest the-top-tier-does-not-climb ()
  (let ((tiers (enchiridion.memory:build-tiers "world" "body")))
    (flet ((climb ()
             (enchiridion.memory:note-tier-miss tiers)
             (enchiridion.memory:note-tier-miss tiers)
             (enchiridion.memory:promote-tier tiers)))
      (climb)
      (climb))
    (ok (eq :l2 (enchiridion.memory:promote-tier tiers)))
    (testing "asking at the top with misses only clears the count"
      (enchiridion.memory:note-tier-miss tiers)
      (enchiridion.memory:note-tier-miss tiers)
      (ok (eq :l2 (enchiridion.memory:promote-tier tiers)))
      (ok (zerop (enchiridion.memory:tier-misses tiers))))))

(deftest misses-can-be-forgotten-without-a-promotion ()
  (let ((tiers (enchiridion.memory:build-tiers "world" "body")))
    (enchiridion.memory:note-tier-miss tiers)
    (ok (zerop (enchiridion.memory:reset-tier-misses tiers)))
    (ok (zerop (enchiridion.memory:tier-misses tiers)))
    (testing "an old miss cannot promote anything on its own"
      (enchiridion.memory:note-tier-miss tiers)
      (ok (eq :l0 (enchiridion.memory:promote-tier tiers))))))

(deftest promotion-never-changes-a-compiled-prompt ()
  (let* ((text "the body of the world block, with words in it")
         (blocks (list (enchiridion.memory:make-block :label :world :text text)))
         (tiers (enchiridion.memory:build-tiers "world" text))
         (before (enchiridion.kernel:prompt-text
                  (enchiridion.kernel:compile-prompt blocks))))
    (enchiridion.memory:note-tier-miss tiers)
    (enchiridion.memory:note-tier-miss tiers)
    (testing "the tier really moved"
      (ok (eq :l1 (enchiridion.memory:promote-tier tiers))))
    (testing "and the compiled prompt did not move with it"
      (ok (string= before
                   (enchiridion.kernel:prompt-text
                    (enchiridion.kernel:compile-prompt blocks)))))))
