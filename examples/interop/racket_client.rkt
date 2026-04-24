#lang racket
;; racket_client.rkt — Connect Spritely Goblins (Racket) to the zig-syrup
;; OCapN server.
;;
;; Usage (from ~/i with flox active):
;;   # Terminal 1:
;;   cd zig-syrup
;;   zig build ocapn-server
;;   ./zig-out/bin/ocapn-server        ;; prints: "sturdy uri: ocapn://..."
;;
;;   # Terminal 2, paste the URI into STURDY-URI below:
;;   raco pkg install --auto goblins   ;; first time
;;   racket examples/interop/racket_client.rkt
;;
;; Exercises handshake (captp-version, session-pubkey, acceptable-location,
;; sig-envelope) and one op:deliver-only. Zig server should log:
;;   handshake established
;;   <- op:deliver-only (3 fields)

(require goblins
         goblins/ocapn/captp
         goblins/ocapn/netlayer/tcp
         goblins/ocapn/ids)

(define STURDY-URI
  ;; PASTE the "sturdy uri:" line printed by ocapn-server below:
  "ocapn://PLACEHOLDER.tcp/00000000000000000000000000000000000000000000000000000000000000")

(define (main)
  (define vat (make-vat))
  (define mycapn (vat 'spawn ^mycapn (list (make-tcp-netlayer))))
  (define sturdy (string->ocapn-sturdyref-uri STURDY-URI))
  (define peer ($ mycapn 'resolve sturdy))
  (printf "resolved peer: ~s~%" peer)

  ;; op:deliver-only — fire and forget.
  (<-np peer 'hello "from racket-goblins" 1069)
  (printf "sent <-np peer hello~%")

  (sleep 1))

(main)
