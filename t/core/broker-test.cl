;;;; broker-test.cl --- The framing and the in-process transport.
;;;;
;;;; The container isolation tests are separate: they need uid 1000 and a real
;;;; /run/secrets tmpfs. These tests prove the wire format and dispatch, which
;;;; is what the child and the supervisor have to agree on before isolation can
;;;; mean anything.

(defpackage #:enchiridion-broker-test
  (:use #:cl)
  (:import-from #:rove #:deftest #:ok #:ng #:testing #:signals)
  (:export #:run))

(in-package #:enchiridion-broker-test)

(defun scratch-socket ()
  (merge-pathnames (format nil "enchiridion-broker-~D.sock" (random most-positive-fixnum))
                   #p"/tmp/"))

(deftest frames-round-trip ()
  (let ((path (merge-pathnames (format nil "enchiridion-frame-~D.bin"
                                       (random most-positive-fixnum))
                               #p"/tmp/")))
    (unwind-protect
         (progn
           (with-open-file (stream path :direction :output
                                        :element-type '(unsigned-byte 8)
                                        :if-exists :supersede
                                        :if-does-not-exist :create)
             (enchiridion.tools.broker::write-frame stream "hello broker"))
           (with-open-file (stream path :direction :input
                                        :element-type '(unsigned-byte 8))
             (ok (string= "hello broker"
                          (enchiridion.tools.broker::read-frame stream)))
             (ok (null (enchiridion.tools.broker::read-frame stream)))))
      (ignore-errors (delete-file path)))))

(deftest an-in-process-broker-answers-a-ping-and-a-tool ()
  (enchiridion.tools:clear-registry)
  (enchiridion.tools:register-tool
   (enchiridion.tools:make-tool
    :name "echo"
    :description "Echo one string."
    :schema '(:object :required (:text) :properties ((:text :string)))
    :handler (lambda (arguments) (gethash "text" arguments))))
  (let ((broker (enchiridion.tools.broker:make-broker
                 :socket (scratch-socket)
                 :timeout 5)))
    (unwind-protect
         (progn
           (ok (= 1000 (enchiridion.tools.broker::broker-gid broker)))
           (enchiridion.tools.broker:broker-start broker :in-process t)
           (ok (enchiridion.tools.broker:broker-running-p broker))
           (ok (enchiridion.tools.broker:broker-health broker))
           (ok (string= "hello"
                        (enchiridion.tools.broker:broker-call
                         broker "echo" (list :text "hello"))))
           (ok (signals (enchiridion.tools.broker:broker-call
                         broker "missing" nil)
                        'enchiridion.errors:tool-error)))
      (enchiridion.tools.broker:broker-stop broker)
      (ng (enchiridion.tools.broker:broker-running-p broker))
      (enchiridion.tools:clear-registry))))

(deftest broker-tool-results-redact-credential-trees ()
  (enchiridion.tools:clear-registry)
  (enchiridion.tools:register-tool
   (enchiridion.tools:make-tool
    :name "credentials"
    :description "Return synthetic credential fields."
    :schema '(:object :properties ())
    :handler (lambda (arguments)
               (declare (ignore arguments))
               (enchiridion.llm::json-object
                "token" "first-hidden"
                "password" "second-hidden"
                "message" "kept"
                "items" (vector (enchiridion.llm::json-object
                                "api_key" "nested-hidden"
                                "secret" (vector "hidden-container")
                                "message" "also kept"))))))
  (let ((broker (enchiridion.tools.broker:make-broker
                 :socket (scratch-socket) :timeout 5)))
    (unwind-protect
         (progn
           (enchiridion.tools.broker:broker-start broker :in-process t)
           (let* ((result (enchiridion.tools.broker:broker-call
                           broker "credentials" nil))
                  (child (aref (gethash "items" result) 0)))
             (ok (equal "[redacted]" (gethash "token" result)))
             (ok (equal "[redacted]" (gethash "password" result)))
             (ok (equal "kept" (gethash "message" result)))
             (ok (equal "[redacted]" (gethash "api_key" child)))
             (ok (equal "[redacted]" (gethash "secret" child)))
             (ok (equal "also kept" (gethash "message" child)))))
      (enchiridion.tools.broker:broker-stop broker)
      (enchiridion.tools:clear-registry))))

(deftest an-abandoned-call-does-not-answer-the-next-one ()
  ;; A call left between its request and its reply, as a Ctrl-C leaves it,
  ;; used to leave the reply in the socket for the next call to read.
  (enchiridion.tools:clear-registry)
  (enchiridion.tools:register-tool
   (enchiridion.tools:make-tool
    :name "slow"
    :description "Answer after a pause."
    :schema '(:object :properties ((:text :string)))
    :handler (lambda (arguments)
               (declare (ignore arguments))
               (sleep 0.5)
               "slow answer")))
  (enchiridion.tools:register-tool
   (enchiridion.tools:make-tool
    :name "echo"
    :description "Echo one string."
    :schema '(:object :required (:text) :properties ((:text :string)))
    :handler (lambda (arguments) (gethash "text" arguments))))
  (let ((broker (enchiridion.tools.broker:make-broker
                 :socket (scratch-socket)
                 :timeout 5)))
    (unwind-protect
         (progn
           (enchiridion.tools.broker:broker-start broker :in-process t)
           (let ((caller (bordeaux-threads:make-thread
                          (lambda ()
                            (catch 'abandon
                              (enchiridion.tools.broker:broker-call
                               broker "slow" (list :text "x")))))))
             (sleep 0.1)
             (bordeaux-threads:interrupt-thread
              caller (lambda () (throw 'abandon :abandoned)))
             (bordeaux-threads:join-thread caller))
           (ok (string= "hello"
                        (enchiridion.tools.broker:broker-call
                         broker "echo" (list :text "hello")))
               "the next call reads its own answer")
           (ok (enchiridion.tools.broker:broker-health broker)))
      (enchiridion.tools.broker:broker-stop broker)
      (enchiridion.tools:clear-registry))))

(deftest a-call-past-its-deadline-fails-and-frees-the-broker ()
  (enchiridion.tools:clear-registry)
  (enchiridion.tools:register-tool
   (enchiridion.tools:make-tool
    :name "slow"
    :description "Answer after a pause."
    :schema '(:object :properties ())
    :handler (lambda (arguments)
               (declare (ignore arguments))
               (sleep 1)
               "slow answer")))
  (enchiridion.tools:register-tool
   (enchiridion.tools:make-tool
    :name "echo"
    :description "Echo one string."
    :schema '(:object :required (:text) :properties ((:text :string)))
    :handler (lambda (arguments) (gethash "text" arguments))))
  (let ((broker (enchiridion.tools.broker:make-broker
                 :socket (scratch-socket)
                 :timeout 5)))
    (unwind-protect
         (progn
           (enchiridion.tools.broker:broker-start broker :in-process t)
           (ok (signals (enchiridion.tools.broker:broker-call
                         broker "slow" nil :timeout 0.2)
                        'enchiridion.errors:transport-error)
               "a call past its deadline is an error, not a hang")
           (ok (string= "hello"
                        (enchiridion.tools.broker:broker-call
                         broker "echo" (list :text "hello")))
               "and the next call reads its own answer"))
      (enchiridion.tools.broker:broker-stop broker)
      (enchiridion.tools:clear-registry))))

;;;; The generation protocol.

(defun load-hook-reply (values-list)
  "Return a hook that answers with VALUES-LIST and records the digest it saw."
  (lambda (directory generation)
    (declare (ignore directory generation))
    (apply #'values values-list)))

(deftest a-load-request-carries-the-digest-and-the-reply-reports-it ()
  (let ((broker (enchiridion.tools.broker:make-broker :socket (scratch-socket)
                                                      :timeout 5))
        (digest "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
        (seen "not called"))
    (unwind-protect
         (progn
           (setf enchiridion.tools.broker:*load-generation-function*
                 (lambda (directory generation)
                   (declare (ignore directory generation))
                   (setf seen enchiridion.tools.broker::*load-source-digests*)
                   (values t "generation 4 loaded, 1 file" digest 4)))
           (enchiridion.tools.broker:broker-start broker :in-process t)
           (let ((reply (enchiridion.tools.broker:broker-load-generation
                         broker #p"/tmp/" :generation 4 :digests digest)))
             (testing "the child hook sees the digest the supervisor verified"
               (ok (string= digest seen)))
             (testing "the reply reports the digest it published"
               (ok (eq t (gethash "ok" reply)))
               (ok (string= digest (gethash "digests" reply))))
             (testing "and the generation that is live"
               (ok (= 4 (gethash "generation" reply)))
               (ok (search "1 file" (gethash "report" reply))))
             (testing "the replay after a restart does not remember the digest"
               (ok (null (getf (enchiridion.tools.broker::broker-last-load broker)
                               :digests))))))
      (enchiridion.tools.broker:broker-stop broker)
      (setf enchiridion.tools.broker:*load-generation-function* nil))))

(deftest a-load-refusal-comes-back-with-its-report-and-digest ()
  (let ((broker (enchiridion.tools.broker:make-broker :socket (scratch-socket)
                                                      :timeout 5))
        (digest "sha256:fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"))
    (unwind-protect
         (progn
           (setf enchiridion.tools.broker:*load-generation-function*
                 (load-hook-reply
                  (list nil "the agent source changed while it loaded: tools/x.cl changed"
                        digest 3)))
           (enchiridion.tools.broker:broker-start broker :in-process t)
           (let ((reply (enchiridion.tools.broker:broker-load-generation
                         broker #p"/tmp/" :generation 3 :digests digest)))
             (ng (gethash "ok" reply))
             (ok (search "tools/x.cl changed" (gethash "report" reply)))
             (ok (string= digest (gethash "digests" reply)))
             (ok (= 3 (gethash "generation" reply)))))
      (enchiridion.tools.broker:broker-stop broker)
      (setf enchiridion.tools.broker:*load-generation-function* nil))))

(deftest a-two-value-load-hook-still-answers-and-reports-nothing-more ()
  (let ((broker (enchiridion.tools.broker:make-broker :socket (scratch-socket)
                                                      :timeout 5))
        (digest "sha256:aaaaaaaabbbbbbbbccccccccddddddddeeeeeeeeffffffff0000000011111111"))
    (unwind-protect
         (progn
           ;; The shape every hook in the tree had before the digest existed.
           (setf enchiridion.tools.broker:*load-generation-function*
                 (lambda (directory generation)
                   (declare (ignore directory generation))
                   (values t "generation 2 loaded, 1 file")))
           (enchiridion.tools.broker:broker-start broker :in-process t)
           (let ((reply (enchiridion.tools.broker:broker-load-generation
                         broker #p"/tmp/" :generation 2 :digests digest)))
             (ok (eq t (gethash "ok" reply)))
             (ok (search "1 file" (gethash "report" reply)))
             (testing "a hook that reports neither leaves both fields null"
               (ok (null (gethash "digests" reply)))
               (ok (null (gethash "generation" reply))))))
      (enchiridion.tools.broker:broker-stop broker)
      (setf enchiridion.tools.broker:*load-generation-function* nil))))

(deftest the-verification-child-is-given-the-digest-on-its-command-line ()
  ;; The child is replaced rather than started: the command line is what this
  ;; checks, and a real child would compile the whole system to prove it. The
  ;; replacement is global because BROKER-VERIFY-PLUGIN calls the capture
  ;; helper by its global name.
  (let ((digest "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
        (argv nil)
        (original (symbol-function 'enchiridion.compat:run-program-capture)))
    (unwind-protect
         (progn
           (setf (symbol-function 'enchiridion.compat:run-program-capture)
                 (lambda (program arguments &key timeout environment)
                   (declare (ignore program timeout environment))
                   (setf argv arguments)
                   (values "checked" 0)))
           (multiple-value-bind (ok-p output)
               (enchiridion.tools.broker:broker-verify-plugin #p"/tmp/" :digests digest)
             (ok ok-p)
             (ok (string= "checked" output))
             (ok (string= digest
                          (nth (1+ (position "--digests" argv :test #'string=))
                               argv))))
           (testing "and a caller with no digest adds no argument"
             (enchiridion.tools.broker:broker-verify-plugin #p"/tmp/")
             (ok (null (member "--digests" argv :test #'string=)))))
      (setf (symbol-function 'enchiridion.compat:run-program-capture) original))))
