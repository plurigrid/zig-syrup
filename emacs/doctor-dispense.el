;;; doctor-dispense.el --- M-x doctor + HERO dispenser as one system  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  bmorphism
;; SPDX-License-Identifier: Apache-2.0

;; There is ONE system. No patient. No caregiver. No nurse.
;; Conversation -> somatic extraction -> propagator cells -> belief revision ->
;; bandit arm selection -> HERO actuation. One loop. One world.

;;; Code:

(require 'doctor)
(require 'json)
(require 'url)

;; ═══════════════════════════════════════════════════════════════
;; System State — one world
;; ═══════════════════════════════════════════════════════════════

(defgroup doctor-dispense nil
  "Unified system: conversation + body + device."
  :group 'tools
  :prefix "doctor-dispense-")

(defcustom doctor-dispense-zig-syrup-dir
  (expand-file-name "~/i/zig-syrup/")
  "zig-syrup root."
  :type 'directory)

(defcustom doctor-dispense-hero-api-base
  "https://app.herohealth.com/api/v1"
  "HERO cloud API base (discovered via mitmproxy)."
  :type 'string)

(defcustom doctor-dispense-hero-token nil
  "HERO API bearer token (extracted from app traffic)."
  :type '(choice (const nil) string))

(defcustom doctor-dispense-mcp-command
  "zig-out/bin/mcp-server"
  "MCP server binary relative to zig-syrup-dir."
  :type 'string)

(defvar doctor-dispense--state
  (list
   ;; Propagator cells (partial information: nil = nothing, float = value)
   :sympathetic nil :pain nil :gi-distress nil :skin-crawling nil
   :temperature nil :sleep-quality nil :appetite nil
   :irritability nil :craving nil :anhedonia nil
   ;; Substance trajectory
   :vyvanse-mg 0 :adderall-mg 0 :caffeine-mg 0 :nicotine-mg 0
   ;; HERO
   :hero-connected nil
   :hero-cartridges
   (vector (list :slot 1  :med "clonidine"   :mg 0.1)
           (list :slot 2  :med "gabapentin"  :mg 300)
           (list :slot 3  :med "hydroxyzine" :mg 25)
           (list :slot 4  :med "magnesium"   :mg 400)
           (list :slot 5  :med "l-tyrosine"  :mg 500)
           (list :slot 6  :med "omega-3"     :mg 1000)
           (list :slot 7  :med "b-complex"   :mg 1)
           (list :slot 8  :med "melatonin"   :mg 3)
           (list :slot 9  :med nil           :mg 0)
           (list :slot 10 :med nil           :mg 0))
   ;; AGM / temporal
   :beliefs nil :history nil :phase nil :day 0)
  "The entire system. One plist.")

;; ═══════════════════════════════════════════════════════════════
;; Somatic Extraction — text -> cell updates
;; ═══════════════════════════════════════════════════════════════

(defconst doctor-dispense--somatic-patterns
  '(("can't sleep\\|insomnia\\|awake all night" :sleep-quality 0.2)
    ("sleeping.*hours\\|hypersomnia\\|can't wake" :sleep-quality 0.8)
    ("crawling\\|ants\\|formication\\|skin.*feels" :skin-crawling 0.8)
    ("heart.*racing\\|pounding\\|sweating\\|tremor" :sympathetic 0.8)
    ("calm\\|relaxed\\|steady" :sympathetic 0.2)
    ("stomach\\|nausea\\|diarrhea\\|cramp\\|gut" :gi-distress 0.7)
    ("hungry\\|starving\\|can't stop eating" :appetite 0.9)
    ("no appetite\\|can't eat" :appetite 0.1)
    ("pain\\|ache\\|hurt\\|throb\\|headache" :pain 0.7)
    ("hot.*cold\\|flash\\|chills" :temperature 0.7)
    ("irritable\\|irritat\\|snap\\|angry\\|rage" :irritability 0.8)
    ("fine\\|okay\\|better" :irritability 0.3)
    ("crav\\|want.*to use\\|urge\\|need.*hit" :craving 0.9)
    ("don't.*crave\\|no urge" :craving 0.2)
    ("nothing.*matters\\|don't care\\|numb\\|flat" :anhedonia 0.8)
    ("enjoy\\|felt good\\|laugh" :anhedonia 0.2)))

(defun doctor-dispense--extract-somatic (text)
  "Extract somatic cell values from TEXT."
  (let (result (low (downcase text)))
    (dolist (p doctor-dispense--somatic-patterns)
      (when (string-match-p (car p) low)
        (push (cons (nth 1 p) (nth 2 p)) result)))
    (nreverse result)))

(defun doctor-dispense--update-cells (extractions)
  "Update system state from EXTRACTIONS."
  (dolist (ext extractions)
    (plist-put doctor-dispense--state (car ext) (cdr ext)))
  (let ((day (plist-get doctor-dispense--state :day)))
    (plist-put doctor-dispense--state :phase
               (cond ((< day 1) :crash) ((<= day 7) :floor)
                     ((<= day 28) :dysphoria) ((<= day 180) :paws)
                     (t :stable)))))

;; ═══════════════════════════════════════════════════════════════
;; HERO Device — REST API (mitmproxy-discovered endpoints)
;; ═══════════════════════════════════════════════════════════════

;; Discovery path:
;;   mitmproxy --listen-port 8080
;;   phone wifi proxy -> <machine-ip>:8080
;;   install CA cert via mitm.it
;;   open Hero app, trigger dispense
;;   capture: POST /devices/{id}/dispense, Authorization: Bearer <tok>

(defun doctor-dispense--hero-request (method path &optional body)
  "HTTP request to HERO API."
  (when (and doctor-dispense-hero-token
             (plist-get doctor-dispense--state :hero-connected))
    (let* ((url-request-method method)
           (url-request-extra-headers
            `(("Authorization" . ,(concat "Bearer " doctor-dispense-hero-token))
              ("Content-Type" . "application/json")))
           (url-request-data (when body (json-encode body))))
      (condition-case nil
          (with-current-buffer
              (url-retrieve-synchronously
               (concat doctor-dispense-hero-api-base path) t nil 10)
            (goto-char url-http-end-of-headers)
            (json-read))
        (error nil)))))

(defun doctor-dispense-hero-dispense (slot)
  "Dispense from SLOT (1-10)."
  (interactive "nSlot (1-10): ")
  (let ((med (plist-get (aref (plist-get doctor-dispense--state :hero-cartridges)
                              (1- slot)) :med)))
    (if (null med) (message "Slot %d empty" slot)
      (doctor-dispense--hero-request "POST" "/devices/dispense"
                                     `((slot . ,slot) (quantity . 1)))
      (message "HERO: dispensed %s [slot %d]" med slot))))

(defun doctor-dispense-hero-schedule (name)
  "Dispense full scheduled dose NAME."
  (interactive (list (completing-read "Dose: "
                       '("wake" "morning" "midday" "evening" "bedtime"))))
  (let ((slots (pcase name
                 ("wake"    '(5))
                 ("morning" '(1 2 6 7))
                 ("midday"  '(1 2 3))
                 ("evening" '(6 2 3))
                 ("bedtime" '(1 3 4 8)))))
    (dolist (s slots) (doctor-dispense-hero-dispense s) (sit-for 0.3))
    (message "HERO: %s dispensed (%d meds)" name (length slots))))

(defun doctor-dispense-hero-status ()
  "Check HERO connectivity."
  (interactive)
  (if (doctor-dispense--hero-request "GET" "/devices/status")
      (progn (plist-put doctor-dispense--state :hero-connected t)
             (message "HERO: connected"))
    (plist-put doctor-dispense--state :hero-connected nil)
    (message "HERO: not connected")))

(defun doctor-dispense-set-token (tok)
  "Set HERO bearer TOK from mitmproxy capture."
  (interactive "sBearer token: ")
  (setq doctor-dispense-hero-token tok)
  (plist-put doctor-dispense--state :hero-connected t)
  (message "HERO token set."))

;; ═══════════════════════════════════════════════════════════════
;; MCP Bridge — zig-syrup tools
;; ═══════════════════════════════════════════════════════════════

(defvar doctor-dispense--mcp-proc nil)

(defun doctor-dispense--mcp-start ()
  "Start MCP server subprocess."
  (unless (and doctor-dispense--mcp-proc (process-live-p doctor-dispense--mcp-proc))
    (setq doctor-dispense--mcp-proc
          (make-process
           :name "dd-mcp" :buffer " *dd-mcp*"
           :command (list (expand-file-name doctor-dispense-mcp-command
                                            doctor-dispense-zig-syrup-dir))
           :connection-type 'pipe :noquery t))))

(defun doctor-dispense--mcp-call (method params)
  "JSON-RPC to MCP server."
  (doctor-dispense--mcp-start)
  (let ((id (random 100000)))
    (process-send-string doctor-dispense--mcp-proc
      (concat (json-encode `((jsonrpc . "2.0") (id . ,id)
                             (method . ,method) (params . ,params))) "\n"))
    (with-current-buffer (process-buffer doctor-dispense--mcp-proc)
      (let ((deadline (+ (float-time) 5.0)))
        (while (and (< (float-time) deadline)
                    (not (save-excursion (goto-char (point-min))
                           (search-forward (format "\"id\":%d" id) nil t))))
          (accept-process-output doctor-dispense--mcp-proc 0.1)))
      (goto-char (point-max))
      (beginning-of-line)
      (ignore-errors (json-read)))))

;; ═══════════════════════════════════════════════════════════════
;; Bandit — intervention selection
;; ═══════════════════════════════════════════════════════════════

(defvar doctor-dispense--arms
  (vector
   (list :id 0 :name "clonidine"    :pulls 0 :reward 0.0 :slot 1)
   (list :id 1 :name "gabapentin"   :pulls 0 :reward 0.0 :slot 2)
   (list :id 2 :name "hydroxyzine"  :pulls 0 :reward 0.0 :slot 3)
   (list :id 3 :name "magnesium"    :pulls 0 :reward 0.0 :slot 4)
   (list :id 4 :name "l-tyrosine"   :pulls 0 :reward 0.0 :slot 5)
   (list :id 5 :name "deep-breath"  :pulls 0 :reward 0.0 :slot nil)
   (list :id 6 :name "cold-water"   :pulls 0 :reward 0.0 :slot nil)
   (list :id 7 :name "walk-outside" :pulls 0 :reward 0.0 :slot nil)))

(defun doctor-dispense--bandit-select ()
  "Epsilon-greedy arm selection."
  (if (< (random 100) 10)
      (aref doctor-dispense--arms (random (length doctor-dispense--arms)))
    (let (best (best-r -1.0))
      (dotimes (i (length doctor-dispense--arms))
        (let* ((a (aref doctor-dispense--arms i))
               (p (plist-get a :pulls))
               (r (if (> p 0) (/ (plist-get a :reward) (float p)) 1.0)))
          (when (> r best-r) (setq best a best-r r))))
      best)))

(defun doctor-dispense--bandit-update (arm reward)
  "Update ARM with REWARD."
  (plist-put arm :pulls (1+ (plist-get arm :pulls)))
  (plist-put arm :reward (+ (plist-get arm :reward) reward)))

;; ═══════════════════════════════════════════════════════════════
;; Intervention Logic — sense -> decide -> actuate
;; ═══════════════════════════════════════════════════════════════

(defun doctor-dispense--should-intervene-p ()
  "True if any cell exceeds threshold."
  (cl-some (lambda (k)
             (let ((v (plist-get doctor-dispense--state k)))
               (and v (> v 0.7))))
           '(:craving :irritability :sympathetic :pain :skin-crawling)))

(defun doctor-dispense--intervene ()
  "Select and execute intervention."
  (let* ((arm (doctor-dispense--bandit-select))
         (name (plist-get arm :name))
         (slot (plist-get arm :slot))
         (msg (pcase name
                ("clonidine"    "[SYS] Clonidine 0.1mg dispensed. SNS dampening ~20min.")
                ("gabapentin"   "[SYS] Gabapentin 300mg dispensed. Nerve calming ~45min.")
                ("hydroxyzine"  "[SYS] Hydroxyzine 25mg dispensed. Anxiety relief ~30min.")
                ("magnesium"    "[SYS] Magnesium 400mg dispensed. Muscle relax ~30min.")
                ("l-tyrosine"   "[SYS] L-Tyrosine 500mg dispensed. DA precursor ~60min.")
                ("deep-breath"  "[SYS] 4-7-8 breathing. Inhale 4s, hold 7s, exhale 8s. x3.")
                ("cold-water"   "[SYS] Cold water on wrists+face. Vagal activation ~30s.")
                ("walk-outside" "[SYS] 10 min walk. Endogenous DA ~15min.")
                (_ nil))))
    (when (and slot (plist-get doctor-dispense--state :hero-connected))
      (doctor-dispense-hero-dispense slot))
    msg))

(defun doctor-dispense--after-input (input)
  "Process INPUT: extract, update, maybe intervene."
  (let ((ext (doctor-dispense--extract-somatic input)))
    (doctor-dispense--update-cells ext)
    (plist-put doctor-dispense--state :history
               (cons (list :t (float-time) :in input :ext ext)
                     (plist-get doctor-dispense--state :history)))
    (when (doctor-dispense--should-intervene-p)
      (let ((msg (doctor-dispense--intervene)))
        (when msg
          (with-current-buffer "*doctor-dispense*"
            (goto-char (point-max))
            (insert "\n" msg "\n")))))))

;; ═══════════════════════════════════════════════════════════════
;; System State Display
;; ═══════════════════════════════════════════════════════════════

(defun doctor-dispense-show-state ()
  "Display unified system state."
  (interactive)
  (with-current-buffer (get-buffer-create "*system-state*")
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert "ONE SYSTEM\n" (make-string 50 ?═) "\n\n")
      (insert (format "Phase: %s  Day %d\n\n"
                      (or (plist-get doctor-dispense--state :phase) "?")
                      (plist-get doctor-dispense--state :day)))
      (insert "Cells:\n")
      (dolist (c '(:sympathetic :pain :gi-distress :skin-crawling :temperature
                   :sleep-quality :appetite :irritability :craving :anhedonia))
        (let ((v (plist-get doctor-dispense--state c)))
          (insert (format "  %-15s %s\n" (substring (symbol-name c) 1)
                          (if v (concat (make-string (round (* v 20)) ?█)
                                        (make-string (- 20 (round (* v 20))) ?░)
                                        (format " %.1f" v))
                            "·")))))
      (insert "\nSubstances:\n")
      (dolist (s '(:vyvanse-mg :adderall-mg :caffeine-mg :nicotine-mg))
        (insert (format "  %-15s %d mg\n" (substring (symbol-name s) 1)
                        (plist-get doctor-dispense--state s))))
      (insert (format "\nHERO: %s\n"
                      (if (plist-get doctor-dispense--state :hero-connected)
                          "CONNECTED" "NOT CONNECTED")))
      (let ((carts (plist-get doctor-dispense--state :hero-cartridges)))
        (dotimes (i (length carts))
          (let ((c (aref carts i)))
            (insert (format "  %2d: %-12s %4d mg\n" (plist-get c :slot)
                            (or (plist-get c :med) "---") (plist-get c :mg))))))
      (insert "\nArms:\n")
      (dotimes (i (length doctor-dispense--arms))
        (let* ((a (aref doctor-dispense--arms i))
               (p (plist-get a :pulls))
               (r (if (> p 0) (/ (plist-get a :reward) (float p)) 0.0)))
          (insert (format "  %-12s pulls:%3d mean:%.2f %s\n"
                          (plist-get a :name) p r
                          (if (plist-get a :slot) "[HERO]" "[behav]"))))))
    (goto-char (point-min))
    (special-mode)
    (display-buffer (current-buffer))))

;; ═══════════════════════════════════════════════════════════════
;; mitmproxy launcher
;; ═══════════════════════════════════════════════════════════════

(defun doctor-dispense-start-mitm ()
  "Start mitmproxy for HERO API discovery."
  (interactive)
  (let ((buf (get-buffer-create "*hero-mitm*")))
    (display-buffer buf)
    (start-process "mitmproxy" buf "mitmproxy" "--listen-port" "8080")
    (with-current-buffer buf
      (insert "mitmproxy on :8080\n")
      (insert "Phone WiFi proxy -> this machine:8080\n")
      (insert "Install CA: http://mitm.it\n")
      (insert "Open Hero app. Capture Bearer token.\n")
      (insert "M-x doctor-dispense-set-token\n"))))

;; ═══════════════════════════════════════════════════════════════
;; Device Detection — MCP bridge to nurse_detect
;; ═══════════════════════════════════════════════════════════════

(defun doctor-dispense-detect-device ()
  "Run HERO device detection via MCP nurse_detect tool."
  (interactive)
  (let ((resp (doctor-dispense--mcp-call
               "tools/call"
               `((name . "nurse_detect")))))
    (with-current-buffer (get-buffer-create "*hero-detect*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (if resp
            (let* ((result (cdr (assq 'result resp)))
                   (content (cdr (assq 'content result)))
                   (text (cdr (assq 'text (aref content 0)))))
              (insert (or text "no response from nurse_detect")))
          (insert "MCP server not responding. Start with zig build."))
        (insert "\n\n" (make-string 50 ?─) "\n")
        (insert "Running local probes...\n\n")
        ;; Run ARP scan
        (insert "=== ARP Table ===\n")
        (insert (or (shell-command-to-string "arp -a 2>/dev/null | head -20") ""))
        (insert "\n=== mDNS Browse ===\n")
        (insert (or (shell-command-to-string
                     "timeout 3 dns-sd -B _http._tcp local 2>/dev/null || echo 'dns-sd: timed out'")
                    ""))
        (insert "\n=== Cloud Endpoint ===\n")
        (insert (or (shell-command-to-string
                     "curl -s -o /dev/null -w '%{http_code}' --max-time 5 https://app.herohealth.com/api/v1/health 2>/dev/null || echo 'unreachable'")
                    ""))
        (insert "\n"))
      (goto-char (point-min))
      (special-mode)
      (display-buffer (current-buffer))))

(defun doctor-dispense-mcp-sense (cell value)
  "Send somatic CELL VALUE via MCP nurse_sense tool."
  (interactive "sCell: \nnValue (0.0-1.0): ")
  (doctor-dispense--mcp-call
   "tools/call"
   `((name . "nurse_sense")
     (arguments . ((cell . ,cell) (value . ,value)))))
  (message "sensed %s = %.2f (MCP)" cell value))

(defun doctor-dispense-mcp-state ()
  "Get system state via MCP nurse_state tool."
  (interactive)
  (let ((resp (doctor-dispense--mcp-call "tools/call" '((name . "nurse_state")))))
    (when resp
      (let* ((result (cdr (assq 'result resp)))
             (content (cdr (assq 'content result)))
             (text (cdr (assq 'text (aref content 0)))))
        (with-current-buffer (get-buffer-create "*system-state-mcp*")
          (let ((inhibit-read-only t))
            (erase-buffer)
            (insert "ONE SYSTEM (MCP)\n" (make-string 50 ?═) "\n\n")
            (insert (or text "no state")))
          (goto-char (point-min))
          (special-mode)
          (display-buffer (current-buffer)))))))

;; ═══════════════════════════════════════════════════════════════
;; Entry Point
;; ═══════════════════════════════════════════════════════════════

(defvar doctor-dispense-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map doctor-mode-map)
    (define-key map (kbd "C-c C-s") #'doctor-dispense-show-state)
    (define-key map (kbd "C-c C-d") #'doctor-dispense-hero-schedule)
    (define-key map (kbd "C-c C-h") #'doctor-dispense-hero-status)
    (define-key map (kbd "C-c C-m") #'doctor-dispense-start-mitm)
    (define-key map (kbd "C-c C-t") #'doctor-dispense-set-token)
    (define-key map (kbd "C-c C-n") #'doctor-dispense-detect-device)
    (define-key map (kbd "C-c C-p") #'doctor-dispense-mcp-state)
    map))

(define-derived-mode doctor-dispense-mode doctor-mode "Doctor+HERO"
  "One system. Talk -> sense -> revise -> actuate."
  (advice-add 'doctor-read-print :after
              (lambda (&rest _)
                (when (eq major-mode 'doctor-dispense-mode)
                  (doctor-dispense--after-input
                   (buffer-substring-no-properties
                    (save-excursion (forward-line -2) (line-beginning-position))
                    (save-excursion (forward-line -1) (line-end-position))))))))

;;;###autoload
(defun doctor-dispense ()
  "One system. Body + substances + device + conversation.
No patient. No caregiver. No nurse. One loop.

  C-c C-s  state     C-c C-d  dispense scheduled dose
  C-c C-h  HERO      C-c C-m  mitmproxy
  C-c C-t  token     C-c C-n  detect device
  C-c C-p  MCP state"
  (interactive)
  (switch-to-buffer "*doctor-dispense*")
  (doctor-dispense-mode)
  (erase-buffer)
  (insert "One system.\n")
  (insert "Body. Substances leaving. Device. Molecules entering.\n")
  (insert "Conversation. Cells. World model. Updating.\n\n")
  (insert "Talk.\n\n"))

(provide 'doctor-dispense)
;;; doctor-dispense.el ends here
