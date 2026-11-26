;;;; json.lsp --- Shared JSON parsing and serialization over com.inuoe.jzon.
;;;;
;;;; PARSE-JSON converts objects to keyword plists, arrays to lists, and JSON
;;;; null to NIL. STRINGIFY writes hash tables (built with JSON-OBJECT) as
;;;; objects and lists as arrays; handlers needing exact null/empty-array
;;;; distinctions call COM.INUOE.JZON:PARSE directly.

(in-package #:enchiridion.llm)

;; jzon's unexported sentinel for JSON null; quoted because DEFCONSTANT evaluates its form.
(defconstant +json-null+ 'com.inuoe.jzon::null)

(declaim (ftype (function (t) keyword) json-key))

(defun json-key (name)
  "Intern NAME (string or character) as an uppercase keyword.
Handles characters because jzon pools 1-char keys as CHARACTER."
  (declare (type (or string character) name))
  (intern (string-upcase (string name)) :keyword))

(declaim (ftype (function (t) list) json-object->plist))

(defun json-object->plist (table)
  "Convert a jzon hash-table object into a plist with keyword keys."
  (loop for key being the hash-keys of table
        append (list (json-key key) (json->lisp (gethash key table)))))

(declaim (ftype (function (t) t) json->lisp))

(defun json->lisp (node)
  "Convert jzon values to Lisp shapes: hash tables to plists, vectors/conses to
lists, +JSON-NULL+ to NIL. Tests STRINGP before VECTORP because SBCL base-strings are vectors."
  (cond
    ((hash-table-p node) (json-object->plist node))
    ((stringp node) node)
    ((vectorp node) (map 'list #'json->lisp node))
    ((consp node) (map 'list #'json->lisp node))
    ((eq node +json-null+) nil)
    (t node)))

(declaim (ftype (function (string) t) parse-json))

(defun parse-json (text)
  "Parse JSON TEXT into Lisp data (objects as keyword plists, arrays as lists,
null as NIL). Signals JSON-PARSE-ERROR on malformed input."
  (json->lisp (com.inuoe.jzon:parse text)))

(declaim (ftype (function (t) (or null string)) stringify))

(defun stringify (object)
  "Serialize OBJECT to JSON text.
NIL and empty lists serialize as false; use vectors for empty JSON arrays."
  (com.inuoe.jzon:stringify object))

(declaim (ftype (function (&rest t) hash-table) json-object))

(defun json-object (&rest pairs)
  "Build a string-keyed hash table from alternating key/value PAIRS for STRINGIFY
(which serializes plists as arrays). Keys are downcased."
  (let ((table (make-hash-table :test #'equal)))
    (loop for (key value) on pairs by #'cddr
          do (setf (gethash (string-downcase (string key)) table) value))
    table))

(declaim (ftype (function (t t &optional t) t) json-value))

(defun json-value (object key &optional default)
  "Look up KEY in jzon hash-table OBJECT (case-insensitively, avoiding pooled-key
identity issues), returning DEFAULT if absent or not a hash table."
  (if (hash-table-p object)
      (let ((name (loop for candidate being the hash-keys of object
                        when (string-equal (string candidate) key)
                          return candidate)))
        (if name (gethash name object) default))
      default))

(declaim (ftype (function (t) string) json-string))

(defun json-string (value)
  "Return VALUE if it is a string, otherwise \"\" (handling NIL and +JSON-NULL+)."
  (if (stringp value) value ""))

(declaim (ftype (function (t) (integer 0 *)) json-count))

(defun json-count (value)
  "Return VALUE if it is a non-negative integer, otherwise 0."
  (if (and (integerp value) (not (minusp value))) value 0))
