# Pinboard

A lightweight macOS menu-bar utility that turns clipboard content — plain
text, rich text (RTF/RTFD), or images — into independent floating windows
that stay on top of ordinary apps. Text pins are directly editable with full
RTF fidelity; image pins support non-destructive annotation and crop. Built
entirely with native Swift/AppKit — no Electron, no WebView.

## Features

- **Pin the clipboard** — one action converts text, RTF, or an image into a
  borderless always-on-top window. Multiple pins coexist independently.
- **Editable rich text** — click to type, select, undo/redo; fonts, colors,
  backgrounds and paragraph styles survive import, editing and copy-out.
- **Image annotation** — rectangle, ellipse, arrow, line, freehand, text,
  highlight, blur, mosaic and crop, all non-destructive and undoable.
- **Pin history** — every pin is recorded locally (latest edited state,
  including editable annotation data), searchable, re-pinnable, with
  configurable retention (default 30 days).
- **Transparent text pins** — text floats directly over the desktop; only
  runs you explicitly give a background to show one.
- **Global hotkey** — `⌃⌥⇧⌘P` (Hyper+P) pins the clipboard from anywhere;
  re-recordable in Settings.
- **URL Scheme** — drive Pinboard from scripts and other apps (below).

## Global Shortcut

Press `Control + Option + Shift + Command + P` (`⌃⌥⇧⌘P`) in any app to pin
the current clipboard. Change, clear or disable it under **Settings →
Keyboard Shortcuts**. The default can be restored via **Reset to Default**.

## URL Scheme

Pinboard registers the `pinboard` URL scheme for external control:

| URL | Description |
| --- | ----------- |
| `pinboard://paste` | Pin current clipboard content |
| `pinboard://show` | Show all pinned windows |
| `pinboard://hide` | Hide all pinned windows |
| `pinboard://toggle` | Toggle visibility of pinned windows |

Examples (Terminal):

```bash
open "pinboard://paste"   # pin what's on the clipboard right now
open "pinboard://hide"    # hide every pin without destroying it
open "pinboard://show"    # bring them all back
open "pinboard://toggle"  # hide all if any are visible, else show all
```

Notes:

- `show` / `hide` / `toggle` never recreate windows — they only change
  visibility, preserving each pin's content, frame and editing state.
- `toggle` hides everything when at least one pin is visible, otherwise
  shows all hidden pins; with no pins it does nothing.
- Unknown commands are ignored safely.
- Commands do not steal keyboard focus from the app you're using.
- The same commands are available from the menu bar icon; both paths share
  the same window-management logic.

## Building

Requires Xcode (Swift toolchain) on macOS 13+.

```bash
./scripts/build-app.sh          # builds .build/Pinboard.app (release)
open .build/Pinboard.app        # launch
swift test                      # headless unit tests
```

If `xcode-select` points at CommandLineTools, prefix SwiftPM commands with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

## Data & Privacy

All clipboard processing happens locally — nothing is uploaded. Pin history
is stored under `~/Library/Application Support/Pinboard/History/` and can be
cleared or bounded by retention in the History window / Settings.
