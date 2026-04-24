;;; guile_echo.scm — Square A (Zig⇄Guile) Syrup canonical-form echo.
;;;
;;; Reads length-prefixed Syrup frames produced by `path_invariance emit`,
;;; decodes (proving the Guile syrup parser accepts Zig output), re-encodes
;;; (proving Guile's canonical form matches), writes the result back. Bit-
;;; equality on each frame is the path-invariance witness for Square A.
;;;
;;; Frame format: u32 big-endian length, then syrup payload bytes.
;;;
;;; Usage (requires Goblins' bundled `(goblins contrib syrup)` module;
;;; the runner probes that concrete namespace before invoking this witness):
;;;   guile -L <site-1> -L <site-2> --no-auto-compile \
;;;         examples/interop/guile_echo.scm \
;;;         /tmp/corpus.bin /tmp/echo.bin
;;;
;;; Note: the Babashka runner discovers candidate Guile site directories from
;;; the active Flox environment and threads them through as repeated `-L`
;;; arguments. In the current Flox environment, Square A resolves through
;;; Goblins' bundled Syrup implementation rather than a separate top-level
;;; Guile Syrup package.
;;;
;;; Then verify with the Zig harness:
;;;   ./zig-out/bin/path_invariance verify /tmp/corpus.bin /tmp/echo.bin

(use-modules (goblins contrib syrup)
             (rnrs bytevectors)
             (rnrs io ports)
             (ice-9 binary-ports))

(define (read-u32-be port)
  (let ((b0 (get-u8 port)))
    (if (eof-object? b0)
        b0
        (let ((b1 (get-u8 port))
              (b2 (get-u8 port))
              (b3 (get-u8 port)))
          (when (or (eof-object? b1) (eof-object? b2) (eof-object? b3))
            (error "truncated length"))
          (+ (* b0 16777216) (* b1 65536) (* b2 256) b3)))))

(define (write-u32-be n port)
  (put-u8 port (logand (ash n -24) #xff))
  (put-u8 port (logand (ash n -16) #xff))
  (put-u8 port (logand (ash n  -8) #xff))
  (put-u8 port (logand n #xff)))

(define (read-frame port)
  (let ((len (read-u32-be port)))
    (if (eof-object? len)
        len
        (let ((bv (get-bytevector-n port len)))
          (when (or (eof-object? bv) (< (bytevector-length bv) len))
            (error "truncated payload"))
          bv))))

(define (write-frame bv port)
  (write-u32-be (bytevector-length bv) port)
  (put-bytevector port bv))

(define (echo-loop in out)
  (let loop ((n 0))
    (let ((payload (read-frame in)))
      (cond
       ((eof-object? payload)
        (format (current-error-port) "guile_echo: echoed ~a frames~%" n))
       (else
        (let* ((value (syrup-decode payload))
               (re    (syrup-encode value)))
          (write-frame re out)
          (loop (+ n 1))))))))

(define (main args)
  (when (< (length args) 3)
    (error "usage: guile_echo.scm <in> <out>"))
  (let ((in-path (cadr args))
        (out-path (caddr args)))
    (call-with-input-file in-path
      (lambda (in)
        (call-with-output-file out-path
          (lambda (out)
            (echo-loop in out)))))))

(main (command-line))
