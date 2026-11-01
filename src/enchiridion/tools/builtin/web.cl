;;;; web.cl --- Fetch a URL and search DuckDuckGo.
;;;;
;;;; Fetch is the useful half and the one the tests can mock. Search uses the
;;;; DuckDuckGo JSON endpoint, which returns related topics and an abstract
;;;; without a key. It is not a full search index, and the docstring says so.

(in-package #:enchiridion.tools.builtin)

(defparameter *web-get-function* #'dexador:get
  "The one HTTP GET the web tools use. Bound in tests so no socket is opened.")

(defparameter +web-timeout+ 20
  "Seconds before one web request is abandoned.")

(defun url-encode (text)
  "Return TEXT percent encoded as UTF-8."
  (with-output-to-string (stream)
    (loop for byte across (enchiridion.compat:encode-utf8 text)
          do (if (or (<= (char-code #\A) byte (char-code #\Z))
                     (<= (char-code #\a) byte (char-code #\z))
                     (<= (char-code #\0) byte (char-code #\9))
                     (member byte (map 'list #'char-code "-_.~")))
                 (write-char (code-char byte) stream)
                 (format stream "%~2,'0X" byte)))))

(defparameter +web-body-limit+ (* 2 1024 1024)
  "The most bytes one fetch reads. A result is capped at a few thousand
characters anyway; this bounds what is held in memory before the cap, so a
link to a large download costs two megabytes and not the download.")

(defun binary-octets-p (octets count)
  "Return T when the first COUNT OCTETS look like binary rather than text.
A NUL byte in the head is the test: text formats do not carry one."
  (loop for index from 0 below (min count 1024)
        thereis (zerop (aref octets index))))

(defun octets-text (octets count truncated-p)
  "Return the first COUNT OCTETS as the text a fetch reports."
  (if (binary-octets-p octets count)
      (format nil "[binary content, ~:[~D~;more than ~D~] bytes, not shown]"
              truncated-p count)
      (format nil "~A~:[~;~%[truncated at ~D bytes]~]"
              (enchiridion.compat:decode-utf8-lenient (subseq octets 0 count))
              truncated-p count)))

(defun web-body-text (body)
  "Return BODY, what the getter answered, as bounded text.

The real getter is asked for a binary stream so that nothing past the limit is
ever read. A string or an octet vector is accepted too, because that is what a
test's getter returns and what an older dexador hands back."
  (typecase body
    (string body)
    ((vector (unsigned-byte 8))
     (let ((count (min (length body) +web-body-limit+)))
       (octets-text body count (> (length body) count))))
    (stream
     (unwind-protect
          (let* ((octets (make-array +web-body-limit+ :element-type '(unsigned-byte 8)))
                 (count (read-sequence octets body))
                 (truncated-p (and (= count +web-body-limit+)
                                   (not (eq :eof (read-byte body nil :eof))))))
            (octets-text octets count truncated-p))
       (ignore-errors (close body))))
    (t (princ-to-string body))))

(defun web-get (url)
  "Return URL as text, with the provider's error reduced to a tool error."
  (handler-case
      (web-body-text
       (funcall *web-get-function* url
                :read-timeout +web-timeout+
                :connect-timeout +web-timeout+
                :want-stream t
                :force-binary t))
    (dexador.error:http-request-failed (failure)
      (error 'enchiridion.errors:tool-error
             :tool "web"
             :detail (format nil "HTTP ~A: ~A"
                             (dexador.error:response-status failure)
                             (let ((body (dexador.error:response-body failure)))
                               (if (or (stringp body) (typep body '(vector (unsigned-byte 8))))
                                   (let ((text (web-body-text body)))
                                     (subseq text 0 (min 2000 (length text))))
                                   "")))))
    (error (condition)
      (error 'enchiridion.errors:tool-error
             :tool "web" :detail (princ-to-string condition)))))

(defun web-search (query limit)
  "Return up to LIMIT DuckDuckGo related topics for QUERY."
  (let* ((url (format nil "https://api.duckduckgo.com/?q=~A&format=json&no_html=1&skip_disambig=1"
                      (url-encode query)))
         (data (enchiridion.llm:parse-json (web-get url)))
         (results '()))
    (labels ((collect (topics)
               (dolist (topic topics)
                 (when (listp topic)
                   (let ((nested (getf topic :topics)))
                     (if nested
                         (collect nested)
                         (let ((text (getf topic :text))
                               (url (getf topic :firsturl)))
                           (when (and text url)
                             (push (format nil "~A - ~A" text url) results)))))))))
      ;; The abstract is the direct answer, so it leads.
      (let ((abstract (getf data :abstracttext))
            (abstract-url (getf data :abstracturl)))
        (when (and abstract abstract-url)
          (push (format nil "~A - ~A" abstract abstract-url) results)))
      (collect (getf data :relatedtopics)))
    ;; RESULTS was built newest first, so it is put back in the order the
    ;; topics arrived before it is cut: the first topics are the relevant ones.
    (let* ((ordered (nreverse results))
           (limited (subseq ordered 0 (min (length ordered) limit))))
      (cap-result (if limited
                      (format nil "~{~A~^~%~}" limited)
                      "no results")))))

(declaim (ftype (function (t) string) web-fetch))

(defun web-fetch (args)
  "Fetch URL, or search for QUERY when ACTION is search."
  (let* ((action (string-downcase (or (argument args "action") "fetch")))
         (limit (or (argument args "limit") 10)))
    (unless (and (integerp limit) (plusp limit))
      (error 'enchiridion.errors:schema-error
             :detail "limit must be a positive integer."))
    (cond
      ((string= action "fetch")
       (let ((url (argument args "url")))
         (unless (and (stringp url)
                      (or (uiop:string-prefix-p "https://" url)
                          (uiop:string-prefix-p "http://" url)))
           (error 'enchiridion.errors:schema-error
                  :detail "url must start with http:// or https://."))
         (cap-result (web-get url))))
      ((string= action "search")
       (let ((query (argument args "query")))
         (unless (and (stringp query) (plusp (length query)))
           (error 'enchiridion.errors:schema-error
                  :detail "query must be a non-empty string."))
         (web-search query limit)))
      (t (error 'enchiridion.errors:schema-error
                :detail (format nil "Unknown web action ~A." action))))))

(defparameter +web-tools+
  (list
   (enchiridion.tools:make-tool
    :name "web"
    :description "Fetch a URL or search the web for a query."
    :schema '(:object :properties
              ((:action :string) (:url :string) (:query :string) (:limit :integer)))
    :handler #'web-fetch)))

(defun register-web-tools ()
  "Register the web tool. Idempotent."
  (dolist (tool +web-tools+)
    (enchiridion.tools:register-tool tool))
  (length +web-tools+))
