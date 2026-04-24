#lang racket/base
;; racket_echo.rkt — Square B (Zig⇄Racket) Syrup canonical-form echo.
;;
;; Reads length-prefixed Syrup frames produced by `path_invariance emit`,
;; decodes each (proving the Racket Syrup parser accepts Zig output),
;; re-encodes (proving Racket's canonical form matches), and writes the
;; result back as length-prefixed frames. Bit-equality on each frame is
;; the path-invariance witness for Square B.
;;
;; Frame format: u32 big-endian length followed by syrup payload bytes.
;;
;; Usage (with goblins package installed):
;;   raco pkg install --auto goblins
;;   racket examples/interop/racket_echo.rkt /tmp/corpus.bin /tmp/echo.bin
;;
;; Then verify with the Zig harness:
;;   ./zig-out/bin/path_invariance verify /tmp/corpus.bin /tmp/echo.bin

(require syrup
         racket/cmdline)

(define (read-u32-be in)
  (define bs (read-bytes 4 in))
  (cond
    [(eof-object? bs) eof]
    [(< (bytes-length bs) 4) (error 'read-u32-be "truncated length")]
    [else
     (+ (arithmetic-shift (bytes-ref bs 0) 24)
        (arithmetic-shift (bytes-ref bs 1) 16)
        (arithmetic-shift (bytes-ref bs 2) 8)
        (bytes-ref bs 3))]))

(define (write-u32-be n out)
  (write-bytes
   (bytes (bitwise-and (arithmetic-shift n -24) #xff)
          (bitwise-and (arithmetic-shift n -16) #xff)
          (bitwise-and (arithmetic-shift n  -8) #xff)
          (bitwise-and n #xff))
   out))

(define (read-frame in)
  (define len (read-u32-be in))
  (cond
    [(eof-object? len) eof]
    [else
     (define payload (read-bytes len in))
     (when (or (eof-object? payload) (< (bytes-length payload) len))
       (error 'read-frame "truncated payload"))
     payload]))

(define (write-frame bs out)
  (write-u32-be (bytes-length bs) out)
  (write-bytes bs out))

(define (echo-loop in out)
  (let loop ([n 0])
    (define payload (read-frame in))
    (cond
      [(eof-object? payload)
       (eprintf "racket_echo: echoed ~a frames~%" n)]
      [else
       (define value (syrup-decode payload))
       (define re (syrup-encode value))
       (write-frame re out)
       (loop (+ n 1))])))

(define (main)
  (command-line
   #:program "racket_echo"
   #:args (in-path out-path)
   (call-with-input-file in-path
     (lambda (in)
       (call-with-output-file out-path #:exists 'replace
         (lambda (out)
           (echo-loop in out)))))))

(main)
