;;; gay-tt.el --- gay × trit-tick: one clock, one color, one stream  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  bmorphism
;; SPDX-License-Identifier: Apache-2.0

;; One timer. One mode-line. One NATS publish.
;; trit-tick's immer chain is the clock.
;; gay's LCH pipeline is the color.
;; Each second: advance chain, derive color, publish, display.

;;; Code:

(require 'trit-tick-clock)

;; ── NATS publisher (raw TCP, no babashka) ──

(defvar gay-tt--nats-proc nil "Direct NATS TCP connection for publishing.")
(defvar gay-tt--nats-info nil "Server INFO plist from CONNECT handshake.")

(defun gay-tt--nats-connect ()
  "Open raw TCP to NATS for publishing. Returns process or nil."
  (condition-case err
      (let* ((host (or (bound-and-true-p gay-nats-server) "nonlocal.info"))
             (port (or (bound-and-true-p gay-nats-port) 4222))
             (proc (open-network-stream "gay-tt-nats" " *gay-tt-nats*"
                                        host port :nowait nil)))
        (set-process-coding-system proc 'utf-8 'utf-8)
        (set-process-query-on-exit-flag proc nil)
        ;; read INFO line
        (accept-process-output proc 3)
        (with-current-buffer (process-buffer proc)
          (goto-char (point-min))
          (when (search-forward "INFO " nil t)
            (let ((json-end (line-end-position)))
              (ignore-errors
                (setq gay-tt--nats-info
                      (json-parse-string
                       (buffer-substring (point) json-end)
                       :object-type 'plist))))))
        ;; CONNECT + PING
        (process-send-string proc
          (concat "CONNECT {\"lang\":\"elisp\",\"name\":\"gay-tt\",\"protocol\":1,\"verbose\":false}\r\n"
                  "PING\r\n"))
        (accept-process-output proc 2)
        ;; keepalive: respond to server PINGs
        (set-process-filter proc
          (lambda (_p out)
            (when (string-match-p "PING" out)
              (ignore-errors
                (process-send-string _p "PONG\r\n")))))
        proc)
    (error
     (message "[gay×tt] NATS connect failed: %s" (error-message-string err))
     nil)))

(defun gay-tt--nats-pub (subject payload)
  "Publish PAYLOAD string to SUBJECT on the NATS connection."
  (when (and gay-tt--nats-proc (process-live-p gay-tt--nats-proc))
    (let ((msg (encode-coding-string payload 'utf-8)))
      (ignore-errors
        (process-send-string gay-tt--nats-proc
          (format "PUB %s %d\r\n%s\r\n" subject (length msg) msg))))))

(defun gay-tt--nats-disconnect ()
  "Close the NATS publisher connection."
  (when (and gay-tt--nats-proc (process-live-p gay-tt--nats-proc))
    (delete-process gay-tt--nats-proc))
  (setq gay-tt--nats-proc nil))

;; ── Unified mode-line ──

(defvar gay-tt--mode-line-string "" "Combined gay×trit-tick mode-line.")
(defvar gay-tt--timer nil "The single 1Hz timer.")

(defun gay-tt--update ()
  "One tick: advance immer chain, derive LCH color, publish, display."
  (let* ((state (tt--advance))
         (trit (tt-state-gf3-trit state))
         (hue (tt-state-hue-degree state))
         (secs (truncate (tt-state-epoch-seconds state)))
         (ticks-in-sec (mod (tt-state-ticks state) tt-ticks-per-second))
         ;; gay's LCH pipeline when available, else trit-tick's RGB
         (gay-color (when (fboundp 'gay-color-at)
                      (ignore-errors (gay-color-at gay-seed (mod secs 360)))))
         (hex (or (and gay-color (plist-get gay-color :hex))
                  (tt-state-color-hex state)))
         (trit-str (propertize (tt-trit-char trit) 'face (tt-trit-face trit)))
         (swatch (propertize "  " 'face `(:background ,hex)))
         (fg (if gay-color
                 (gay--fg-for-bg hex)
               (if (> (tt-state-hue-degree state) 180) "#000000" "#FFFFFF"))))
    ;; mode-line: [swatch] tt:ticks trit hue
    (setq gay-tt--mode-line-string
          (concat " " swatch
                  (propertize (format " %d" ticks-in-sec)
                              'face `(:foreground "#888888" :weight light))
                  trit-str
                  (propertize (format "h%d " hue)
                              'face '(:foreground "#666666"))))
    ;; feed gay's internal state so gay-color-update-hook fires
    (when (boundp 'gay--current-color)
      (let ((plist (list :hex hex :trit trit :hue hue
                         :state (symbol-name (tt-state-gf3-phase state))
                         :epoch (tt-state-version state))))
        (setq gay--previous-color gay--current-color)
        (setq gay--current-color plist)
        (setq gay--update-count (1+ gay--update-count))
        (run-hook-with-args 'gay-color-update-hook plist)))
    ;; publish to NATS
    (gay-tt--nats-pub "ies.a.tt.state"
      (format "{\"v\":%d,\"tick\":%d,\"trit\":%d,\"hue\":%d,\"hex\":\"%s\",\"hash\":\"%.16s\",\"phase\":\"%s\"}"
              (tt-state-version state)
              ticks-in-sec trit hue hex
              (tt-state-hash state)
              (tt-state-gf3-phase state)))
    (force-mode-line-update t)))

;; ── Lifecycle ──

;;;###autoload
(defun gay-tt-start ()
  "Start unified gay×trit-tick. One timer, one mode-line, one NATS stream."
  (interactive)
  ;; tear down any separate timers
  (when (bound-and-true-p tt--timer)
    (cancel-timer tt--timer) (setq tt--timer nil))
  (when gay-tt--timer
    (cancel-timer gay-tt--timer) (setq gay-tt--timer nil))
  ;; reset chain
  (setq tt--state-chain nil tt--state-version 0)
  ;; NATS publisher
  (gay-tt--nats-disconnect)
  (setq gay-tt--nats-proc (gay-tt--nats-connect))
  ;; also start gay's subscriber if available and not running
  (when (and (fboundp 'gay--make-process)
             (boundp 'gay--process)
             (or (not gay--process) (not (process-live-p gay--process))))
    (ignore-errors (setq gay--process (gay--make-process))))
  ;; single combined mode-line entry
  (setq global-mode-string
        (seq-remove (lambda (x) (memq x '(tt--mode-line-string
                                           gay-mode-line-string
                                           gay-tt--mode-line-string)))
                    global-mode-string))
  (push 'gay-tt--mode-line-string global-mode-string)
  ;; one timer
  (gay-tt--update)
  (setq gay-tt--timer (run-at-time 1 1 #'gay-tt--update))
  (message "gay×tt: seed %d | 141,120,000 Hz | NATS %s:%s %s"
           (or (bound-and-true-p gay-seed) 42)
           (or (bound-and-true-p gay-nats-server) "?")
           (or (bound-and-true-p gay-nats-port) "?")
           (if gay-tt--nats-proc "connected" "offline")))

(defun gay-tt-stop ()
  "Stop the unified clock."
  (interactive)
  (when gay-tt--timer
    (cancel-timer gay-tt--timer) (setq gay-tt--timer nil))
  (gay-tt--nats-disconnect)
  (setq global-mode-string
        (delq 'gay-tt--mode-line-string global-mode-string))
  (force-mode-line-update t)
  (message "gay×tt stopped (%d states in chain)" (length tt--state-chain)))

(defun gay-tt-status ()
  "Show unified status."
  (interactive)
  (let* ((chain-len (length tt--state-chain))
         (head (car tt--state-chain))
         (nats-ok (and gay-tt--nats-proc (process-live-p gay-tt--nats-proc)))
         (gay-ok (and (boundp 'gay--process) gay--process
                      (process-live-p gay--process))))
    (message "gay×tt: chain=%d v=%s trit=%s nats-pub=%s nats-sub=%s seed=%s"
             chain-len
             (if head (tt-state-version head) "-")
             (if head (tt-trit-char (tt-state-gf3-trit head)) "?")
             (if nats-ok "up" "down")
             (if gay-ok "up" "down")
             (or (bound-and-true-p gay-seed) "?"))))

;; ── Keymap (C-c C-t prefix, replaces both) ──

(defvar gay-tt-command-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "s") #'gay-tt-start)
    (define-key map (kbd "q") #'gay-tt-stop)
    (define-key map (kbd "?") #'gay-tt-status)
    (define-key map (kbd "c") #'tt-show-clock)
    (define-key map (kbd "e") #'tt-show-scenarios)
    (define-key map (kbd "g") #'tt-conservation-report)
    (define-key map (kbd "m") #'tt-mcp-start)
    map)
  "C-c C-t keymap: s=start q=stop ?=status c=clock e=entropy g=conservation m=mcp")

(global-set-key (kbd "C-c C-t") gay-tt-command-map)

(provide 'gay-tt)
;;; gay-tt.el ends here
