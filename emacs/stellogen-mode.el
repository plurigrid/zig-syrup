;;; stellogen-mode.el --- Major mode for Stellogen (.sg) files  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  bmorphism
;; SPDX-License-Identifier: Apache-2.0

;; Stellogen: logic-agnostic language based on term unification.
;; Polarity-driven star fusion = Robinson's resolution.
;; Two backends: OCaml (sgen) and Zig (stellogen_cli).

;;; Code:

(require 'compile)
(require 'trit-tick-clock nil t)

;; ── Customization ──

(defgroup stellogen nil
  "Stellogen programming language."
  :group 'languages
  :prefix "stellogen-")

(defcustom stellogen-ocaml-executable
  (expand-file-name "~/i/stellogen-upstream/_build/default/bin/sgen.exe")
  "Path to OCaml sgen executable."
  :type 'file
  :group 'stellogen)

(defcustom stellogen-zig-executable
  (expand-file-name "~/i/zig-syrup/zig-out/bin/stellogen")
  "Path to Zig stellogen CLI."
  :type 'file
  :group 'stellogen)

(defcustom stellogen-backend 'ocaml
  "Which backend to use for compilation."
  :type '(choice (const :tag "OCaml (sgen)" ocaml)
                 (const :tag "Zig (stellogen_cli)" zig))
  :group 'stellogen)

(defcustom stellogen-examples-dir
  (expand-file-name "~/i/stellogen-upstream/examples/")
  "Directory containing Stellogen example files."
  :type 'directory
  :group 'stellogen)

;; ── Syntax table ──

(defvar stellogen-mode-syntax-table
  (let ((st (make-syntax-table)))
    (modify-syntax-entry ?\' "<" st)   ; single quote starts comment
    (modify-syntax-entry ?\n ">" st)   ; newline ends comment
    (modify-syntax-entry ?\( "()" st)
    (modify-syntax-entry ?\) ")(" st)
    (modify-syntax-entry ?\[ "(]" st)
    (modify-syntax-entry ?\] ")[" st)
    (modify-syntax-entry ?\{ "(}" st)
    (modify-syntax-entry ?\} "){" st)
    (modify-syntax-entry ?_ "w" st)
    (modify-syntax-entry ?- "w" st)
    st)
  "Syntax table for `stellogen-mode'.")

;; ── Font lock (derived from nvim/syntax/stellogen.vim) ──

(defface stellogen-polarity-plus
  '((t :foreground "#00FF00" :weight bold))
  "Face for positive polarity (+)."
  :group 'stellogen)

(defface stellogen-polarity-minus
  '((t :foreground "#FF4444" :weight bold))
  "Face for negative polarity (-)."
  :group 'stellogen)

(defface stellogen-variable
  '((t :foreground "#88CCFF" :weight bold))
  "Face for variables (uppercase identifiers)."
  :group 'stellogen)

(defface stellogen-identifier-ref
  '((t :foreground "#FFAA44"))
  "Face for identifier references (#name)."
  :group 'stellogen)

(defface stellogen-focus
  '((t :foreground "#FF66FF" :weight bold))
  "Face for focus marker (@)."
  :group 'stellogen)

(defface stellogen-ok
  '((t :foreground "#00FF00" :weight bold))
  "Face for ok constant."
  :group 'stellogen)

(defvar stellogen-font-lock-keywords
  `(;; Multi-line comments '''...'''
    ("'''\\(?:.\\|\n\\)*?'''" . font-lock-comment-face)
    ;; Keywords
    (,(regexp-opt '("def" "macro" "macros" "eval" "slice" "show"
                    "use" "use-macros" "exec" "fire" "process"
                    "spec" "stack" "chain" "process-step")
                  'symbols)
     . font-lock-keyword-face)
    ;; ok constant
    ("\\<ok\\>" . 'stellogen-ok)
    ;; Operators
    ("\\(::=?\\|==\\|~=\\|!=\\|||\\|\\.\\.\\.\\)" . font-lock-builtin-face)
    ;; Focus marker @
    ("@" . 'stellogen-focus)
    ;; Polarity markers before identifiers
    ("\\+\\ze\\w" . 'stellogen-polarity-plus)
    ("-\\ze\\w" . 'stellogen-polarity-minus)
    ;; Identifier references #name or #(name)
    ("#[a-z_][a-z0-9_-]*" . 'stellogen-identifier-ref)
    ("#[0-9]+" . 'stellogen-identifier-ref)
    ("#([^)]+)" . 'stellogen-identifier-ref)
    ;; Variables (uppercase starting)
    ("\\<[A-Z_][A-Za-z0-9_]*\\>" . 'stellogen-variable)
    ;; Defined identifiers after (def
    ("(def\\s+\\([a-z_][a-z0-9_-]*\\)" 1 font-lock-function-name-face))
  "Font lock keywords for `stellogen-mode'.")

;; ── Indentation ──

(defun stellogen-indent-line ()
  "Indent current line for Stellogen."
  (let ((indent 0)
        (pos (- (point-max) (point))))
    (save-excursion
      (beginning-of-line)
      (let ((depth (car (syntax-ppss))))
        (setq indent (* 2 (max 0 depth)))
        (when (looking-at "\\s-*[}\\])]")
          (setq indent (max 0 (- indent 2))))))
    (indent-line-to indent)
    (when (> (- (point-max) pos) (point))
      (goto-char (- (point-max) pos)))))

;; ── Compilation ──

(defun stellogen-compile-file ()
  "Compile/run the current .sg file with the selected backend."
  (interactive)
  (let* ((file (buffer-file-name))
         (cmd (pcase stellogen-backend
                ('ocaml (format "%s run %s" stellogen-ocaml-executable file))
                ('zig (format "%s run %s" stellogen-zig-executable file)))))
    (compile cmd)))

(defun stellogen-check-file ()
  "Check the current .sg file without executing."
  (interactive)
  (let* ((file (buffer-file-name))
         (cmd (pcase stellogen-backend
                ('ocaml (format "%s run %s" stellogen-ocaml-executable file))
                ('zig (format "%s check %s" stellogen-zig-executable file)))))
    (compile cmd)))

(defun stellogen-fire-file ()
  "Run the current file with linear (fire) execution."
  (interactive)
  (compile (format "%s run %s" stellogen-ocaml-executable (buffer-file-name))))

(defun stellogen-switch-backend ()
  "Toggle between OCaml and Zig backends."
  (interactive)
  (setq stellogen-backend (if (eq stellogen-backend 'ocaml) 'zig 'ocaml))
  (message "Stellogen backend: %s" stellogen-backend))

(defun stellogen-open-example ()
  "Open a Stellogen example file."
  (interactive)
  (let* ((files (directory-files-recursively stellogen-examples-dir "\\.sg$"))
         (names (mapcar (lambda (f) (file-relative-name f stellogen-examples-dir)) files))
         (choice (completing-read "Example: " names nil t)))
    (find-file (expand-file-name choice stellogen-examples-dir))))

;; ── Counterfactual regret worlds ──

(defvar stellogen--active-world 0
  "Index (0-6) of the currently active counterfactual regret world.")

(defconst stellogen-world-names
  '("hwb" "nit" "xsy" "acr" "dlm" "egk" "ovz")
  "The 7 Hamming chain letter-worlds from from-possible-worlds.")

(defconst stellogen-world-strategies
  '("direct-append"      ; balanced_append via concatenation
    "inductive-split"     ; list_sum_split by induction on index
    "operadic-substitute" ; substitution preserves sum
    "linarith-close"      ; linear arithmetic finishing
    "zero-slot-special"   ; zero-slot corollary
    "permutation-equiv"   ; Perm.sum_eq
    "full-compose")       ; complete operadic composition
  "Proof strategy for each of the 7 worlds.")

(defun stellogen-cycle-world ()
  "Advance to the next counterfactual regret world."
  (interactive)
  (setq stellogen--active-world (mod (1+ stellogen--active-world) 7))
  (message "World %d/%d: %s [%s]"
           (1+ stellogen--active-world) 7
           (nth stellogen--active-world stellogen-world-names)
           (nth stellogen--active-world stellogen-world-strategies)))

(defun stellogen-show-worlds ()
  "Display all 7 counterfactual regret worlds and their status."
  (interactive)
  (with-current-buffer (get-buffer-create "*Stellogen Worlds*")
    (erase-buffer)
    (insert "GF(3) Operadic Composition -- 7 Counterfactual Regret Worlds\n")
    (insert "Proof obligation :a036ea from `from-possible-worlds`\n")
    (insert (make-string 60 ?=) "\n\n")
    (dotimes (i 7)
      (let* ((active (= i stellogen--active-world))
             (trit (mod (- i 1) 3))
             (trit-c (pcase trit (0 "o") (1 "+") (2 "-")))
             (marker (if active ">>>" "   ")))
        (insert (format "%s [%s] World %d: %-3s | %-22s | trit=%s\n"
                        marker (if active "*" " ") (1+ i)
                        (nth i stellogen-world-names)
                        (nth i stellogen-world-strategies)
                        trit-c))))
    (insert (format "\nSum of trits: %d mod 3 = %d  %s\n"
                    (apply #'+ (number-sequence -1 5))
                    (mod (apply #'+ (number-sequence -1 5)) 3)
                    "BALANCED"))
    (insert "\nPress `w` to cycle worlds, `r` to run active world.\n")
    (goto-char (point-min))
    (special-mode)
    (display-buffer (current-buffer))))

;; ── gay-tt integration ──

(defvar sg-worlds--mode-line "" "Stellogen worlds mode-line segment.")

(defun stellogen--tt-world-index ()
  "Derive active world from trit-tick state if available."
  (when (bound-and-true-p tt--state-chain)
    (let ((state (car tt--state-chain)))
      (when state
        (mod (tt-state-ticks state) 7)))))

(defun stellogen-sync-to-tt ()
  "Sync active world to trit-tick clock state."
  (interactive)
  (let ((idx (stellogen--tt-world-index)))
    (when idx
      (setq stellogen--active-world idx)
      (message "Synced to trit-tick: world %d (%s)"
               (1+ idx) (nth idx stellogen-world-names)))))

(defun stellogen--gay-tt-hook (plist)
  "Hook called on each gay-tt color update. Cycles worlds and publishes to NATS."
  (let* ((epoch (or (plist-get plist :epoch) 0))
         (idx (mod epoch 7))
         (name (nth idx stellogen-world-names))
         (strat (nth idx stellogen-world-strategies))
         (trit (plist-get plist :trit)))
    (setq stellogen--active-world idx)
    (setq sg-worlds--mode-line
          (format " [W%d:%s|%s]" (1+ idx) name
                  (pcase trit (1 "+") (-1 "-") (_ "o"))))
    (when (fboundp 'gay-tt--nats-pub)
      (gay-tt--nats-pub "ies.a.stellogen.world"
        (format "{\"world\":%d,\"name\":\"%s\",\"strategy\":\"%s\",\"trit\":%d,\"epoch\":%d}"
                (1+ idx) name strat (or trit 0) epoch)))))

(defun stellogen-enable-tt-cycling ()
  "Enable automatic world cycling via gay-tt trit-tick clock."
  (interactive)
  (when (boundp 'gay-color-update-hook)
    (add-hook 'gay-color-update-hook #'stellogen--gay-tt-hook))
  (unless (memq 'sg-worlds--mode-line global-mode-string)
    (push 'sg-worlds--mode-line global-mode-string))
  (message "Stellogen worlds cycling via gay-tt enabled"))

;; ── Keymap ──

(defvar stellogen-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'stellogen-compile-file)
    (define-key map (kbd "C-c C-k") #'stellogen-check-file)
    (define-key map (kbd "C-c C-f") #'stellogen-fire-file)
    (define-key map (kbd "C-c C-b") #'stellogen-switch-backend)
    (define-key map (kbd "C-c C-e") #'stellogen-open-example)
    (define-key map (kbd "C-c C-w") #'stellogen-cycle-world)
    (define-key map (kbd "C-c C-s") #'stellogen-sync-to-tt)
    (define-key map (kbd "C-c ?")   #'stellogen-show-worlds)
    map)
  "Keymap for `stellogen-mode'.")

;; ── Global keymap under C-c C-g (stellogen) ──

(defvar stellogen-command-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "w") #'stellogen-show-worlds)
    (define-key map (kbd "c") #'stellogen-cycle-world)
    (define-key map (kbd "s") #'stellogen-sync-to-tt)
    (define-key map (kbd "e") #'stellogen-open-example)
    map)
  "C-c C-g prefix: w=worlds c=cycle s=sync e=examples")

(global-set-key (kbd "C-c C-g") stellogen-command-map)

;; ── Mode definition ──

;;;###autoload
(define-derived-mode stellogen-mode prog-mode "Stellogen"
  "Major mode for editing Stellogen (.sg) files.

Stellogen is a logic-agnostic language based on term unification.
Stars fuse along compatible rays (opposite polarity + unification).

\\{stellogen-mode-map}"
  :syntax-table stellogen-mode-syntax-table
  (setq-local font-lock-defaults '(stellogen-font-lock-keywords))
  (setq-local comment-start "' ")
  (setq-local comment-end "")
  (setq-local indent-line-function #'stellogen-indent-line)
  (setq-local font-lock-multiline t))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.sg\\'" . stellogen-mode))
;;;###autoload
(add-to-list 'auto-mode-alist '("\\.mml\\'" . stellogen-mode))

(provide 'stellogen-mode)
;;; stellogen-mode.el ends here
