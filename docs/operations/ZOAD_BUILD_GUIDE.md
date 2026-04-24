# ZOAD Build Configuration Guide

## Problem Fixed: Build Hang with `zig build zoad`

The `zig build zoad` command was **hanging indefinitely** due to:

1. **Hardcoded Nix paths** in `build.zig` that didn't exist on non-Nix systems
2. **Missing notcurses library** and development headers
3. **Zoad being included in the default install step**, causing all builds to fail

### What Changed

#### Before (Hanging):
- Lines 1721 and 1748 had hardcoded Nix store paths for notcurses:
  ```zig
  nc_backend_mod.addIncludePath(.{ .cwd_relative = "/nix/store/vp4mqyfj800wyhc92d888g3glzl3dzn7-notcurses-3.0.17-dev/include" });
  zoad_exe.addLibraryPath(.{ .cwd_relative = "/nix/store/2fv3qgr6wnsxkxanhl31sry78rn1vk74-notcurses-3.0.17/lib" });
  ```
- These paths blocked the build from even starting properly

#### After (Fixed):
- Removed hardcoded Nix paths
- **Commented out** `b.installArtifact(zoad_exe)` to exclude zoad from default build
- Updated build step documentation
- `zig build` now **completes successfully** without zoad
- `zig build zoad` fails **immediately** with clear error message about missing notcurses

## Building ZOAD

### Option 1: Install notcurses via Flox (Recommended for Nix systems)

```bash
cd zig-syrup
flox activate --init
# Now notcurses should be available
zig build zoad
```

### Option 2: Install notcurses via Homebrew (macOS)

```bash
brew install notcurses
zig build zoad
```

### Option 3: Install notcurses via system package manager (Linux)

```bash
# Ubuntu/Debian
sudo apt-get install libnotcurses-dev libnotcurses-core-dev

# Fedora/RHEL
sudo dnf install notcurses-devel

zig build zoad
```

### Option 4: Skip ZOAD entirely

The default `zig build` now works fine without notcurses:

```bash
zig build          # Builds all non-ZOAD targets
zig build zeta-cli # Build other tools
```

## Architecture

ZOAD (Zig Agent Desktop) is a TUI interface for interacting with ACP agents:

- **Backend**: notcurses (C library for terminal rendering)
- **Layout engine**: retty (constraint-based UI layout)
- **Transport**: ACP (Agent Client Protocol)
- **Theme**: Dracula color scheme
- **Features**: 
  - Real-time agent interaction
  - Sidebar project browser
  - Message stream with tool tracking
  - Damage-aware rendering (only redraws changed cells)

## File Structure

```
src/zoad.zig                    # Main ZOAD app (TUI loop, input handling, rendering)
src/notcurses_backend.zig       # C bindings to notcurses library
build.zig                       # Build configuration (lines 1719-1777)
```

## Troubleshooting

### Build fails with "unable to find dynamic system library 'notcurses'"

This means notcurses isn't installed. Try one of the installation options above.

### Build hangs with `zig build`

The hanging issue has been fixed. If you still see hangs:
1. Ensure your `build.zig` doesn't have hardcoded Nix paths
2. Check that `b.installArtifact(zoad_exe)` is commented out
3. Run `rm -rf .zig-cache && zig build` to clear cache

### notcurses library found but headers missing

You need the development headers:
- **macOS**: `brew install notcurses`
- **Linux**: Install `libnotcurses-dev` or equivalent

## Future Improvements

- [ ] Detect notcurses availability at build time and skip gracefully
- [ ] Provide a stub backend for terminal environments without notcurses
- [ ] Add build option: `zig build --no-zoad` to explicitly skip
- [ ] Use pkg-config to find notcurses paths automatically
