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
