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

(defun web-get (url)
  "Return URL as text, with the provider's error reduced to a tool error."
  (handler-case
      (funcall *web-get-function* url
               :read-timeout +web-timeout+
               :connect-timeout +web-timeout+)
    (dexador.error:http-request-failed (failure)
      (error 'enchiridion.errors:tool-error
             :tool "web"
             :detail (format nil "HTTP ~A: ~A"
                             (dexador.error:response-status failure)
                             (dexador.error:response-body failure))))
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
      (collect (getf data :relatedtopics))
      (let ((abstract (getf data :abstracttext))
            (abstract-url (getf data :abstracturl)))
        (when (and abstract abstract-url)
          (push (format nil "~A - ~A" abstract abstract-url) results))))
    (let ((limited (subseq results 0 (min (length results) limit))))
      (cap-result (if limited
                      (format nil "~{~A~^~%~}" (nreverse limited))
                      "no results")))))

(declaim (ftype (function (t) string) web-fetch))

(defun web-fetch (args)
  "Fetch URL, or search for QUERY when ACTION is search."
  (let* ((action (string-downcase (or (argument args "action") "fetch")))
         (limit (or (argument args "limit") 10)))
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
