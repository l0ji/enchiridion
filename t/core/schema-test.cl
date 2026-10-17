;;;; schema-test.cl --- One declaration, two jobs.
;;;;
;;;; The schema is both the JSON the model sees and the check the dispatcher
;;;; runs. These tests keep those two uses honest: the JSON has the shape the
;;;; model needs, and the same form rejects a missing or wrongly typed argument.

(defpackage #:enchiridion-schema-test
  (:use #:cl)
  (:import-from #:rove #:deftest #:ok #:ng #:testing #:signals)
  (:export #:run))

(in-package #:enchiridion-schema-test)

(defparameter +schema+
  '(:object
    :required (:path)
    :properties ((:path :string)
                 (:from :integer)
                 (:to :integer))))

(deftest a-schema-becomes-json-schema ()
  (let ((json (enchiridion.tools:schema-json-string +schema+)))
    (ok (search "\"type\":\"object\"" json))
    (ok (search "\"path\"" json))
    (ok (search "\"integer\"" json))
    (ok (search "\"required\":[\"path\"]" json))))

(deftest a-valid-argument-set-passes ()
  (ok (enchiridion.tools:validate-arguments +schema+ (list :path "x")))
  (ok (enchiridion.tools:validate-arguments +schema+ (list :path "x" :from 1 :to 2))))

(deftest a-required-argument-is-required ()
  (ok (signals (enchiridion.tools:validate-arguments +schema+ (list :from 1))
               'enchiridion.errors:schema-error))
  (ok (signals (enchiridion.tools:validate-arguments +schema+ (list :path 42))
               'enchiridion.errors:schema-error)))

(deftest an-unknown-argument-is-rejected ()
  (ok (signals (enchiridion.tools:validate-arguments
                +schema+ (list :path "x" :typo 1))
               'enchiridion.errors:schema-error)))

(deftest schema-tokens-is-a-positive-estimate ()
  (ok (plusp (enchiridion.tools:schema-tokens +schema+))))
