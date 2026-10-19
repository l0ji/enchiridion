;;;; auth.cl --- How a credential becomes a header, a query parameter, or a
;;;; signature.
;;;;
;;;; There are four simple answers and two signed ones. The simple four are
;;;; here: a bearer token, a vendor-named key header (Azure's api-key), an
;;;; x-api-key header (Anthropic), and a query parameter (Google's older
;;;; samples), plus the no-credential case a local server wants.
;;;;
;;;; The signed two are not here, and that is the point. AWS Signature V4 and
;;;; Google OAuth are each a body of code that one vendor uses; they live in
;;;; aws-sigv4.cl and gcp-oauth.cl. Those files register a signer under their
;;;; scheme name, and this file dispatches to it. Nothing above auth.cl names
;;;; a vendor, and adding a third signed scheme later is a file and a register
;;;; call rather than an edit here.

(in-package #:enchiridion.llm)

;;;; The static schemes.

(declaim (ftype (function (t t &optional list) list) auth-headers))

(defun auth-headers (dialect key &optional extra)
  "Return the credential header for DIALECT, or NIL when there is none.

A signed scheme returns nothing here: its header cannot be written until the
request exists, and AUTH-APPLY is what puts it in place."
  (let ((scheme (dialect-field dialect :auth-scheme :bearer))
        (name (dialect-field dialect :auth-header "api-key"))
        ;; A vendor-named header sometimes carries a scheme word in its value:
        ;; Cloudflare's gateway wants `cf-aig-authorization: Bearer <token>`,
        ;; and the credential itself is the token. The prefix is data so that
        ;; one header name is not enough information to send a right request.
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

(defun auth-query-params (dialect key)
  "Return the credential query parameters for DIALECT.

Google's older samples pass the key as ?key=...; the endpoint also accepts a
header, and the profile chooses. Every other scheme answers the empty list."
  (if (and (eq (dialect-field dialect :auth-scheme) :query-param)
           (plusp (length key)))
      (list (cons (or (dialect-field dialect :auth-query "key") "key") key))
      '()))

;;;; The signed schemes.

(defparameter *auth-signers* '()
  "Scheme keyword to a function of (DIALECT KEY REQUEST) returning headers.

A signer closes over its own credentials and its own clock, so this table is
the only thing the core knows about it. Filled by aws-sigv4.cl and
gcp-oauth.cl as they load.")

(declaim (ftype (function (symbol function) t) register-auth-signer))

(defun register-auth-signer (scheme function)
  "Register FUNCTION as the signer for SCHEME and return the table."
  (setf (getf *auth-signers* scheme) function))

(declaim (ftype (function (t) t) find-auth-signer))

(defun find-auth-signer (scheme)
  "Return the signer registered for SCHEME, or NIL."
  (getf *auth-signers* scheme))

;;;; The one entry point.

;; A URL with a query string has to gain parameters without losing what it
;; already carries; the catalog and the model listers build URLs with query
;; strings of their own, so this is not hypothetical.
(declaim (ftype (function (string t list) string) url-with-query))

(defun url-with-query (url key parameters)
  "Return URL with KEY as the query parameter, plus PARAMETERS, appended.

KEY is the credential parameter name and may be NIL when there is only
PARAMETERS. An existing query string is kept and extended rather than
replaced, because the model listers add parameters of their own."
  (let ((parameters (if (and key (plusp (length key)))
                        (cons key parameters)
                        parameters)))
    (if parameters
        (format nil "~A~A~{~A=~A~^&~}"
                url
                (if (search "?" url) "&" "?")
                ;; A caller may write a parameter as (NAME VALUE) or as
                ;; (NAME . VALUE), exactly as a header may be written, and the
                ;; two must not produce different URLs.
                (loop for parameter in parameters
                      append (list (car parameter)
                                   (if (consp (cdr parameter))
                                       (cadr parameter)
                                       (cdr parameter)))))
        url)))

(defun auth-apply (dialect key request &key extra)
  "Return REQUEST with DIALECT's credential applied to it.

The one place a handler has to call for auth, so a scheme that needs the
finished body (SigV4 hashes it) and one that needs only the key take the same
path. The body is already in the request at this point, which is exactly why
signing is done here and not when the connection is built."
  (let* ((scheme (dialect-field dialect :auth-scheme :bearer))
         (signer (find-auth-signer scheme))
         (url (url-with-query (http-request-url request)
                              nil
                              (append (auth-query-params dialect key)
                                      (dialect-field dialect :query-params '())))))
    (setf (http-request-url request) url)
    (setf (http-request-headers request)
          (merge-headers
           (append (auth-headers dialect key)
                   (dialect-field dialect :extra-headers '())
                   extra)
           (if signer (funcall signer dialect key request) '())))
    request))
