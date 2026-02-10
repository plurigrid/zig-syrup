# Emacs Color Bridge

Rapidly update Emacs theme colors from broadcasted BCI color stream.

## Overview

Bridges the `color.index.syrup` NATS stream (from `nats_color_bridge.py`) directly into Emacs via `emacsclient`. Colors update in real-time as the SSE stream broadcasts ColorEpoch events.

**Key features:**
- Listens to SSE :7070 for incoming color data
- Extracts hex color, converts to RGB with luminance calculation
- Auto-selects black or white text for contrast
- Applies background + foreground via `set-face-*`
- Updates Emacs mode-line, cursor, and default face
- Triggers `color-index-update-hook` for downstream integrations

## Quick Start

### 1. Start Emacs Server

In Emacs, enable the server:
```elisp
M-x server-start
```

Or add to `.emacs`:
```elisp
(server-start)
```

### 2. Start Color Stream

If not already running, start `nats_color_bridge.py`:

```bash
cd /Users/bob/i/zig-syrup/tools/openbci_host/nuworlds
python nats_color_bridge.py synthetic_eeg.csv --realtime --sse-port 7070
```

### 3. Initialize Emacs Hook

```bash
nu emacs_color_bridge.nu main init-emacs
```

This installs the `color-index-update-hook` in your Emacs process.

### 4. Start Bridge Listener

**One-shot:**
```bash
nu emacs_color_bridge.nu main listen
```

**Daemon (auto-restart on failure):**
```bash
nu emacs_color_bridge.nu main daemon &
```

## Commands

### `main listen`
Stream colors and apply to Emacs in real-time.

```bash
nu emacs_color_bridge.nu main listen \
  --url "http://localhost:7070/events" \
  --emacs-socket "emacs"
```

Options:
- `--url`: SSE endpoint (default: `http://localhost:7070/events`)
- `--emacs-socket`: Emacs server socket name (default: `emacs`)
- `--no-cache`: Skip theme cache (default: off)

### `main daemon`
Background daemon with auto-restart on connection loss.

```bash
nu emacs_color_bridge.nu main daemon &
```

PID file: `~/.cache/emacs_bci_bridge.pid`

### `main init-emacs`
Install Emacs hook for updates.

```bash
nu emacs_color_bridge.nu main init-emacs
```

### `main test`
Test connection with a single color update.

```bash
nu emacs_color_bridge.nu main test \
  --color "#FF6B9D" \
  --state "test"
```

### `main status`
Check SSE + Emacs connection status.

```bash
nu emacs_color_bridge.nu main status
```

## Architecture

### Data Flow

```
NATS (color.index) → SSE :7070 (JSON) → stream-sse → apply-to-emacs → emacsclient
```

### Color Conversion

```
Hex (#RRGGBB) → RGB [0-255] → Luminance L* → Text Color (white/black)
```

Luminance uses CIE1931 relative luminance formula for proper contrast.

### Elisp Generated

Each color update generates code like:

```elisp
(progn
  (set-face-background 'default "#FF6B9D")
  (set-face-foreground 'default "black")
  (set-face-background 'mode-line "#FF6B9D")
  (set-face-foreground 'mode-line "black")
  (setq color-index-current
    (list :hex "#FF6B9D" :rgb (list 255 107 157) :state "focused" :timestamp ...))
  (run-hooks 'color-index-update-hook))
```

## Integration Hooks

Listen for color updates in your Emacs config:

```elisp
(add-hook 'color-index-update-hook
  (lambda ()
    (message "[BCI] Color: %s State: %s"
      (plist-get color-index-current :hex)
      (plist-get color-index-current :state))))
```

Or integrate with other packages:

```elisp
(add-hook 'color-index-update-hook
  (lambda ()
    ;; Sync with linum/display-line-numbers
    (set-face-foreground 'line-number
      (face-foreground 'default))

    ;; Notify other major modes
    (force-mode-line-update)))
```

## Troubleshooting

### "Could not connect to Emacs"

**Check 1:** Is Emacs running?
```bash
pgrep -l emacs
```

**Check 2:** Is server enabled?
```bash
M-x server-start
```

**Check 3:** Try explicit socket:
```bash
emacsclient --socket-name emacs -e "(+ 1 1)"
```

### "Failed to connect to SSE: http://localhost:7070/events"

**Check 1:** Is nats_color_bridge.py running?
```bash
curl -v http://localhost:7070/events
```

**Check 2:** Different port?
```bash
python nats_color_bridge.py synthetic_eeg.csv --sse-port 8080
nu emacs_color_bridge.nu main listen --url "http://localhost:8080/events"
```

### Colors not updating

**Check logs:**
```bash
# See daemon output
tail -f ~/.cache/emacs_bci_bridge.log
```

**Test in Elisp:**
```elisp
(message "color-index-current: %s" color-index-current)
(run-hooks 'color-index-update-hook)
```

## Files

- `emacs_color_bridge.nu` — Main nuworlds bridge script
- `nats_color_bridge.py` — ColorEpoch → NATS/SSE source
- `themes.nu` — Reference for color application patterns

## See Also

- [nats_color_bridge.py](./nats_color_bridge.py) — Color stream source
- [themes.nu](./themes.nu) — Terminal color themes
- [valence_bridge.py](./valence_bridge.py) — Fisher-Rao → Color pipeline
