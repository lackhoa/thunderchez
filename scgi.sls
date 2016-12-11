;;
;; Copyright 2016 Aldo Nicolas Bruno
;;
;; Licensed under the Apache License, Version 2.0 (the "License");
;; you may not use this file except in compliance with the License.
;; You may obtain a copy of the License at
;;
;;     http://www.apache.org/licenses/LICENSE-2.0
;;
;; Unless required by applicable law or agreed to in writing, software
;; distributed under the License is distributed on an "AS IS" BASIS,
;; WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
;; See the License for the specific language governing permissions and
;; limitations under the License.

(library (scgi)
  (export scgi-request-handler handle-scgi-connection run-scgi
	  scgi-headers->bytevector)
  (import (chezscheme)
	  (socket)
	  (netstring)
	  (only (srfi s1 lists) list-index take drop)
	  (only (posix) fork wait-for-pid wait-flag))

  (define (header-get-token l)
    (let ([i (list-index zero? l)])
      (values (take l i) (drop l (+ i 1)))))

  (define (list-u8->string l)
    (utf8->string (apply bytevector l)))

  (define (read-headers sock)
    (let ([r (read-netstring sock)])
      (let loop ([l (bytevector->u8-list r)] [headers '()])
	(if (null? l)
	    (reverse headers)
	    (let-values ([(tok1 rest1) (header-get-token l)])
	      (let-values ([(tok2 rest2) (header-get-token rest1)])
		(loop rest2 (cons (cons (string->symbol (list-u8->string tok1)) (list-u8->string tok2)) headers))))))))

  (define (scgi-headers->bytevector l)
    (apply bytevector
	   (fold-right
	    (lambda (x acc)
	      (let ([name (car x)] [value (cdr x)])
		(append (bytevector->u8-list (string->utf8 name)) '(0)
			(bytevector->u8-list (string->utf8 value)) '(0)
			acc)))
	    '() l )))

  (define scgi-request-handler
    (make-parameter
     (lambda (sock headers content)
       (printf "scgi: headers: ~a~n" headers)
       (printf "scgi: contents: ~a~n" content)
       (put-bytevector sock (string->utf8 "Status: 200 OK\r\nContent-Type: text/html\r\n\r\n<html><body><center><h1><big>WELCOME TO THUNDERCHEZ!</big></h1></center></body></html>")))))
  
  (define (handle-scgi-connection sock)
    (define h (read-headers sock))
    (assert (string=? "1" (cdr (assq 'SCGI h))))
    (let* ([len (string->number (cdr (assq 'CONTENT_LENGTH h)))]
	   [content (get-bytevector-n sock len)])
      (assert (= (bytevector-length content) len))
      ((scgi-request-handler) sock h content)))

  (define (run-scgi addr port)
    (define sock (socket 'inet 'stream '() 0))
    (define nchildren 0)
    (define max-children 10)
    (define waitpid (foreign-procedure "waitpid" (int void* int) int))
    
    (dynamic-wind
	(lambda ()
	  (bind/inet sock addr port)
	  (listen sock 1000))
	(lambda ()
	  (do ()
	      (#f)
	    ;(printf "nchildren ~d~n" nchildren)
	    (printf "scgi: waiting for connection...~n")
	    (let ([cli #f])
	      (dynamic-wind
		  (lambda () (set! cli (accept sock)))
		  (lambda ()
		    (printf "scgi: accepted connection~n")
		    (if (> nchildren max-children)
			(sleep (make-time 'time-duration 0 1)))
		    (printf "scgi: forking..~n")
		    (let ([pid (fork)])
		      (if (= pid 0)			
			  (guard (e [else (display "scgi: handler error: ")
					  (display-condition e)
					  (newline)])
				 (handle-scgi-connection cli)
				 (exit))
			  (set! nchildren (+ 1 nchildren)))))
		  (lambda ()
		    (close-port cli))))
	    (do ()
		((not (> (waitpid 0 0 (wait-flag 'nohang)) 0)))
	      (set! nchildren (- nchildren 1)))))
	
	(lambda ()
	  (close-port sock))))
  );;library scgi



#|

;SERVER EXAMPLE:
(import (scgi))
(run-scgi "localhost" 8088)
;; it will use the default scgi-request-handler

;CLIENT EXAMPLE:
(import (netstring) 
	(socket)
	(scgi))

(define sock (socket 'inet 'stream '() 0))
(connect/inet sock "localhost" 8088)
(define h (scgi-headers->bytevector '(("CONTENT_LENGTH" . "10") 
				      ("SCGI" . "1")
				      ("REQUEST_METHOD" . "POST") 
				      ("REQUEST_URI" . "/chez"))))
(write-netstring sock h)
(put-bytevector sock (bytevector 1 2 3 4 5 6 7 8 9 0))
(flush-output-port sock)
(close-port sock)

;; or just configure nginx with something like this:
;; location /chez {
;; 	include scgi_params;
;; 	scgi_pass localhost:8088;
;; 	scgi_param SCRIPT_NAME "/chez";
;; }

;; and point your browser to http://localhost:8088/chez

|#