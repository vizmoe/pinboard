# Pinboard

A lightweight macOS menu-bar utility that turns clipboard content — plain
text, rich text (RTF/RTFD), or images — into independent floating windows
that stay on top of ordinary apps. Text pins are directly editable with full
RTF fidelity, as plain text in the default font, or as Markdown source with
rendered display; image pins support non-destructive annotation and crop.
Built entirely with native Swift/AppKit — no Electron, no WebView.

## Features

- **Pin the clipboard** — one action converts text, RTF, or an image into a
  borderless always-on-top window. Multiple pins coexist independently.
- **Editable rich text** — click to type, select, undo/redo; fonts, colors,
  backgrounds and paragraph styles survive import, editing and copy-out.
- **Three text modes** — Rich Text keeps everything above; Plain Text drops
  formatting and shows the text in the default font (PingFang SC 14);
  Markdown idles as a rendered document (headings, lists, tables, code,
  links — and `![alt](url)` pictures) and edits as raw source. Switch
  globally under **Settings → Text**,
  or per pin via the window's context menu; a per-pin switch stops that
  window from following the global default.
- **Markdown themes** — colour a whole Markdown pin, paper included:
  *Default* (system colours) and *Everforest Dark Hard*, picked with a live
  preview under **Settings → Text**. The source you edit stays the same; a
  pin you switched to a transparent background keeps it.
- **Image annotation** — rectangle, ellipse, arrow, line, freehand, text,
  highlight, blur, mosaic and crop, all non-destructive and undoable.
- **Charts in pasted messages** — when a copied message ships its image only
  as an `<img>` reference (typical for Discord, Slack and web chat), the
  picture is fetched and shown inside the pin instead of an empty
  placeholder. Markdown pins show `![alt](url)` pictures the same way.
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

All clipboard processing happens locally. The one exception is deliberate and
narrow: when pasted content references its image only by URL (no image bytes on
the clipboard; common for Discord, Slack and web chat) or when a Markdown pin
contains `![alt](url)`, that single image is downloaded once so the pin can
show it — nothing is ever uploaded, the request carries no cookies, and remote
images are only fetched when the content actually needs them. Pin history is
stored under `~/Library/Application Support/Pinboard/History/` and can be
cleared or bounded by retention in the History window / Settings.
