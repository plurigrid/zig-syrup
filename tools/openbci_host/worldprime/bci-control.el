;;; bci-control.el --- Bidirectional BCI robot/drone control buffer -*- lexical-binding: t -*-

;; Author: Plurigrid
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (url "1.0"))
;; Keywords: bci, robotics, drone, control

;;; Commentary:

;; Provides a bidirectional Emacs interface for BCI-driven robot and drone
;; control.  Subscribes to SSE/Braid-HTTP streams for telemetry display
;; and sends motor intention commands back through the active inference loop.
;;
;; Architecture:
;;   EEG → BCI pipeline → SSE :7070 → this buffer (display)
;;   this buffer (commands) → HTTP POST :7071 → active inference → robot/drone
;;
;; GF(3) trit mode selection:
;;   -1 = OBSERVE  (loiter/stabilize, read-only telemetry)
;;    0 = COORDINATE (guided, shared control with AI)
;;   +1 = GENERATE  (manual, direct BCI-to-actuator)
;;
;; Keybindings:
;;   SPC     Toggle pause/resume telemetry stream
;;   1/2/3   Switch trit mode: observe/coordinate/generate
;;   a       Arm motors
;;   d       Disarm motors
;;   t       Takeoff (prompts altitude)
;;   l       Land
;;   r       Return to launch
;;   g       Go to guided mode
;;   q       Quit control buffer
;;   C-c C-a Toggle ARC-AGI overlay (grid puzzle visualization)

;;; Code:

(require 'url)
(require 'json)

;; ============================================================================
;; Customization
;; ============================================================================

(defgroup bci-control nil
  "BCI robot/drone control interface."
  :group 'tools
  :prefix "bci-control-")

(defcustom bci-control-sse-url "http://localhost:7070/events"
  "SSE endpoint for BCI telemetry stream."
  :type 'string)

(defcustom bci-control-command-url "http://localhost:7071/command"
  "HTTP POST endpoint for motor intention commands."
  :type 'string)

(defcustom bci-control-braid-url nil
  "Braid-HTTP endpoint for versioned state sync.
When non-nil, uses Braid subscription instead of plain SSE."
  :type '(choice (const nil) string))

(defcustom bci-control-refresh-rate 0.1
  "Telemetry display refresh interval in seconds."
  :type 'number)

;; ============================================================================
;; State
;; ============================================================================

(defvar-local bci-control--trit 0
  "Current GF(3) control trit: -1=observe, 0=coordinate, +1=generate.")

(defvar-local bci-control--armed nil
  "Whether motors are armed.")

(defvar-local bci-control--mode "stabilize"
  "Current flight/robot mode.")

(defvar-local bci-control--attitude nil
  "Current attitude plist (:roll :pitch :yaw :rollspeed :pitchspeed :yawspeed).")

(defvar-local bci-control--position nil
  "Current position plist (:lat :lon :alt :relative-alt :vx :vy :vz :hdg).")

(defvar-local bci-control--bci nil
  "Current BCI state plist (:phi :valence :trit :fisher :color).")

(defvar-local bci-control--battery -1
  "Battery remaining (0-100, -1 unknown).")

(defvar-local bci-control--paused nil
  "Whether telemetry stream is paused.")

(defvar-local bci-control--stream-process nil
  "The SSE stream process.")

(defvar-local bci-control--refresh-timer nil
  "Timer for display refresh.")

(defvar-local bci-control--telemetry-log nil
  "Ring buffer of recent telemetry frames for sparkline rendering.")

(defvar-local bci-control--arc-agi-overlay nil
  "Whether ARC-AGI grid overlay is active.")

;; ============================================================================
;; Faces
;; ============================================================================

(defface bci-control-trit-minus
  '((t :foreground "#9B59B6" :weight bold))
  "Face for trit -1 (observe/validate).")

(defface bci-control-trit-zero
  '((t :foreground "#3498DB" :weight bold))
  "Face for trit 0 (coordinate).")

(defface bci-control-trit-plus
  '((t :foreground "#E74C3C" :weight bold))
  "Face for trit +1 (generate).")

(defface bci-control-armed
  '((t :foreground "#E74C3C" :weight bold))
  "Face for armed state.")

(defface bci-control-disarmed
  '((t :foreground "#2ECC71" :weight bold))
  "Face for disarmed state.")

(defface bci-control-header
  '((t :foreground "#F39C12" :weight bold :height 1.1))
  "Face for section headers.")

(defface bci-control-value
  '((t :foreground "#ECF0F1"))
  "Face for telemetry values.")

(defface bci-control-label
  '((t :foreground "#7F8C8D"))
  "Face for telemetry labels.")

;; ============================================================================
;; Trit mode display
;; ============================================================================

(defun bci-control--trit-string ()
  "Return display string for current trit mode."
  (pcase bci-control--trit
    (-1 (propertize "[-1] OBSERVE" 'face 'bci-control-trit-minus))
    (0  (propertize "[ 0] COORDINATE" 'face 'bci-control-trit-zero))
    (1  (propertize "[+1] GENERATE" 'face 'bci-control-trit-plus))))

(defun bci-control--sparkline (values width)
  "Render VALUES as a Unicode sparkline of WIDTH characters."
  (let* ((chars "▁▂▃▄▅▆▇█")
         (min-v (apply #'min values))
         (max-v (apply #'max values))
         (range (max (- max-v min-v) 0.001))
         (recent (last values width)))
    (mapconcat
     (lambda (v)
       (let ((idx (min 7 (floor (* (/ (- v min-v) range) 7.9)))))
         (string (aref chars idx))))
     recent "")))

;; ============================================================================
;; Display rendering
;; ============================================================================

(defun bci-control--render ()
  "Render the control buffer contents."
  (when (and (not bci-control--paused)
             (eq major-mode 'bci-control-mode))
    (let ((inhibit-read-only t)
          (pos (point)))
      (erase-buffer)
      (insert
       (propertize "╔══════════════════════════════════════════════╗\n" 'face 'bci-control-header)
       (propertize "║  BCI Universal Control Interface             ║\n" 'face 'bci-control-header)
       (propertize "╚══════════════════════════════════════════════╝\n" 'face 'bci-control-header)
       "\n"
       ;; Trit mode
       (propertize " MODE: " 'face 'bci-control-label)
       (bci-control--trit-string)
       "  "
       (propertize (format "FLIGHT: %s" (upcase (or bci-control--mode "?"))) 'face 'bci-control-value)
       "  "
       (if bci-control--armed
           (propertize "ARMED" 'face 'bci-control-armed)
         (propertize "DISARMED" 'face 'bci-control-disarmed))
       "\n\n"

       ;; BCI state
       (propertize " ── BCI ──────────────────────────────────────\n" 'face 'bci-control-header))

      (if bci-control--bci
          (let-alist bci-control--bci
            (insert
             (format "  Φ (integration): %6.2f    Valence: %+.3f\n"
                     (or (plist-get bci-control--bci :phi) 0.0)
                     (or (plist-get bci-control--bci :valence) 0.0))
             (format "  Fisher-Rao:      %6.2f    Trit:    %+d\n"
                     (or (plist-get bci-control--bci :fisher) 0.0)
                     (or (plist-get bci-control--bci :trit) 0))
             (format "  Color: %s\n"
                     (or (plist-get bci-control--bci :color) "#000000"))))
        (insert "  (awaiting BCI stream...)\n"))

      (insert
       "\n"
       (propertize " ── ATTITUDE ─────────────────────────────────\n" 'face 'bci-control-header))

      (if bci-control--attitude
          (insert
           (format "  Roll:  %+7.2f°  (%+.2f°/s)\n"
                   (* (or (plist-get bci-control--attitude :roll) 0) (/ 180.0 float-pi))
                   (* (or (plist-get bci-control--attitude :rollspeed) 0) (/ 180.0 float-pi)))
           (format "  Pitch: %+7.2f°  (%+.2f°/s)\n"
                   (* (or (plist-get bci-control--attitude :pitch) 0) (/ 180.0 float-pi))
                   (* (or (plist-get bci-control--attitude :pitchspeed) 0) (/ 180.0 float-pi)))
           (format "  Yaw:   %+7.2f°  (%+.2f°/s)\n"
                   (* (or (plist-get bci-control--attitude :yaw) 0) (/ 180.0 float-pi))
                   (* (or (plist-get bci-control--attitude :yawspeed) 0) (/ 180.0 float-pi))))
        (insert "  (awaiting attitude data...)\n"))

      (insert
       "\n"
       (propertize " ── POSITION ─────────────────────────────────\n" 'face 'bci-control-header))

      (if bci-control--position
          (insert
           (format "  Lat: %.7f  Lon: %.7f\n"
                   (/ (or (plist-get bci-control--position :lat) 0) 1e7)
                   (/ (or (plist-get bci-control--position :lon) 0) 1e7))
           (format "  Alt: %.1fm MSL  Rel: %.1fm AGL\n"
                   (/ (or (plist-get bci-control--position :alt) 0) 1000.0)
                   (/ (or (plist-get bci-control--position :relative-alt) 0) 1000.0))
           (format "  Vel: [%.1f, %.1f, %.1f] cm/s  Hdg: %.1f°\n"
                   (or (plist-get bci-control--position :vx) 0.0)
                   (or (plist-get bci-control--position :vy) 0.0)
                   (or (plist-get bci-control--position :vz) 0.0)
                   (/ (or (plist-get bci-control--position :hdg) 0) 100.0)))
        (insert "  (awaiting GPS fix...)\n"))

      (insert
       "\n"
       (propertize " ── SYSTEM ───────────────────────────────────\n" 'face 'bci-control-header)
       (format "  Battery: %s%%\n"
               (if (< bci-control--battery 0) "??"
                 (number-to-string bci-control--battery))))

      ;; Sparkline for phi history
      (when bci-control--telemetry-log
        (insert
         "\n"
         (propertize " ── Φ HISTORY " 'face 'bci-control-header)
         (bci-control--sparkline bci-control--telemetry-log 40)
         "\n"))

      ;; ARC-AGI overlay
      (when bci-control--arc-agi-overlay
        (insert
         "\n"
         (propertize " ── ARC-AGI ──────────────────────────────────\n" 'face 'bci-control-header)
         "  (grid puzzle overlay active)\n"
         "  Trit → grid op: -1=erase  0=observe  +1=fill\n"))

      (insert
       "\n"
       (propertize " ── KEYS ─────────────────────────────────────\n" 'face 'bci-control-label)
       "  1/2/3  trit mode    a/d  arm/disarm\n"
       "  t      takeoff      l    land        r  RTL\n"
       "  SPC    pause        g    guided      q  quit\n"
       "  C-c C-a  ARC-AGI overlay toggle\n")

      (goto-char (min pos (point-max))))))

;; ============================================================================
;; SSE stream handling
;; ============================================================================

(defun bci-control--parse-sse-line (line)
  "Parse a single SSE data LINE and update state."
  (when (string-prefix-p "data: " line)
    (condition-case nil
        (let ((json-object-type 'plist)
              (data (json-read-from-string (substring line 6))))
          ;; Update BCI state
          (when (plist-get data :phi)
            (setq bci-control--bci data)
            ;; Append to history ring
            (push (plist-get data :phi)
                  bci-control--telemetry-log)
            (when (> (length bci-control--telemetry-log) 200)
              (setq bci-control--telemetry-log
                    (seq-take bci-control--telemetry-log 200))))

          ;; Update attitude
          (when (plist-get data :roll)
            (setq bci-control--attitude data))

          ;; Update position
          (when (plist-get data :lat)
            (setq bci-control--position data))

          ;; Update system
          (when (plist-get data :battery_remaining)
            (setq bci-control--battery (plist-get data :battery_remaining)))
          (when (plist-get data :armed)
            (setq bci-control--armed (plist-get data :armed)))
          (when (plist-get data :mode)
            (setq bci-control--mode (plist-get data :mode))))
      (error nil))))

(defun bci-control--start-stream ()
  "Start SSE telemetry stream."
  (let* ((url (or bci-control-braid-url bci-control-sse-url))
         (buf (generate-new-buffer " *bci-sse*")))
    (setq bci-control--stream-process
          (make-process
           :name "bci-sse-stream"
           :buffer buf
           :command (if bci-control-braid-url
                        (list "curl" "-sN"
                              "-H" "Subscribe: true"
                              "-H" "Accept: text/event-stream"
                              url)
                      (list "curl" "-sN" url))
           :filter (lambda (_proc output)
                     (dolist (line (split-string output "\n" t))
                       (bci-control--parse-sse-line line)))
           :sentinel (lambda (_proc _event) nil)))))

(defun bci-control--stop-stream ()
  "Stop SSE telemetry stream."
  (when (and bci-control--stream-process
             (process-live-p bci-control--stream-process))
    (delete-process bci-control--stream-process)
    (setq bci-control--stream-process nil)))

;; ============================================================================
;; Command sending
;; ============================================================================

(defun bci-control--send-command (cmd &optional params)
  "Send CMD with optional PARAMS plist to control endpoint."
  (let ((url-request-method "POST")
        (url-request-extra-headers '(("Content-Type" . "application/json")))
        (url-request-data
         (json-encode `(:command ,cmd :trit ,bci-control--trit ,@(or params nil)))))
    (url-retrieve-synchronously bci-control-command-url t t 2)))

;; ============================================================================
;; Interactive commands
;; ============================================================================

(defun bci-control-set-trit (trit)
  "Set control TRIT mode (-1, 0, or +1)."
  (interactive "nTrit (-1/0/1): ")
  (setq bci-control--trit (max -1 (min 1 trit)))
  (bci-control--send-command "set_trit" `(:value ,bci-control--trit))
  (message "Trit mode: %s" (bci-control--trit-string)))

(defun bci-control-observe ()
  "Set trit to -1 (observe/validate)."
  (interactive)
  (bci-control-set-trit -1))

(defun bci-control-coordinate ()
  "Set trit to 0 (coordinate/guided)."
  (interactive)
  (bci-control-set-trit 0))

(defun bci-control-generate ()
  "Set trit to +1 (generate/manual)."
  (interactive)
  (bci-control-set-trit 1))

(defun bci-control-arm ()
  "Arm motors."
  (interactive)
  (when (yes-or-no-p "ARM motors? ")
    (bci-control--send-command "arm")
    (setq bci-control--armed t)))

(defun bci-control-disarm ()
  "Disarm motors."
  (interactive)
  (bci-control--send-command "disarm")
  (setq bci-control--armed nil))

(defun bci-control-takeoff ()
  "Takeoff to specified altitude."
  (interactive)
  (let ((alt (read-number "Takeoff altitude (m): " 2.0)))
    (bci-control--send-command "takeoff" `(:altitude ,alt))))

(defun bci-control-land ()
  "Land at current position."
  (interactive)
  (bci-control--send-command "land"))

(defun bci-control-rtl ()
  "Return to launch."
  (interactive)
  (when (yes-or-no-p "Return to launch? ")
    (bci-control--send-command "rtl")))

(defun bci-control-guided ()
  "Switch to guided mode."
  (interactive)
  (bci-control--send-command "set_mode" '(:mode "guided")))

(defun bci-control-toggle-pause ()
  "Toggle telemetry stream pause."
  (interactive)
  (setq bci-control--paused (not bci-control--paused))
  (message (if bci-control--paused "Telemetry PAUSED" "Telemetry RESUMED")))

(defun bci-control-toggle-arc-agi ()
  "Toggle ARC-AGI grid overlay."
  (interactive)
  (setq bci-control--arc-agi-overlay (not bci-control--arc-agi-overlay))
  (message (if bci-control--arc-agi-overlay "ARC-AGI overlay ON" "ARC-AGI overlay OFF")))

;; ============================================================================
;; Major mode
;; ============================================================================

(defvar bci-control-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "1") #'bci-control-observe)
    (define-key map (kbd "2") #'bci-control-coordinate)
    (define-key map (kbd "3") #'bci-control-generate)
    (define-key map (kbd "a") #'bci-control-arm)
    (define-key map (kbd "d") #'bci-control-disarm)
    (define-key map (kbd "t") #'bci-control-takeoff)
    (define-key map (kbd "l") #'bci-control-land)
    (define-key map (kbd "r") #'bci-control-rtl)
    (define-key map (kbd "g") #'bci-control-guided)
    (define-key map (kbd "SPC") #'bci-control-toggle-pause)
    (define-key map (kbd "q") #'bci-control-quit)
    (define-key map (kbd "C-c C-a") #'bci-control-toggle-arc-agi)
    map)
  "Keymap for `bci-control-mode'.")

(define-derived-mode bci-control-mode special-mode "BCI-Ctrl"
  "Major mode for BCI robot/drone control.

\\{bci-control-mode-map}"
  (setq-local bci-control--telemetry-log nil)
  (setq-local bci-control--paused nil)
  (setq-local bci-control--trit 0)
  (setq buffer-read-only t)
  (setq-local revert-buffer-function #'bci-control--render)

  ;; Start SSE stream
  (bci-control--start-stream)

  ;; Start refresh timer
  (setq bci-control--refresh-timer
        (run-with-timer 0 bci-control-refresh-rate #'bci-control--render)))

(defun bci-control-quit ()
  "Quit BCI control buffer."
  (interactive)
  (bci-control--stop-stream)
  (when bci-control--refresh-timer
    (cancel-timer bci-control--refresh-timer))
  (kill-buffer))

;;;###autoload
(defun bci-control ()
  "Open BCI universal control interface."
  (interactive)
  (let ((buf (get-buffer-create "*BCI Control*")))
    (switch-to-buffer buf)
    (unless (eq major-mode 'bci-control-mode)
      (bci-control-mode))))

(provide 'bci-control)
;;; bci-control.el ends here
