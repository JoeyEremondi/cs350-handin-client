#lang racket/base

(require openssl/mzssl "this-collection.rkt")
;; (require net/http-client)

(require websocket/rfc6455)
(require net/url)
(require racket/port)
;; (require net/http-client)
(require racket/string)
(require racket/list)
 (require racket/async-channel)

(provide handin-connect
         handin-disconnect
         retrieve-user-fields
         retrieve-active-assignments
         retrieve-status
         submit-assignment
         retrieve-assignment
         submit-addition
         submit-info-change
         retrieve-user-info)


(define FRAGMENT_SIZE 512000000)

(define current-thread-id (make-parameter -1))

(define-struct handin (r w))

(define-syntax-rule (debugln x args ...)
  ;; (displayln (format x args ...))
  (void)
             )

;; errors to the user: no need for a "foo: " prefix
(define (error* fmt . args)
  (error (apply format fmt args)))

;; Receiver
(define (ws-input-port conn)
  (make-input-port 'ws-input
                  (lambda (mut-bytes)
                    (define in-port (ws-recv-stream conn))
                    (define ret (read-bytes! mut-bytes in-port))
                    (debugln "Read ~s websocket bytes\n    ~s" ret (bytes->string/utf-8 mut-bytes #f 0 ret))
                    ret
                    )
                  #f
                  (lambda ()
                    ;; (displayln "Closing input ws ")
                     (ws-close! conn) ;;TODO put back? Looks like output closed first
                    )))

;;Sender
(define (ws-output-port conn)
  (define current-bytes (open-output-bytes 'ws-output-buffer))
  ;; Start a send with the input port, waiting input to be provided to the output port
  (make-output-port 'ws-output
  always-evt
  (lambda (bytes start end flush block)
    (debugln "Writing bytes ~s\n     start end ~s ~s ~s ~s" bytes start end flush block)
    (define ret (write-bytes bytes current-bytes start end))
    ;; (printf "Writing bytes start ~s end ~s flush ~s block ~s\n" start end flush block )
    ;; Start a new ws message if we're flushing
    (when (> end start) ;;flush
      (define buffered-bytes (get-output-bytes current-bytes))
      ;; (displayln (format "~s : Writing bytes ~s" (current-thread-id) buffered-bytes))
      (if (<= (- end start) FRAGMENT_SIZE)
      (ws-send! conn buffered-bytes #:payload-type 'text)
      ;; If message is large, then send it as fragments
      (begin
        ;; Send the first chunk with type "text", and marked as non final
        (ws-send! conn (subbytes buffered-bytes start (+ start FRAGMENT_SIZE))
                  #:payload-type 'text
                  #:final-fragment? #f)
        ;; (displayln "Sent first fragment")
        ;; Send each intermediate fragment as non-final continuation
        (for ([start-i (range (+ start FRAGMENT_SIZE) (- end FRAGMENT_SIZE) FRAGMENT_SIZE)])
          ;; (printf "Sending message start ~s start-i ~s end ~s\n" start start-i end )
          (ws-send! conn (subbytes buffered-bytes start-i (+ start-i FRAGMENT_SIZE))
                                   #:payload-type 'continuation
                                   #:final-fragment? #f))
        ;; Send the last message with the final marker
        ;; (printf "Sending last fragment start ~s end ~s\n" (- end (modulo (- end start) FRAGMENT_SIZE)) end)
        (ws-send! conn (subbytes buffered-bytes (- end (modulo (- end start) FRAGMENT_SIZE)) end)
                                   #:payload-type 'continuation
                                   #:final-fragment? #t)))
      (set! current-bytes (open-output-bytes 'ws-output-buffer))
      )
    ret)
  ;; Close if we haven't already
  (lambda ()
    ;; (displayln "Closing output ws")
    (ws-close! conn))))


(define (write+flush port . xs)
  (for ([x (in-list xs)]) (write x port) (newline port))
  (flush-output port))

;; (define (write+flush conn . xs)
;;   (define port (open-output-string))
;;   (for ([x (in-list xs)]) (write x port) (newline port))
;;   (define str (get-output-string port))
;;   (displayln (format "client sending ~s" str))
;;   (ws-send! conn str)
;;   (displayln (format "client sent ~s" str))
;;  )


(define (close-handin-ports h)
  (close-input-port (handin-r h))
  (close-output-port (handin-w h)))

;; (define (ping-url url)
;;   (displayln "ping")
;;   (with-handlers ([(lambda (_) #t)
;;                    (λ (ex)
;;                      (displayln "ping timedout")
;;                      #t)])
;;     (sync/timeout
;;         1.0
;;         (thread (lambda ()
;;               (displayln "in thread")
;;             (let-values ([(status headers body-in)
;;                   (http-sendrecv/url (string->url url) #:method 'HEAD)])
;;             (let ([status-string (bytes->string/locale status)])
;;             ;; (displayln "Status string")
;;             ;; (displayln status-string)
;;             (if (string-suffix? status-string "OK")
;;                 #t
;;                 (error "bad resp")))))))))


(define (wait-for-ok r who . reader)
  (let ([v (if (pair? reader) ((car reader)) (read r))])
    (unless (eq? v 'ok) (error* "~a error: ~a" who v))))


;; ssl connection, makes a readable error message if no connection
(define (connect-to server port ws-url [cert #f] #:force-websocket? (force-websocket? #f))
  (define pem (or cert (in-this-collection "server-cert.pem")))
  (define ctx (ssl-make-client-context))
  (ssl-set-verify! ctx #t)
  (ssl-load-default-verify-sources! ctx)
  (if (file-exists? pem)
      (ssl-load-verify-root-certificates! ctx pem)
      (ssl-set-verify-hostname! ctx #t))
  (with-handlers
      ([exn:fail:network?
        (lambda (e)
          (let* ([msg
                  "handin-connect: could not connect to the server (~a:~a)\n~v"]
                 [msg (format msg server port e)]
                 #; ; un-comment to get the full message too
                 [msg (string-append msg " (" (exn-message e) ")")])
            (raise (make-exn:fail:network msg (exn-continuation-marks e)))))])
    ;(ssl-connect server port ctx)
    ;; Only connect via bridge if not on campus
  (define chan (make-async-channel))
  ;; (define my-ip (port->string (get-pure-port (string->url "https://api.ipify.org"))))
  ;; (define on-campus? (string-prefix? my-ip "142.3"))
  ;; Try connecting via TCP
  (define tcp-success-channel (make-channel))
  (define tcp-url "eremondj.csdyn.uregina.ca" )
  (define tcp-port 7971)
  (define conn-thr
    (thread (lambda ()
          (when (not force-websocket?)
            (define-values (l r) (ssl-connect tcp-url tcp-port ctx))
            (channel-put tcp-success-channel (cons l r))))))
  (sleep)
  (define tcp-conn (and (not force-websocket?) (sync/timeout 1.5 tcp-success-channel)))
  (kill-thread conn-thr)
  ;; Force TCP connection if we're on campus
  (if tcp-conn
      (begin
        ;; (displayln "Connecting directly via TCP")
        (values (car tcp-conn) (cdr tcp-conn)))
      ;; Use websocket ports if TCP failed
      (begin
          ;; (displayln "Falling back to websocket connection")
          ;; (let ([conn (ws-connect (string->url "wss://racket.cs.uregina.ca/drracket"))])
          (let ([conn (ws-connect (string->url ws-url))])
          (values  (ws-input-port conn) (ws-output-port conn)))))
    ))

(define (handin-connect server port [cert #f] #:force-websocket? (force-websocket? #f) #:ws-url (url  "wss://racket.cs.uregina.ca/drracket") )
  (let-values ([(r w) (connect-to server port url cert #:force-websocket? force-websocket?)])
    (write+flush w 'handin)
    ;; Sanity check: server sends "handin", first:
    (let ([s (read-bytes 6 r)])
      (unless (equal? #"handin" s)
        (error 'handin-connect "bad handshake from server: ~e ~e" s (read-bytes 30000 r))))
    ;; Tell server protocol = 'ver1:
    (write+flush w 'ver1)
    ;; One more sanity check: server recognizes protocol:
    (let ([s (read r)])
      (unless (eq? s 'ver1)
        (error 'handin-connect "bad protocol from server: ~e" s)))
    ;; Return connection:
    (make-handin r w)))

(define (handin-disconnect h)
  (write+flush (handin-w h) 'bye)
  (close-handin-ports h))

(define (retrieve-user-fields h)
  (let ([r (handin-r h)] [w (handin-w h)])
    (write+flush w 'get-user-fields 'bye)
    (let ([v (read r)])
      (unless (and (list? v) (andmap string? v))
        (error* "failed to get user-fields list from server"))
      (wait-for-ok r "get-user-fields")
      (close-handin-ports h)
      v)))

(define (retrieve-active-assignments h)
  (let ([r (handin-r h)] [w (handin-w h)])
    (write+flush w 'get-active-assignments)
    (let ([v (read r)])
      (unless (and (list? v) (andmap string? v))
        (error* "failed to get active-assignment list from server"))
      v)))

(define (retrieve-status h)
  (let ([r (handin-r h)] [w (handin-w h)])
    (write+flush w 'get-status)
    (let ([v (read r)])
      (unless (hash? v)
        (error* "failed to get status from server"))
      v)))

(define (submit-assignment h username passwd assignment content
                           on-commit message message-final message-box
                           #:submit-on-error? [submit-on-error? #f]
                           #:thread-id [thread-id -1])
  (parameterize ([current-thread-id thread-id])
   (define failed #t)
   (let loop ([fail-count 0])
     (define (error*-or-tryagain arg fmt)
       (if (and (string-contains? arg "eof") (<= fail-count 10))
            (begin
              (sleep 0.5)
              (loop (add1 fail-count)))
           (error* arg fmt)
           
           ))
    (let ([r (handin-r h)] [w (handin-w h)])
    (define (read/message)
      (let ([v (read r)])
        (case v
          [(message) (message (read r)) (read/message)]
          [(message-final) (message-final (read r)) (read/message)]
          [(message-box)
           (write+flush w (message-box (read r) (read r))) (read/message)]
          [else v])))
    (write+flush w
      'set 'username/s username
      'set 'password   passwd
      'set 'assignment assignment
      'set 'submit-on-error (if submit-on-error? "yes" "no")
      'save-submission)
    (wait-for-ok r "login")
    (write+flush w (bytes-length content))
    (let ([v (read r)])
      (unless (eq? v 'go) (error*-or-tryagain "upload error: ~a" v)))
    (display "$" w)
    (display content w)
    (flush-output w)
    ;; during processing, we're waiting for 'confirm, in the meanwhile, we
    ;; can get a 'message or 'message-box to show -- after 'message we expect
    ;; a string to show using the `messenge' argument, and after 'message-box
    ;; we expect a string and a style-list to be used with `message-box' and
    ;; the resulting value written back
    (let ([v (read/message)])
      (unless (eq? 'confirm v) (error*-or-tryagain "submit error: ~a" v)))
    (on-commit)
    (write+flush w 'check)
    (wait-for-ok r "commit" read/message)
    (close-handin-ports h))
    )))

(define (retrieve-assignment h username passwd assignment)
  (let ([r (handin-r h)] [w (handin-w h)])
    (write+flush w
      'set 'username/s username
      'set 'password   passwd
      'set 'assignment assignment
      'get-submission)
    (let ([len (read r)])
      (unless (and (number? len) (integer? len) (positive? len))
        (error* "bad response from server: ~a" len))
      (let ([buf (begin (regexp-match #rx"[$]" r) (read-bytes len r))])
        (wait-for-ok r "get-submission")
        (close-handin-ports h)
        buf))))

(define (submit-addition h username passwd user-fields)
  (let ([r (handin-r h)] [w (handin-w h)])
    (write+flush w
      'set 'username/s  username
      'set 'password    passwd
      'set 'user-fields user-fields
      'create-user)
    (wait-for-ok r "create-user")
    (close-handin-ports h)))

(define (submit-info-change h username old-passwd new-passwd user-fields)
  (let ([r (handin-r h)]
        [w (handin-w h)])
    (write+flush w
      'set 'username/s   username
      'set 'password     old-passwd
      'set 'new-password new-passwd
      'set 'user-fields  user-fields
      'change-user-info)
    (wait-for-ok r "change-user-info")
    (close-handin-ports h)))

(define (retrieve-user-info h username passwd)
  (let ([r (handin-r h)] [w (handin-w h)])
    (write+flush w
      'set 'username/s username
      'set 'password   passwd
      'get-user-info 'bye)
    (let ([v (read r)])
      (unless (and (list? v) (andmap string? v))
        (error* "failed to get user-info list from server"))
      (wait-for-ok r "get-user-info")
      (close-handin-ports h)
      v)))
