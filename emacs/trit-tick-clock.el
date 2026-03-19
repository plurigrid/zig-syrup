;;; trit-tick-clock.el --- TritTick clock for Emacs via zig-syrup  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  bmorphism
;; SPDX-License-Identifier: Apache-2.0

;; Derives from:
;;   jank-lang:  crdt_sexp_ewig.jank — immutable state transitions, SplitMix64 color
;;   flicks:     Facebook 705,600,000/s — via trit_tick.zig (1 trit-tick = 5 flicks)
;;   immer:      immer_ops.nu — persistent data with structural sharing (parent hash chain)
;;   zig-syrup:  trit_tick.zig — canonical time base, MCP bridge

;;; Commentary:

;; 141,120,000 = 2^9 * 3^2 * 5^4 * 7^2
;;
;; The universal time quantum. Divides every BCI, audio, video, and
;; color-entropy rate exactly. 1 trit-tick = 5 flicks = 1 Unity tick.
;;
;; The clock maintains an immer-style persistent state chain:
;; each tick produces a new immutable snapshot linked to its parent
;; via content hash. No mutation — only consing new states.
;;
;; GF(3) phase rotates every second: +1 -> 0 -> -1 -> +1 ...
;; The trit IS the time. The color IS the phase.

;;; Code:

(require 'cl-lib)

;; ── Constants (from trit_tick.zig) ──

(defconst tt-ticks-per-second 141120000
  "Trit-ticks per second. 2^9 * 3^2 * 5^4 * 7^2.")

(defconst tt-flicks-per-tick 5
  "1 trit-tick = 5 flicks (Facebook, 2017).")

(defconst tt-flicks-per-second 705600000
  "705,600,000 flicks/s = 141,120,000 * 5.")

(defconst tt-gf3-quantum (/ tt-ticks-per-second 3)
  "47,040,000 trit-ticks per GF(3) conservation cycle.")

(defconst tt-band-quantum (/ tt-ticks-per-second 5)
  "28,224,000 trit-ticks per EEG band quantum.")

(defconst tt-hue-quantum (/ tt-ticks-per-second 360)
  "392,000 trit-ticks per hue degree.")

(defconst tt-modalities
  '((eeg        . 250)
    (ultrasound . 100)
    (emg        . 500)
    (ecog       . 2000)
    (fnirs      . 10))
  "BCI modality sample rates (all divide 141,120,000 exactly).")

;; ── SplitMix64 (from crdt_sexp_ewig.jank, matches Gay.jl) ──

(defconst tt-golden-gamma #x9e3779b97f4a7c15)
(defconst tt-mix1 #xbf58476d1ce4e5b9)
(defconst tt-mix2 #x94d049bb133111eb)

(defun tt--u64 (n)
  "Mask N to unsigned 64-bit."
  (logand n #xFFFFFFFFFFFFFFFF))

(defun tt--mix64 (z)
  "SplitMix64 finalizer."
  (setq z (tt--u64 (* (logxor z (ash z -30)) tt-mix1)))
  (setq z (tt--u64 (* (logxor z (ash z -27)) tt-mix2)))
  (logxor z (ash z -31)))

(defun tt-color-at (seed index)
  "Deterministic color from SEED at INDEX. Returns (R G B) bytes."
  (let ((state (tt--u64 seed)))
    (dotimes (_ (1+ index))
      (setq state (tt--u64 (+ state tt-golden-gamma))))
    (let ((z (tt--mix64 state)))
      (list (logand (ash z -40) #xFF)
            (logand (ash z -24) #xFF)
            (logand (ash z -8) #xFF)))))

(defun tt-color-hex (seed index)
  "Return #RRGGBB hex string for SEED at INDEX."
  (apply #'format "#%02X%02X%02X" (tt-color-at seed index)))

;; ── GF(3) trit ──

(defun tt-trit (value)
  "Map VALUE to balanced ternary {-1, 0, +1}."
  (let ((m (mod value 3)))
    (pcase m (0 0) (1 1) (2 -1))))

(defun tt-trit-char (trit)
  "Display character for TRIT."
  (pcase trit (+1 "+") (0 "o") (-1 "-")))

(defun tt-trit-face (trit)
  "Face for TRIT value."
  (pcase trit
    (+1 '(:foreground "#00FF88" :weight bold))
    (0  '(:foreground "#FFDD00"))
    (-1 '(:foreground "#FF4466" :weight bold))))

;; ── Immer-style persistent state (from immer_ops.nu + jank EwigState) ──

(defvar tt--state-chain nil
  "Persistent state chain. Head is current. Each links to parent via :parent-hash.
Immer invariant: states are never mutated, only consed.")

(defvar tt--state-version 0
  "Monotonic version counter.")

(cl-defstruct (tt-state (:constructor tt-state--make))
  "Immutable clock state snapshot. Linked list via parent-hash."
  version          ; monotonic
  ticks            ; i64 trit-ticks since epoch
  flicks           ; ticks * 5
  epoch-seconds    ; float-time
  gf3-trit         ; current second's trit {-1, 0, +1}
  gf3-phase        ; :plus :ergodic :minus
  hue-degree       ; current hue rotation (0-359)
  color-hex        ; SplitMix64 color for current second
  modality-sample  ; plist of (modality . sample-count) at this instant
  hash             ; SHA-1 of content (structural sharing key)
  parent-hash)     ; hash of previous state (immer chain)

(defun tt--content-hash (ticks trit hue)
  "Quick content hash for structural sharing detection."
  (secure-hash 'sha1 (format "%d:%d:%d" ticks trit hue) nil nil t))

(defun tt--make-state (epoch-seconds)
  "Create immutable state snapshot for EPOCH-SECONDS.
Never mutates — returns a fresh struct linked to the chain head."
  (let* ((ticks (truncate (* epoch-seconds tt-ticks-per-second)))
         (secs (truncate epoch-seconds))
         (trit (tt-trit secs))
         (phase (pcase trit (+1 :plus) (0 :ergodic) (-1 :minus)))
         (hue (mod (/ ticks tt-hue-quantum) 360))
         (color (tt-color-hex secs 0))
         (modalities
          (mapcar (lambda (m)
                    (cons (car m) (/ ticks (/ tt-ticks-per-second (cdr m)))))
                  tt-modalities))
         (hash (tt--content-hash ticks trit hue))
         (parent-hash (when tt--state-chain
                        (tt-state-hash (car tt--state-chain))))
         (version (cl-incf tt--state-version)))
    (tt-state--make
     :version version
     :ticks ticks
     :flicks (* ticks tt-flicks-per-tick)
     :epoch-seconds epoch-seconds
     :gf3-trit trit
     :gf3-phase phase
     :hue-degree hue
     :color-hex color
     :modality-sample modalities
     :hash hash
     :parent-hash parent-hash)))

(defun tt--advance ()
  "Cons a new immutable state onto the chain. Returns the new head.
The old chain is preserved — structural sharing via hash linkage."
  (let ((new-state (tt--make-state (float-time))))
    (push new-state tt--state-chain)
    ;; Prune chain to last 120 states (~2 min at 1Hz) to bound memory
    ;; but keep the hash chain intact for ancestry queries
    (when (> (length tt--state-chain) 120)
      (setcdr (nthcdr 119 tt--state-chain) nil))
    new-state))

;; ── MCP bridge to zig-syrup ──

(defcustom tt-zig-syrup-dir
  (expand-file-name "~/i/zig-syrup/")
  "Path to zig-syrup project root."
  :type 'directory
  :group 'trit-tick-clock)

(defvar tt--mcp-proc nil
  "MCP server process for canonical trit-tick computation.")

(defun tt-mcp-start ()
  "Start zig-syrup MCP server for trit-tick queries."
  (interactive)
  (unless (and tt--mcp-proc (process-live-p tt--mcp-proc))
    (let ((cmd (expand-file-name "zig-out/bin/mcp-server" tt-zig-syrup-dir)))
      (when (file-executable-p cmd)
        (setq tt--mcp-proc
              (make-process
               :name "tt-mcp" :buffer " *tt-mcp*"
               :command (list cmd)
               :connection-type 'pipe :noquery t))
        (message "trit-tick: MCP bridge started")))))

(defun tt-mcp-stop ()
  "Stop MCP server."
  (interactive)
  (when (and tt--mcp-proc (process-live-p tt--mcp-proc))
    (delete-process tt--mcp-proc)
    (setq tt--mcp-proc nil)))

;; ── Mode-line clock ──

(defvar tt--timer nil "Clock update timer.")
(defvar tt--mode-line-string "" "Current mode-line display.")

(defun tt--format-ticks (ticks)
  "Format TICKS as human-readable trit-tick timestamp.
Format: SSS.GGG.HHH where S=seconds, G=GF3-cycles, H=hue-degrees."
  (let* ((secs (/ ticks tt-ticks-per-second))
         (rem (mod ticks tt-ticks-per-second))
         (gf3-cycles (/ rem tt-gf3-quantum))
         (rem2 (mod rem tt-gf3-quantum))
         (hue-steps (/ rem2 tt-hue-quantum)))
    (format "%d.%d.%03d" secs gf3-cycles hue-steps)))

(defun tt--update-mode-line ()
  "Advance the state chain and update mode-line display.
Each call is an immer transition: old state preserved, new state consed."
  (let* ((state (tt--advance))
         (trit (tt-state-gf3-trit state))
         (trit-str (propertize (tt-trit-char trit) 'face (tt-trit-face trit)))
         (color (tt-state-color-hex state))
         (swatch (propertize " " 'face `(:background ,color)))
         (hue (tt-state-hue-degree state))
         (v (tt-state-version state)))
    (setq tt--mode-line-string
          (format " %s%s%s%s "
                  swatch
                  (propertize (format "tt:%d" (mod (tt-state-ticks state)
                                                    tt-ticks-per-second))
                              'face '(:weight light))
                  trit-str
                  (propertize (format "h%d" hue)
                              'face '(:foreground "#888888"))))
    (force-mode-line-update t)))

;; ── Display buffer ──

(defun tt-show-clock ()
  "Display full trit-tick clock state in a dedicated buffer."
  (interactive)
  (let ((state (or (car tt--state-chain) (tt--advance))))
    (with-current-buffer (get-buffer-create "*trit-tick-clock*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "TRIT-TICK CLOCK\n")
        (insert (make-string 55 ?=) "\n\n")
        (insert (format "  141,120,000 = 2^9 x 3^2 x 5^4 x 7^2\n"))
        (insert (format "  1 trit-tick = 5 flicks = 7.086 ns\n\n"))
        (insert (make-string 55 ?-) "\n")
        ;; Current state
        (let* ((trit (tt-state-gf3-trit state))
               (color (tt-state-color-hex state)))
          (insert (format "  Version:    %d\n" (tt-state-version state)))
          (insert (format "  Ticks:      %s\n" (tt--format-ticks (tt-state-ticks state))))
          (insert (format "  Flicks:     %d\n" (tt-state-flicks state)))
          (insert (format "  GF(3) trit: %s %s\n"
                          (propertize (tt-trit-char trit) 'face (tt-trit-face trit))
                          (tt-state-gf3-phase state)))
          (insert (format "  Hue:        %d deg\n" (tt-state-hue-degree state)))
          (insert (format "  Color:      %s %s\n"
                          (propertize "  " 'face `(:background ,color))
                          color))
          (insert (format "  Hash:       %.16s\n" (tt-state-hash state)))
          (insert (format "  Parent:     %.16s\n" (or (tt-state-parent-hash state) "(genesis)"))))
        (insert "\n" (make-string 55 ?-) "\n")
        ;; Modality alignment
        (insert "  MODALITY SAMPLES AT THIS INSTANT\n\n")
        (dolist (m (tt-state-modality-sample state))
          (insert (format "    %-12s %15d samples\n" (car m) (cdr m))))
        ;; Quanta
        (insert "\n" (make-string 55 ?-) "\n")
        (insert "  QUANTA\n\n")
        (insert (format "    GF(3) cycle:  %d ticks  (1/3 sec)\n" tt-gf3-quantum))
        (insert (format "    Band quantum: %d ticks  (1/5 sec)\n" tt-band-quantum))
        (insert (format "    Hue degree:   %d ticks  (1/360 sec)\n" tt-hue-quantum))
        ;; State chain
        (insert "\n" (make-string 55 ?-) "\n")
        (insert (format "  IMMER CHAIN (%d states)\n\n" (length tt--state-chain)))
        (let ((i 0))
          (dolist (s (seq-take tt--state-chain 10))
            (let ((t-val (tt-state-gf3-trit s)))
              (insert (format "    %s v%d  %s  %s  %.8s\n"
                              (if (= i 0) ">" " ")
                              (tt-state-version s)
                              (propertize (tt-trit-char t-val) 'face (tt-trit-face t-val))
                              (propertize "  " 'face `(:background ,(tt-state-color-hex s)))
                              (tt-state-hash s))))
            (cl-incf i)))
        (when (> (length tt--state-chain) 10)
          (insert (format "    ... +%d more\n" (- (length tt--state-chain) 10))))
        ;; MCP status
        (insert "\n" (make-string 55 ?-) "\n")
        (insert (format "  MCP: %s\n"
                        (if (and tt--mcp-proc (process-live-p tt--mcp-proc))
                            "connected (zig-syrup)" "not connected")))
        (insert "\n  Derivation chain:\n")
        (insert "    jank-lang   -> immutable state (EwigState, ColoredSexp)\n")
        (insert "    flicks C++  -> 705,600,000/s = 141,120,000 * 5\n")
        (insert "    immer       -> persistent chain (parent-hash linkage)\n")
        (insert "    zig-syrup   -> trit_tick.zig (canonical time base)\n"))
      (goto-char (point-min))
      (special-mode)
      (display-buffer (current-buffer)))))

;; ── Conservation report ──

(defun tt-conservation-report ()
  "Check GF(3) conservation across the state chain."
  (interactive)
  (let* ((states (seq-take tt--state-chain 30))
         (trits (mapcar #'tt-state-gf3-trit states))
         (sum (apply #'+ trits))
         (balanced (= (mod sum 3) 0)))
    (with-current-buffer (get-buffer-create "*trit-conservation*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "GF(3) CONSERVATION REPORT\n")
        (insert (make-string 40 ?=) "\n\n")
        (insert (format "  Window: %d states\n" (length states)))
        (insert "  Trits:  ")
        (dolist (t-val trits)
          (insert (propertize (tt-trit-char t-val) 'face (tt-trit-face t-val)) " "))
        (insert (format "\n  Sum:    %d\n" sum))
        (insert (format "  mod 3:  %d\n" (mod sum 3)))
        (insert (format "\n  %s\n"
                        (if balanced
                            (propertize "CONSERVED" 'face '(:foreground "#00FF88" :weight bold))
                          (propertize "UNBALANCED" 'face '(:foreground "#FF4466" :weight bold))))))
      (goto-char (point-min))
      (special-mode)
      (display-buffer (current-buffer)))))

;; ── Start/Stop ──

;;;###autoload
(defun trit-tick-clock-start ()
  "Start the trit-tick clock in the mode line.
Each second: cons a new immutable state, update display.
GF(3) trit rotates. Color follows SplitMix64. Chain grows."
  (interactive)
  (unless tt--timer
    (setq tt--state-chain nil
          tt--state-version 0)
    (tt--update-mode-line)
    (setq tt--timer (run-at-time 1 1 #'tt--update-mode-line))
    (unless (memq 'tt--mode-line-string global-mode-string)
      (push 'tt--mode-line-string global-mode-string))
    (message "trit-tick clock started (141,120,000 Hz / displayed at 1 Hz)")))

(defun trit-tick-clock-stop ()
  "Stop the trit-tick clock."
  (interactive)
  (when tt--timer
    (cancel-timer tt--timer)
    (setq tt--timer nil)
    (setq global-mode-string
          (delq 'tt--mode-line-string global-mode-string))
    (force-mode-line-update t)
    (message "trit-tick clock stopped (%d states in chain)"
             (length tt--state-chain))))

;; ══════════════════════════════════════════════════════════════════
;; INTERACTION ENTROPY — LIVE FILESYSTEM PROBE
;; ══════════════════════════════════════════════════════════════════
;;
;; Localized to the time of simultaneity: the moment when multiple
;; trajectories outside our control converge into the same trit-tick
;; quantum. Device connections, file mutations, drand beacons, OS
;; housekeeping — all arriving more and more rapidly, each carrying
;; a trit, each landing on a 7.086 ns grid point.
;;
;; The old device connects. The filesystem responds. The density
;; increases. Conservation holds or breaks. We measure.

(defconst tt-worlds-root "/Users/bob/worlds/"
  "Root of the 26 letter-worlds.")

(defconst tt-fs-op-trits
  '(;; make (+1): new matter enters the world
    (create . +1) (write . +1) (symlink . +1)
    ;; coordinate (0): topology rearranges
    (rename . 0) (move . 0) (chmod . 0) (touch . 0) (mkdir . 0)
    ;; check (-1): observation / validation / removal
    (stat . -1) (read . -1) (unlink . -1) (verify . -1))
  "File system operations mapped to GF(3) trits.")

(defun tt--log2 (x)
  "Safe log base 2."
  (if (> x 0) (/ (log x) (log 2)) 0.0))

(defun tt--shannon-entropy (counts)
  "Shannon entropy H of a frequency vector COUNTS."
  (let* ((total (float (max 1 (apply #'+ counts))))
         (probs (mapcar (lambda (c) (/ (float c) total)) counts)))
    (- (apply #'+ (mapcar (lambda (p) (if (> p 0) (* p (tt--log2 p)) 0.0)) probs)))))

(defun tt--free-energy (counts)
  "KL divergence from uniform (1/3, 1/3, 1/3)."
  (let* ((total (float (max 1 (apply #'+ counts))))
         (q (/ 1.0 3.0)))
    (apply #'+ (mapcar (lambda (c)
                         (let ((p (/ (float c) total)))
                           (if (> p 0) (* p (log (/ p q))) 0.0)))
                       counts))))

(defun tt--render-spark (counts width)
  "Spark bar for (plus ergodic minus) at WIDTH chars."
  (let* ((total (float (max 1 (apply #'+ counts))))
         (w+ (max 0 (round (* (/ (float (nth 0 counts)) total) width))))
         (w0 (max 0 (round (* (/ (float (nth 1 counts)) total) width))))
         (w- (max 0 (- width w+ w0))))
    (concat
     (propertize (make-string w+ ?+) 'face '(:foreground "#00FF88" :weight bold))
     (propertize (make-string w0 ?o) 'face '(:foreground "#FFDD00"))
     (propertize (make-string w- ?-) 'face '(:foreground "#FF4466" :weight bold)))))

(defun tt--render-trit-stream (counts n)
  "Sample trit stream of N chars from distribution COUNTS."
  (let* ((total (float (max 1 (apply #'+ counts))))
         (p+ (/ (float (nth 0 counts)) total))
         (p0 (/ (float (nth 1 counts)) total))
         (result ""))
    (dotimes (_ n)
      (let* ((r (/ (random 1000) 1000.0))
             (trit (cond ((< r p+) +1) ((< r (+ p+ p0)) 0) (t -1))))
        (setq result (concat result
                             (propertize (tt-trit-char trit)
                                        'face (tt-trit-face trit))))))
    result))

(defun tt--format-thousands (n)
  "Format integer N with comma thousands separators."
  (let* ((s (number-to-string (truncate n)))
         (len (length s))
         (result ""))
    (dotimes (i len)
      (when (and (> i 0) (= (mod (- len i) 3) 0))
        (setq result (concat result ",")))
      (setq result (concat result (substring s i (1+ i)))))
    result))

;; ── Live filesystem probing ──

(defun tt--probe-letter-world (letter)
  "Probe a letter-world directory. Returns plist of file stats.
Classifies recent modifications by recency buckets."
  (let* ((dir (expand-file-name (string letter) tt-worlds-root))
         (now (float-time))
         (files 0) (dirs 0) (symlinks 0)
         (modified-1m 0) (modified-5m 0) (modified-1h 0) (modified-1d 0) (older 0)
         (trits-plus 0) (trits-zero 0) (trits-minus 0))
    (when (file-directory-p dir)
      (dolist (entry (directory-files dir t nil t))
        (unless (member (file-name-nondirectory entry) '("." ".."))
          (let* ((attrs (file-attributes entry 'string))
                 (type (file-attribute-type attrs))
                 (mtime (float-time (file-attribute-modification-time attrs)))
                 (age (- now mtime)))
            ;; Classify type -> trit
            (cond
             ((stringp type)                     ; symlink
              (cl-incf symlinks)
              (cl-incf trits-plus))              ; symlink = make
             ((eq type t)                        ; directory
              (cl-incf dirs)
              (cl-incf trits-zero))              ; dir = coordinate
             (t                                  ; regular file
              (cl-incf files)
              (cl-incf trits-minus)))            ; file exists = was checked/read
            ;; Recency bucket
            (cond
             ((< age 60)    (cl-incf modified-1m))
             ((< age 300)   (cl-incf modified-5m))
             ((< age 3600)  (cl-incf modified-1h))
             ((< age 86400) (cl-incf modified-1d))
             (t             (cl-incf older)))))))
    (list :letter (string letter) :files files :dirs dirs :symlinks symlinks
          :total (+ files dirs symlinks)
          :mod-1m modified-1m :mod-5m modified-5m
          :mod-1h modified-1h :mod-1d modified-1d :older older
          :trits (list trits-plus trits-zero trits-minus)
          :trit-sum (+ trits-plus (- trits-minus)))))

(defun tt--probe-all-worlds ()
  "Probe all 26 letter-worlds. Returns list of plists."
  (let ((results nil))
    (dotimes (i 26)
      (push (tt--probe-letter-world (+ ?a i)) results))
    (nreverse results)))

(defun tt--simultaneity-window (probes window-key)
  "Find worlds with simultaneous activity in WINDOW-KEY (:mod-1m, :mod-5m, etc)."
  (let ((active nil))
    (dolist (p probes)
      (when (> (plist-get p window-key) 0)
        (push p active)))
    (nreverse active)))

;; ── Scenario density levels ──

(defconst tt-density-levels
  '((:name "silence"     :hz 0      :desc "no events. 141M trit-ticks of void."
     :spacing "infinite" :feel "the old device is off. the filesystem is still.")
    (:name "drand"       :hz 0.33   :desc "drand beacon every 3s. outside all control."
     :spacing "423,360,000" :feel "round 27005578. seed 0xcc655115d7b04279. arriving.")
    (:name "narya"       :hz 2      :desc "narya type-checks a .ny file. isFibrant codata."
     :spacing "70,560,000" :feel "20/25 passing. 3 holes in fibrant_sqrt. reads cascade.")
    (:name "lean-lsp"    :hz 12     :desc "lean 4 server checking InfinityCosmos imports."
     :spacing "11,760,000" :feel "LSP reads every import. stat stat stat stat.")
    (:name "coq-compile" :hz 40     :desc "coqc compiling Overture.v. paths_ind. composition."
     :spacing "3,528,000" :feel "tactics fire. each step reads .vo dependencies.")
    (:name "3-checkers"  :hz 54     :desc "narya + lean + coq simultaneously. THIS SCREEN."
     :spacing "2,613,333" :feel "three type theories checking at once. convergence.")
    (:name "proof+drand" :hz 54.33  :desc "three checkers + drand beacon. fully outside you."
     :spacing "2,597,790" :feel "the beacon arrives mid-proof. you did not ask for it.")
    (:name "adhesion"    :hz 120    :desc "symlink burst. 63 cross-world links updating."
     :spacing "1,176,000" :feel "t/ attractor hub. 18 symlinks. topology reshapes.")
    (:name "zig-build"   :hz 350    :desc "zig build zig-syrup. 320 .zig files read."
     :spacing "403,200" :feel "trit_tick.zig compiled. the clock compiles itself.")
    (:name "device-pour" :hz 4000   :desc "HERO/OpenBCI connected. data streaming in."
     :spacing "35,280" :feel "more and more. packets arrive. you do not schedule them.")
    (:name "saturated"   :hz 141120 :desc "1000 events per GF(3) quantum."
     :spacing "1,000" :feel "every tick full. conservation or chaos."))
  "Density levels localized to the proof session.")

;; ── Main display ──

(defun tt-show-scenarios ()
  "Probe the live filesystem, show interaction entropy at various densities.
Localized to the time of simultaneity of connection."
  (interactive)
  (let* ((now (float-time))
         (now-tt (truncate (* now tt-ticks-per-second)))
         (now-trit (tt-trit (truncate now)))
         (now-color (tt-color-hex (truncate now) 0))
         (probes (tt--probe-all-worlds))
         (active-1m (tt--simultaneity-window probes :mod-1m))
         (active-5m (tt--simultaneity-window probes :mod-5m))
         (active-1h (tt--simultaneity-window probes :mod-1h))
         (total-files (apply #'+ (mapcar (lambda (p) (plist-get p :total)) probes)))
         (total-syms (apply #'+ (mapcar (lambda (p) (plist-get p :symlinks)) probes)))
         (all-trits (let ((sums (list 0 0 0)))
                      (dolist (p probes sums)
                        (let ((tr (plist-get p :trits)))
                          (setf (nth 0 sums) (+ (nth 0 sums) (nth 0 tr)))
                          (setf (nth 1 sums) (+ (nth 1 sums) (nth 1 tr)))
                          (setf (nth 2 sums) (+ (nth 2 sums) (nth 2 tr)))))))
         (global-H (tt--shannon-entropy all-trits))
         (global-F (tt--free-energy all-trits))
         (H-max (tt--log2 3))
         (buf (get-buffer-create "*trit-tick-scenarios*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)

        ;; ── Header: the moment ──
        (insert (propertize "TIME OF SIMULTANEITY\n" 'face '(:weight bold :height 1.3)))
        (insert (make-string 72 ?=) "\n\n")
        (insert "  " (propertize (format-time-string "%Y-%m-%d %H:%M:%S" now)
                                 'face '(:weight bold)))
        (insert (format "  trit-tick %d" (mod now-tt tt-ticks-per-second)))
        (insert "  " (propertize (tt-trit-char now-trit) 'face (tt-trit-face now-trit)))
        (insert "  " (propertize "  " 'face `(:background ,now-color)) " " now-color)
        (insert "\n\n")
        (insert "  Trajectories outside our control arrive more and more.\n")
        (insert "  The old device connects. The filesystem responds.\n")
        (insert "  Each event lands on a 7.086 ns grid point. We measure.\n")
        (insert "\n" (make-string 72 ?=) "\n")

        ;; ── Live filesystem state ──
        (insert "\n" (propertize "LIVE FILESYSTEM STATE" 'face '(:weight bold)) "\n")
        (insert (make-string 72 ?-) "\n\n")
        (insert (format "  Total entries across a-z:  %d\n" total-files))
        (insert (format "  Symlinks (adhesion):       %d\n" total-syms))
        (insert (format "  Global trit distribution:  "))
        (insert (tt--render-spark all-trits 30))
        (insert (format "  +%d o%d -%d\n" (nth 0 all-trits) (nth 1 all-trits) (nth 2 all-trits)))
        (insert (format "  Shannon entropy:           %.3f / %.3f bits (%.0f%%)\n"
                        global-H H-max (* 100 (/ global-H H-max))))
        (insert (format "  Free energy:               %.4f nats\n" global-F))
        (let ((gsum (+ (nth 0 all-trits) (- (nth 2 all-trits)))))
          (insert (format "  GF(3) sum:                 %+d  mod3=%d  " gsum (mod (abs gsum) 3)))
          (if (= (mod (abs gsum) 3) 0)
              (insert (propertize "CONSERVED\n" 'face '(:foreground "#00FF88" :weight bold)))
            (insert (propertize "UNBALANCED\n" 'face '(:foreground "#FF4466" :weight bold)))))

        ;; ── Simultaneity windows ──
        (insert "\n" (propertize "SIMULTANEITY WINDOWS" 'face '(:weight bold)) "\n")
        (insert (make-string 72 ?-) "\n")
        (insert "  Worlds with file mutations converging in the same time window:\n\n")

        (dolist (window-spec '((:mod-1m "< 1 min"  "device just connected. burst arriving.")
                               (:mod-5m "< 5 min"  "recent session. trajectories still warm.")
                               (:mod-1h "< 1 hour" "this working period. control fading.")
                               (:mod-1d "< 1 day"  "today's arc. mostly outside control now.")))
          (let* ((key (nth 0 window-spec))
                 (label (nth 1 window-spec))
                 (feel (nth 2 window-spec))
                 (active (tt--simultaneity-window probes key))
                 (n (length active)))
            (insert (format "  %s " (propertize label 'face '(:weight bold))))
            (if (= n 0)
                (insert (propertize "---" 'face '(:foreground "#444444")))
              (dolist (p active)
                (let* ((letter (plist-get p :letter))
                       (cnt (plist-get p key))
                       (color (tt-color-hex (string-to-char letter) 0)))
                  (insert (propertize (format "%s:%d " letter cnt)
                                      'face `(:foreground ,color :weight bold)))))
              (insert (propertize (format " (%d worlds)" n) 'face '(:foreground "#888888"))))
            (insert "\n")
            (when (> n 1)
              (insert "         " (propertize feel 'face '(:slant italic :foreground "#666666")) "\n"))))

        ;; ── Per-world detail for active worlds ──
        (insert "\n" (propertize "ACTIVE WORLD DETAIL" 'face '(:weight bold)) "\n")
        (insert (make-string 72 ?-) "\n\n")
        (insert "  world  files syms  trits          H      F      GF(3)\n")
        (insert "  " (make-string 70 ?-) "\n")
        (dolist (p probes)
          (let* ((total (plist-get p :total))
                 (trits (plist-get p :trits)))
            (when (> total 0)
              (let* ((H (tt--shannon-entropy trits))
                     (F (tt--free-energy trits))
                     (tsum (plist-get p :trit-sum))
                     (color (tt-color-hex (string-to-char (plist-get p :letter)) 0)))
                (insert (format "  %s "
                                (propertize (plist-get p :letter)
                                            'face `(:foreground ,color :weight bold))))
                (insert (format "    %4d %4d  " (plist-get p :files) (plist-get p :symlinks)))
                (insert (tt--render-spark trits 15))
                (insert (format " %.2f  %.3f  %+d%s\n"
                                H F tsum
                                (if (= (mod (abs tsum) 3) 0) "" " !")))))))

        ;; ── Density phase diagram ──
        (insert "\n" (propertize "DENSITY PHASE DIAGRAM" 'face '(:weight bold)) "\n")
        (insert (make-string 72 ?=) "\n")
        (insert "  trit-ticks between events at each density level:\n\n")

        (dolist (level tt-density-levels)
          (let* ((name (plist-get level :name))
                 (hz (plist-get level :hz))
                 (desc (plist-get level :desc))
                 (spacing (plist-get level :spacing))
                 (feel (plist-get level :feel))
                 (tpe (if (> hz 0) (/ tt-ticks-per-second hz) 0))
                 ;; bar width proportional to log of spacing
                 (bar-w (if (> hz 0)
                            (max 1 (min 40 (round (* 5 (log (max 1 tpe) 10)))))
                          40))
                 (color (cond ((= hz 0) "#222244")
                              ((< hz 1) "#334466")
                              ((< hz 10) "#446688")
                              ((< hz 100) "#6699BB")
                              ((< hz 1000) "#99AA44")
                              ((< hz 10000) "#DD8833")
                              (t "#FF4444"))))

            (insert "\n  " (propertize (format "%-13s" name) 'face `(:foreground ,color :weight bold)))
            (if (= hz 0)
                (insert (propertize (make-string 40 ?.) 'face '(:foreground "#222244")))
              (insert (propertize (make-string bar-w ?|) 'face `(:foreground ,color))
                      (make-string (max 0 (- 40 bar-w)) ? )))
            (insert (format " %s Hz\n" (if (= hz 0) "0" (tt--format-thousands hz))))
            (insert "                ")
            (insert (propertize (format "%s tt between events" spacing)
                                'face '(:foreground "#888888")))
            (insert "\n                ")
            (insert (propertize feel 'face '(:slant italic :foreground "#666666")))
            (insert "\n")))

        ;; ── The old device connects ──
        (insert "\n\n" (propertize "THE OLD DEVICE CONNECTS" 'face '(:weight bold)) "\n")
        (insert (make-string 72 ?=) "\n\n")
        (insert "  Three type checkers are running. This is the old device.\n")
        (insert "  The proofs are the trajectories outside your control.\n\n")

        (insert "  " (propertize "NARYA" 'face '(:foreground "#FF9944" :weight bold)))
        (insert "   fibrancy.ny → isFibrant codata\n")
        (insert "    t=0   load .ny               ")
        (insert (propertize "-1" 'face (tt-trit-face -1)) " read\n")
        (insert "    t+1   parse codata decl      ")
        (insert (propertize " 0" 'face (tt-trit-face 0)) " coordinate\n")
        (insert "    t+2   check .trr.e           ")
        (insert (propertize "-1" 'face (tt-trit-face -1)) " verify\n")
        (insert "    t+3   check .liftl.e         ")
        (insert (propertize "-1" 'face (tt-trit-face -1)) " verify\n")
        (insert "    t+4   check .id.e            ")
        (insert (propertize "-1" 'face (tt-trit-face -1)) " verify\n")
        (insert "    t+5   emit eq.trr proof      ")
        (insert (propertize "+1" 'face (tt-trit-face 1)) " create\n")
        (insert "    t+6   emit rtr               ")
        (insert (propertize "+1" 'face (tt-trit-face 1)) " create\n")
        (insert "    t+7   emit Id_eq chain       ")
        (insert (propertize "+1" 'face (tt-trit-face 1)) " create\n")
        (insert "    ...   20 of 25 pass. 3 holes remain in fibrant_sqrt.\n")
        (let* ((narya-trits '(3 1 4)))
          (insert "    narya burst:   " (tt--render-spark narya-trits 15)
                  (format " H=%.3f" (tt--shannon-entropy narya-trits)))
          (insert (format " sum=%+d" (- (nth 0 narya-trits) (nth 2 narya-trits)))))
        (insert "\n\n")

        (insert "  " (propertize "LEAN 4" 'face '(:foreground "#6699CC" :weight bold)))
        (insert "  InfinityCosmos imports\n")
        (insert "    continuous LSP stat/read on every import line\n")
        (insert "    12 Hz. each import = read .olean + stat .lean\n")
        (let* ((lean-trits '(0 0 12)))
          (insert "    lean burst:    " (tt--render-spark lean-trits 15)
                  (format " H=%.3f" (tt--shannon-entropy lean-trits)))
          (insert (format " sum=%+d" (- (nth 0 lean-trits) (nth 2 lean-trits)))))
        (insert "  " (propertize "pure check" 'face '(:foreground "#FF4466")) "\n\n")

        (insert "  " (propertize "COQ HOTT" 'face '(:foreground "#BB66DD" :weight bold)))
        (insert " Overture.v\n")
        (insert "    composeD, iff_compose, paths_ind, paths_rec\n")
        (insert "    each Global Instance = write .vo + read deps\n")
        (let* ((coq-trits '(8 2 15)))
          (insert "    coq burst:     " (tt--render-spark coq-trits 15)
                  (format " H=%.3f" (tt--shannon-entropy coq-trits)))
          (insert (format " sum=%+d" (- (nth 0 coq-trits) (nth 2 coq-trits)))))
        (insert "\n\n")

        (insert "  " (propertize "DRAND" 'face '(:foreground "#44DDAA" :weight bold)))
        (insert "    round 27005578\n")
        (insert "    arrives every 3s. you did not ask for it.\n")
        (insert "    seed 0xcc655115d7b04279 -> color -> trit\n")
        (let ((drand-trit (tt-trit 27005578)))
          (insert "    this round's trit: "
                  (propertize (tt-trit-char drand-trit) 'face (tt-trit-face drand-trit))))
        (insert "\n\n")

        ;; Combined
        (insert "  " (propertize "COMBINED (this screen)" 'face '(:weight bold)) "\n")
        (let* ((combined '(11 3 31))
               (cH (tt--shannon-entropy combined))
               (cF (tt--free-energy combined))
               (csum (- (nth 0 combined) (nth 2 combined))))
          (insert "    " (tt--render-spark combined 30))
          (insert (format "  +%d o%d -%d\n" (nth 0 combined) (nth 1 combined) (nth 2 combined)))
          (insert (format "    H=%.3f bits  F=%.4f nats\n" cH cF))
          (insert (format "    GF(3) sum: %+d  mod3=%d  " csum (mod (abs csum) 3)))
          (if (= (mod (abs csum) 3) 0)
              (insert (propertize "CONSERVED" 'face '(:foreground "#00FF88" :weight bold)))
            (insert (propertize "UNBALANCED" 'face '(:foreground "#FF4466" :weight bold))))
          (insert "\n\n")
          (insert "    Proof verification IS the check trit.\n")
          (insert "    The checker reads (-1) so that the proof can exist (+1).\n")
          (insert "    " (propertize "Verification is the balancing force." 'face '(:weight bold)) "\n"))

        (insert "\n" (make-string 72 ?-) "\n")
        (insert "  SECURITY CHAIN (from your *GAY* buffer):\n")
        (insert "    isFibrant -> eq -> rtr -> Id_eq -> Id_rtr\n")
        (insert "    -> fib_rtr -> fib_pi -> isbisim_rtr -> fib_any\n")
        (insert "    -> pre_univalence -> glue_rtr -> fib_glue -> id_pi_rtr\n")
        (insert "    -> univalence_bisim -> univalence_11 -> univalence_vv\n")
        (insert "    -> DEFINITIONAL both directions -> srefl\n\n")
        (insert "    Each link in this chain: a check trit followed by a make trit.\n")
        (insert "    verify(n) -> emit(n+1). The chain IS conservation.\n")
        (insert "    " (propertize "20 verified. 3 holes. 4 known issues. 1 frontier."
                                   'face '(:slant italic)) "\n")

        (insert "\n" (make-string 72 ?-) "\n")
        (insert "  As density increases, control inverts:\n\n")
        (insert "    you type .ny  ")
        (insert (propertize "||||||||||||||||||||" 'face '(:foreground "#00FF88"))
                (propertize "||" 'face '(:foreground "#FF4444")))
        (insert "  90% you\n")
        (insert "    narya checks  ")
        (insert (propertize "|||||||" 'face '(:foreground "#00FF88"))
                (propertize "|||||||||||||||" 'face '(:foreground "#FF4444")))
        (insert "  30% you\n")
        (insert "    lean imports  ")
        (insert (propertize "||" 'face '(:foreground "#00FF88"))
                (propertize "||||||||||||||||||||" 'face '(:foreground "#FF4444")))
        (insert "  10% you\n")
        (insert "    coq compiles  ")
        (insert (propertize "|" 'face '(:foreground "#00FF88"))
                (propertize "|||||||||||||||||||||" 'face '(:foreground "#FF4444")))
        (insert "   5% you\n")
        (insert "    drand arrives ")
        (insert (propertize "" 'face '(:foreground "#00FF88"))
                (propertize "||||||||||||||||||||||" 'face '(:foreground "#FF4444")))
        (insert "   0% you\n")
        (insert "    device pours  ")
        (insert (propertize "" 'face '(:foreground "#00FF88"))
                (propertize "||||||||||||||||||||||" 'face '(:foreground "#FF4444")))
        (insert "   0% you\n")

        (insert "\n  " (propertize "The trit-tick clock keeps counting either way."
                                   'face '(:slant italic)))
        (insert "\n  " (propertize "Conservation does not require control."
                                   'face '(:slant italic)))
        (insert "\n  " (propertize "It requires balance."
                                   'face '(:weight bold)))
        (insert "\n"))
      (goto-char (point-min))
      (special-mode)
      (display-buffer buf))))

;; ── Keymap ──

(defvar trit-tick-clock-command-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "c") #'tt-show-clock)
    (define-key map (kbd "s") #'trit-tick-clock-start)
    (define-key map (kbd "q") #'trit-tick-clock-stop)
    (define-key map (kbd "g") #'tt-conservation-report)
    (define-key map (kbd "m") #'tt-mcp-start)
    (define-key map (kbd "e") #'tt-show-scenarios)
    map)
  "Keymap for trit-tick clock commands.")

(global-set-key (kbd "C-c C-t") trit-tick-clock-command-map)

(provide 'trit-tick-clock)

;;; trit-tick-clock.el ends here
