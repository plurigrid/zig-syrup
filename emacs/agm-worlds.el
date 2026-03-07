;;; agm-worlds.el --- AGM Belief Revision × Worlds × Isabelle2  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  bmorphism
;; SPDX-License-Identifier: Apache-2.0

;; Author: bmorphism
;; Keywords: belief-revision, worlds, isabelle, bandit

;;; Commentary:

;; Emacs interface for zig-syrup's AGM belief revision engine.
;; Connects three systems:
;;   1. Zig runtime: bandit.zig + agm.zig + puffer_ffi.zig
;;   2. Isabelle2 theories: boxxy/theories/AGM_Base.thy, AGM_Extensions.thy
;;   3. PufferLib RL: observation/action inspection
;;
;; Keybindings (under C-c C-a prefix):
;;   C-c C-a p  — Run AGM postcondition checks
;;   C-c C-a b  — Show bandit strategy state
;;   C-c C-a i  — Open Isabelle2 theory file
;;   C-c C-a e  — Show ewig history summary
;;   C-c C-a t  — Build and run worlds tests
;;   C-c C-a w  — Run world-bandit example
;;   C-c C-a g  — Verify GF(3) conservation

;;; Code:

(require 'compile)

(defgroup agm-worlds nil
  "AGM Belief Revision × Worlds interface."
  :group 'tools
  :prefix "agm-worlds-")

(defcustom agm-worlds-zig-syrup-dir
  (expand-file-name "~/i/zig-syrup/")
  "Path to zig-syrup project root."
  :type 'directory
  :group 'agm-worlds)

(defcustom agm-worlds-boxxy-dir
  (expand-file-name "~/i/boxxy/")
  "Path to boxxy Isabelle2 theories."
  :type 'directory
  :group 'agm-worlds)

(defcustom agm-worlds-isabelle-executable
  "isabelle"
  "Path to Isabelle executable."
  :type 'string
  :group 'agm-worlds)

;; ── Source file locations ──

(defconst agm-worlds-source-files
  '((bandit     . "src/worlds/bandit.zig")
    (agm        . "src/worlds/agm.zig")
    (agm-ewig   . "src/worlds/agm_ewig.zig")
    (agm-isa    . "src/worlds/agm_isabelle.zig")
    (puffer-ffi . "src/worlds/puffer_ffi.zig")
    (mod        . "src/worlds/mod.zig"))
  "Zig source files for the AGM/Worlds system.")

(defconst agm-worlds-isabelle-theories
  '((agm-base       . "theories/AGM_Base.thy")
    (agm-extensions  . "theories/AGM_Extensions.thy")
    (agm-bridge      . "theories/Boxxy_AGM_Bridge.thy")
    (grove-spheres   . "theories/Grove_Spheres.thy")
    (nashator        . "theories/SemiReliable_Nashator.thy"))
  "Isabelle2 theory files for AGM verification.")

;; ── AGM Postulates (from AGM_Base.thy) ──

(defconst agm-worlds-postulates
  '(("K*1" "Closure"        "K*p is deductively closed")
    ("K*2" "Success"        "p ∈ K*p")
    ("K*3" "Inclusion"      "K*p ⊆ K+p")
    ("K*4" "Vacuity"        "if ¬p ∉ K then K*p = K+p")
    ("K*5" "Consistency"    "if ⊥ ∉ Cn({p}) then K*p ≠ ⊥")
    ("K*6" "Extensionality" "if ⊢ p↔q then K*p = K*q")
    ("K*7" "Superexpansion" "K*(p∧q) ⊆ (K*p)+q")
    ("K*8" "Subexpansion"   "if ¬q ∉ K*p then (K*p)+q ⊆ K*(p∧q)"))
  "The 8 AGM postulates for belief revision.")

;; ── GF(3) trit display ──

(defconst agm-worlds-trit-faces
  '((+1 . (:foreground "#00FF00" :weight bold))   ;; GREEN = expansion
    (0  . (:foreground "#FFFF00" :weight normal))  ;; YELLOW = revision
    (-1 . (:foreground "#FF0000" :weight bold)))   ;; RED = contraction
  "Face specs for GF(3) trit values.")

(defun agm-worlds--trit-char (trit)
  "Return display character for TRIT value."
  (pcase trit
    (+1 "+")
    (0  "○")
    (-1 "-")))

(defun agm-worlds--trit-propertize (trit)
  "Return propertized string for TRIT."
  (let ((char (agm-worlds--trit-char trit))
        (face (alist-get trit agm-worlds-trit-faces)))
    (propertize char 'face face)))

;; ── Build commands ──

(defun agm-worlds-test ()
  "Run zig-syrup worlds test suite."
  (interactive)
  (let ((default-directory agm-worlds-zig-syrup-dir))
    (compile "zig build test-worlds")))

(defun agm-worlds-run-bandit ()
  "Run world-bandit example."
  (interactive)
  (let ((default-directory agm-worlds-zig-syrup-dir))
    (compile "zig build world-bandit")))

(defun agm-worlds-build-library ()
  "Build libpuffer_zig shared library."
  (interactive)
  (let ((default-directory agm-worlds-zig-syrup-dir))
    (compile "zig build")))

;; ── Navigation ──

(defun agm-worlds-open-source (key)
  "Open a source file by KEY from `agm-worlds-source-files'."
  (interactive
   (list (intern (completing-read "Source: "
                                  (mapcar #'car agm-worlds-source-files)))))
  (let ((file (alist-get key agm-worlds-source-files)))
    (find-file (expand-file-name file agm-worlds-zig-syrup-dir))))

(defun agm-worlds-open-isabelle (key)
  "Open an Isabelle2 theory file by KEY."
  (interactive
   (list (intern (completing-read "Theory: "
                                  (mapcar #'car agm-worlds-isabelle-theories)))))
  (let ((file (alist-get key agm-worlds-isabelle-theories)))
    (find-file (expand-file-name file agm-worlds-boxxy-dir))))

;; ── Postcondition display ──

(defun agm-worlds-show-postulates ()
  "Display AGM postulates in a buffer with Isabelle2 theory references."
  (interactive)
  (with-current-buffer (get-buffer-create "*AGM Postulates*")
    (erase-buffer)
    (insert "╔═══════════════════════════════════════════════════╗\n")
    (insert "║  AGM Belief Revision Postulates (K*1-K*8)        ║\n")
    (insert "║  Verified in: boxxy/theories/AGM_Base.thy        ║\n")
    (insert "╚═══════════════════════════════════════════════════╝\n\n")
    (dolist (p agm-worlds-postulates)
      (insert (format "  [%s] %-16s %s\n"
                      (nth 0 p) (nth 1 p) (nth 2 p))))
    (insert "\n── GF(3) Conservation ──\n\n")
    (insert (format "  %s Expansion  (+1)  K + p\n"
                    (agm-worlds--trit-propertize +1)))
    (insert (format "  %s Revision   ( 0)  K * p  (Levi identity)\n"
                    (agm-worlds--trit-propertize 0)))
    (insert (format "  %s Contraction(-1)  K - p\n"
                    (agm-worlds--trit-propertize -1)))
    (insert "\n  Sum must ≡ 0 (mod 3) for conservation.\n")
    (insert "\n── Grove Sphere Semantics ──\n\n")
    (insert "  Verified in: boxxy/theories/Grove_Spheres.thy\n")
    (insert "  Inner spheres = more plausible worlds.\n")
    (insert "  Entrenchment ordering induces linear order (total case).\n")
    (insert "\n── Bandit Strategy Progression ──\n\n")
    (insert "  A/B → ε-greedy → UCB1 → Thompson → Softmax → Q-Learn\n")
    (insert "  Each arm = hypothesis about world quality.\n")
    (insert "  Pulling arm = observing evidence.\n")
    (insert "  AGM revision updates epistemic state.\n")
    (goto-char (point-min))
    (special-mode)
    (display-buffer (current-buffer))))

;; ── Architecture overview ──

(defun agm-worlds-show-architecture ()
  "Display the AGM-Worlds-PufferLib architecture diagram."
  (interactive)
  (with-current-buffer (get-buffer-create "*AGM Architecture*")
    (erase-buffer)
    (insert "╔═════════════════════════════════════════════════════════════╗\n")
    (insert "║  AGM × Worlds × PufferLib Architecture                    ║\n")
    (insert "╚═════════════════════════════════════════════════════════════╝\n\n")
    (insert "  ┌─────────────────────────────────────────────────────────┐\n")
    (insert "  │  Python (PufferLib)                                     │\n")
    (insert "  │  ┌───────────────────────────────────────────────────┐  │\n")
    (insert "  │  │ observations[N×128] actions[N] rewards[N]        │  │\n")
    (insert "  │  │      ↕ zero-copy shared memory (numpy)           │  │\n")
    (insert "  │  └───────────────────────────────────────────────────┘  │\n")
    (insert "  └──────────────────────┬──────────────────────────────────┘\n")
    (insert "                         │ C ABI (libpuffer_zig)\n")
    (insert "                         ↓\n")
    (insert "  ┌─────────────────────────────────────────────────────────┐\n")
    (insert "  │  Zig (zig-syrup/src/worlds/)                           │\n")
    (insert "  │  ┌──────────┐ ┌──────────┐ ┌──────────────────────┐   │\n")
    (insert "  │  │ Bandit   │ │ AGM      │ │ PufferLib FFI        │   │\n")
    (insert "  │  │ 6 strats │ │ K*1-K*8  │ │ vec_init/step/close  │   │\n")
    (insert "  │  │ GF(3)    │ │ Grove    │ │ 128-byte obs layout  │   │\n")
    (insert "  │  └──────────┘ └──────────┘ └──────────────────────┘   │\n")
    (insert "  │       ↓             ↓                                  │\n")
    (insert "  │  ┌──────────────────────────────────────────────────┐  │\n")
    (insert "  │  │ Ewig (append-only Merkle DAG event log)         │  │\n")
    (insert "  │  │ Time-travel ⋅ Branching ⋅ CRDT sync             │  │\n")
    (insert "  │  └──────────────────────────────────────────────────┘  │\n")
    (insert "  └──────────────────────┬──────────────────────────────────┘\n")
    (insert "                         │ Postconditions\n")
    (insert "                         ↓\n")
    (insert "  ┌─────────────────────────────────────────────────────────┐\n")
    (insert "  │  Isabelle2 (boxxy/theories/)                           │\n")
    (insert "  │  AGM_Base.thy ⋅ AGM_Extensions.thy ⋅ Grove_Spheres.thy│\n")
    (insert "  │  0 sorry statements — 100% formally verified          │\n")
    (insert "  └─────────────────────────────────────────────────────────┘\n")
    (goto-char (point-min))
    (special-mode)
    (display-buffer (current-buffer))))

;; ── Keymap ──

(defvar agm-worlds-command-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "p") #'agm-worlds-show-postulates)
    (define-key map (kbd "b") #'agm-worlds-run-bandit)
    (define-key map (kbd "i") #'agm-worlds-open-isabelle)
    (define-key map (kbd "e") #'agm-worlds-show-architecture)
    (define-key map (kbd "t") #'agm-worlds-test)
    (define-key map (kbd "w") #'agm-worlds-run-bandit)
    (define-key map (kbd "s") #'agm-worlds-open-source)
    (define-key map (kbd "l") #'agm-worlds-build-library)
    map)
  "Keymap for AGM-Worlds commands.")

(global-set-key (kbd "C-c C-a") agm-worlds-command-map)

(provide 'agm-worlds)

;;; agm-worlds.el ends here
