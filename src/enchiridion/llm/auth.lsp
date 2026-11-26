;;;; auth.lsp --- Credential headers, query parameters, and request signers.
;;;;
;;;; Static schemes (:bearer, :api-key-header, :x-api-key, :query-param, :none)
;;;; are handled here; signed schemes (:aws-sigv4, :gcp-oauth) register via
;;;; REGISTER-AUTH-SIGNER from aws-sigv4.lsp and gcp-oauth.lsp.

(in-package #:enchiridion.llm)

;;;; Static schemes.

(declaim (ftype (function (t t &optional list) list) auth-headers))

(defun auth-headers (dialect key &optional extra)
  "Return credential headers for DIALECT merged with EXTRA, or NIL for
query-param, none, and signed schemes (applied later by AUTH-APPLY)."
  (let ((scheme (dialect-field dialect :auth-scheme :bearer))
        ;; Explicit :auth-header NIL falls back to "api-key".
        (name (or (dialect-field dialect :auth-header nil) "api-key"))
        ;; Optional value prefix, e.g. "Bearer " for custom gateway headers.
        (prefix (dialect-field dialect :auth-prefix "")))
    (merge-headers
     (case scheme
       (:bearer (list (cons :authorization (format nil "Bearer ~A" key))))
       (:api-key-header (list (cons name (format nil "~A~A" prefix key))))
       (:x-api-key (list (cons :x-api-key key)))
       ((:query-param :none :aws-sigv4 :gcp-oauth) '())
       (t (list (cons :authorization (format nil "Bearer ~A" key)))))
     extra)))

(declaim (ftype (function (t t) list) auth-query-params))

(defun merge-query-params (base extra)
  "Return BASE with EXTRA replacing parameters with the same name."
  (let ((result (header-pairs base)))
    (dolist (pair (header-pairs extra) result)
      (setf result (append (remove (car pair) result :key #'car :test #'string=)
                           (list pair))))))

(defun auth-query-params (dialect key)
  "Return credential query parameters for DIALECT (:query-param only), or NIL."
  (if (and (eq (dialect-field dialect :auth-scheme) :query-param)
           (plusp (length key)))
      (list (cons (or (dialect-field dialect :auth-query "key") "key") key))
      '()))

;;;; Signed schemes.

(defparameter *auth-signers* '()
  "Plist mapping signed scheme keywords to functions of (DIALECT KEY REQUEST)
returning headers.")

(declaim (ftype (function (symbol function) t) register-auth-signer))

(defun register-auth-signer (scheme function)
  "Register FUNCTION as the signer for SCHEME and return the table."
  (setf (getf *auth-signers* scheme) function))

(declaim (ftype (function (t) t) find-auth-signer))

(defun find-auth-signer (scheme)
  "Return the signer registered for SCHEME, or NIL."
  (getf *auth-signers* scheme))

;;;; Entry point.

(declaim (ftype (function (string t list) string) url-with-query))

(defun url-with-query (url key parameters)
  "Return URL with optional KEY and PARAMETERS appended to any existing query
string. Accepts (NAME VALUE) or (NAME . VALUE) entries."
  (let ((parameters (if (and key (plusp (length key)))
                        (cons key parameters)
                        parameters)))
    (if parameters
        (format nil "~A~A~{~A=~A~^&~}"
                url
                (if (search "?" url) "&" "?")
                (loop for parameter in parameters
                      append (list (quri:url-encode (princ-to-string (car parameter)))
                                    (quri:url-encode
                                     (princ-to-string
                                      (if (consp (cdr parameter))
                                          (cadr parameter)
                                          (cdr parameter)))))))
        url)))

(defun auth-apply (dialect key request &key extra)
  "Apply DIALECT's query params, static headers, extra headers, and any
registered signer to REQUEST (after its body is populated) and return REQUEST."
  (let* ((scheme (dialect-field dialect :auth-scheme :bearer))
         (signer (find-auth-signer scheme))
         (url (url-with-query (http-request-url request)
                              nil
                              (append (auth-query-params dialect key)
                                      (dialect-field dialect :query-params '())))))
    (setf (http-request-url request) url)
    (setf (http-request-headers request)
          (merge-headers
           (merge-headers
            (auth-headers dialect key)
            (append (dialect-field dialect :extra-headers '())
                    (http-request-headers request) extra))
           (if signer (funcall signer dialect key request) '())))
    request))
