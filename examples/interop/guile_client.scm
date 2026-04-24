;;; guile_client.scm — Connect Guile Goblins to the zig-syrup OCapN server.
;;;
;;; Usage (from inside flox activate -d /Users/bob/i):
;;;   # Terminal 1:
;;;   zig build ocapn-server
;;;   ./zig-out/bin/ocapn-server        ;; prints: "sturdy uri: ocapn://..."
;;;
;;;   # Terminal 2, paste the URI into the let-binding below, then:
;;;   guile --no-auto-compile -L /nix/store/.../guile-goblins/share/guile/site/3.0 \
;;;         examples/interop/guile_client.scm
;;;
;;; This exercises the handshake (captp-version, session-pubkey, acceptable-
;;; location, sig-envelope) and sends a single op:deliver-only to the demo
;;; sturdy. The Zig server should log:
;;;   handshake established
;;;   <- op:deliver-only (3 fields)

(use-modules (goblins)
             (goblins vat)
             (goblins actor-lib methods)
             (goblins ocapn captp)
             (goblins ocapn netlayers tcp-tls)
             (goblins ocapn ids)
             (fibers)
             (ice-9 match))

(define STURDY-URI
  ;; PASTE the "sturdy uri:" line printed by ocapn-server below:
  "ocapn://PLACEHOLDER.tcp/00000000000000000000000000000000000000000000000000000000000000")

(define (main)
  (run-fibers
   (lambda ()
     (define mycapn (spawn-mycapn (spawn-tcp-tls-netlayer)))
     (define sturdy (string->ocapn-id STURDY-URI))
     (define peer (mycapn 'resolve sturdy))
     (format #t "resolved peer: ~a~%" peer)

     ;; op:deliver-only — fire and forget.
     (<-np peer 'hello "from guile-goblins" 1069)
     (format #t "sent <-np peer hello~%")

     (sleep 1)
     (exit 0))))

(main)
