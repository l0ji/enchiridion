;;;; json.cl --- The JSON door: one place decides what a parsed object is.
;;;;
;;;; These definitions used to live in openai.cl, which made the OpenAI backend
;;;; the owner of infrastructure every provider needs. The Anthropic backend
;;;; already imported them from there, and a Bedrock or Vertex handler would
;;;; have had to as well. They are here now, below every handler and above none
;;;; of them, so no adapter owns the JSON library.
;;;;
;;;; Two shapes exist in this tree and the difference is the point:
;;;;
;;;;   PARSE-JSON   jzon's data, normalised for this system: an object becomes
;;;;                a plist with keyword keys, an array becomes a list, and
;;;;                JSON null becomes NIL.
;;;;   STRINGIFY    the text half of the same shape. It writes a hash table as
;;;;                an object and a plist as an ARRAY, which is why every
;;;;                request body is built with JSON-OBJECT and not with a
;;;;                quoted list.
;;;;
;;;; A parser that needs to tell an empty array from an absent field, or that
;;;; must keep an object an object, reads jzon's own types instead; that is why
;;;; the Anthropic and Vertex handlers call COM.INUOE.JZON:PARSE directly in
;;;; the places where the distinction matters.

(in-package #:enchiridion.llm)

;; jzon spells JSON null as an unexported symbol rather than as NIL, and its
;; own JSON-ATOM type says so: T is true, NIL is false, REAL is a number and
;; this symbol is null. PARSE hands the symbol back, so a provider that omits a
;; field and a provider that sends the field as null arrive as two different
;; values and would reach two different code paths if it were passed through as
;; it came.
;;
;; Naming it here is why this file has an internal reference to a dependency at
;; all. There is no exported name to ask for, and the parsers have to be able
;; to recognise the value once it is in hand.
;;
;; The QUOTE is not decoration. DEFCONSTANT evaluates its value form, and a bare
;; symbol in an evaluated position is a variable reference, so writing the name
;; unqualified here reads as a lookup of a variable called null and fails during
;; the compile of this file with an unbound variable whose name gives nothing
;; away. The backtrace prints CL:NULL as bare NULL because *PRINT-ESCAPE* is off,
;; so the reported name looks like the standard Lisp one it is not.
(defconstant +json-null+ 'com.inuoe.jzon::null)

(declaim (ftype (function (t) keyword) json-key))

(defun json-key (name)
  "Return NAME as a keyword, interned in KEYWORD.

NAME is an OR a CHARACTER, not only a string. jzon pools short object keys
and pools a one character key as the character itself, so a reply with a key
called \"id\" arrives here as #\\I rather than as \"id\". STRING on either turns
that back into a name, and without it the first short key in a reply is a type
error.

The DECLARE is inline and not an F-TYPE because an F-TYPE lambda list whose one
argument spec is itself a compound type has to be written ((TYPE)), and a
reader error in a declaim costs a whole build to find.

Interning in KEYWORD rather than in this package means a provider that invents
a key cannot intern a symbol into enchiridion.llm and make it look like part
of this system's own API."
  (declare (type (or string character) name))
  (intern (string-upcase (string name)) :keyword))

(declaim (ftype (function (t) list) json-object->plist))

(defun json-object->plist (table)
  "Return TABLE, a jzon object, as a plist with keyword keys.

jzon represents a JSON object as a hash table keyed by strings, measured
against com.inuoe.jzon 1.1.4, and has no option to change that. GETF on a
hash table is a malformed property list error, so every accessor in a parser
would fail on the first reply. Converting here means one place owns the
translation and every caller above it speaks the plist shape the rest of this
system already uses."
  (loop for key being the hash-keys of table
        append (list (json-key key) (json->lisp (gethash key table)))))

(declaim (ftype (function (t) t) json->lisp))

(defun json->lisp (node)
  "Return NODE, as jzon produced it, in this system's shape.

An object arrives as a hash table and becomes a plist. An array arrives as a
vector and becomes a list. A cons is mapped over for the benefit of any future
jzon that changes its mind about arrays. Numbers, booleans and NIL are already
what they are and are returned untouched.

STRINGP is tested before VECTORP, and the order is the whole function. jzon
returns a JSON string whose characters are all base characters as a
SIMPLE-BASE-STRING, and SBCL reports that as a vector as well as a string. A
branch that tests VECTORP first therefore turns every string in a reply into a
list of characters, and the symptom is a STRING= against a list of CHAR, which
says nothing at all about where it came from.

JSON null becomes NIL. jzon's JSON-ATOM type says so outright: T is true, NIL
is false, REAL is a number and the symbol NULL is null. A provider that omits
a field and a provider that sends it as null are the same fact to every caller
here, and leaving NULL in place means it reaches a string slot and fails as a
type error about a word nobody wrote."
  (cond
    ((hash-table-p node) (json-object->plist node))
    ((stringp node) node)
    ((vectorp node) (map 'list #'json->lisp node))
    ((consp node) (map 'list #'json->lisp node))
    ((eq node +json-null+) nil)
    (t node)))

(declaim (ftype (function (string) t) parse-json))

(defun parse-json (text)
  "Return TEXT as JSON data: objects as plists keyed by keyword, arrays as
lists, strings as strings, numbers as numbers.

Signals JSON-PARSE-ERROR on malformed input rather than returning NIL, because
a provider that answered with an error page and a provider that answered with
an empty object are different problems and the message has to say which."
  (json->lisp (com.inuoe.jzon:parse text)))

(declaim (ftype (function (t) (or null string)) stringify))

(defun stringify (object)
  "Return OBJECT as JSON text.

NIL is written as false and not omitted, which is why every request builder
omits a field it does not want rather than setting it to NIL. An empty list is
written as false too, so a field the wire requires to be an array is coerced
to a vector by its builder."
  (com.inuoe.jzon:stringify object))

(declaim (ftype (function (&rest t) hash-table) json-object))

(defun json-object (&rest pairs)
  "Return PAIRS, alternating keys and values, as the object STRINGIFY writes as
a JSON object.

STRINGIFY takes the same shape PARSE produces, and that shape is a hash table
keyed by strings. Handed a plist it writes an ARRAY of alternating elements
instead, so the provider receives [\"model\",\"m\",...] rather than {...} and
answers with an error about a malformed request. Keys are downcased because
that is what a JSON object conventionally looks like on the wire; the reading
side upcases whatever it gets, so the case is only ever cosmetic here.

One constructor for this, so the mistake above is made in one place rather
than in every object the tree builds."
  (let ((table (make-hash-table :test #'equal)))
    (loop for (key value) on pairs by #'cddr
          do (setf (gethash (string-downcase (string key)) table) value))
    table))

(declaim (ftype (function (t t &optional t) t) json-value))

(defun json-value (object key &optional default)
  "Return KEY from OBJECT, a jzon object, or DEFAULT.

Keys are compared with STRING-EQUAL and not by identity, because jzon pools
object keys: a table just parsed holds the pooled string, and a GETHASH against
a fresh literal of the same characters is the kind of code that works until the
pool grows. A value that is not an object, an absent key and a JSON null all
answer DEFAULT rather than signalling, because a provider that omits a field
and one that sends it as null are the same fact to every caller here."
  (if (hash-table-p object)
      (let ((name (loop for candidate being the hash-keys of object
                        when (string-equal (string candidate) key)
                          return candidate)))
        (if name (gethash name object) default))
      default))

(declaim (ftype (function (t) string) json-string))

(defun json-string (value)
  "Return VALUE as a string, or the empty string when it is absent or null.

jzon spells JSON null as a symbol, so a field the provider sent as null
reaches this function as something that is neither a string nor NIL, and every
completion slot it is stored in is typed STRING."
  (if (stringp value) value ""))

(declaim (ftype (function (t) (integer 0 *)) json-count))

(defun json-count (value)
  "Return VALUE as a token count, and zero for anything else.

A missing usage field, a null and a value that is not a whole number are all an
unknown cost, and zero is the honest answer for an unknown cost. The completion
slots are typed (INTEGER 0 *), so jzon's null symbol would be a type error at
the constructor rather than the number nobody asked for."
  (if (and (integerp value) (not (minusp value))) value 0))
