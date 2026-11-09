# Pinboard

A macOS menu-bar utility that turns clipboard content (plain text, rich text
RTF/RTFD, or images) into independent floating windows that stay on top of
ordinary apps. Text pins are directly editable with full RTF fidelity, as
plain text in the default font, or as Markdown source with rendered display;
image pins support non-destructive annotation and crop. Built with Swift and
AppKit.

## Features

- **Pin the clipboard**: One action converts text, RTF, or an image into a
  borderless always-on-top window. Multiple pins coexist independently.
- **Pins panel in the menu bar**: Click the status icon to see all current
  pins with content previews; hidden pins are dimmed. A compact icon strip
  switches between Pins and History, pins the clipboard with the plus icon,
  and keeps Settings and Quit available while lists scroll. The eye, crossed
  eye and close icons in the strip act on all pins; those inside a card act on
  that pin. Closing a pin keeps its saved history. Empty Pins shows only the
  strip. Hover an action for its name; every icon also has an accessibility
  label. Click a card to show that pin; `⌘F` jumps to History search. Click
  outside, press Escape or click the status icon again to dismiss the panel.
- **Quick actions**: New pins appear at the pointer, clamped to the screen.
  Double-click an idle pin to copy its content and close it. Use the pencil or
  context menu to edit; double-click within an active editor keeps its normal
  selection behavior.
- **Editable rich text**: Use the pencil to type, select, undo/redo; fonts, colors,
  backgrounds and paragraph styles survive import, editing and copy-out.
  Text copied from web pages drops page-layout leftovers (container margins,
  page backgrounds, near-black or near-white body colours) while keeping
  emphasis, links and coloured text.
- **Three text modes**, in order: **Rich Text Format**, **GitHub Flavored
  Markdown**, **Plain Text**. Rich Text Format preserves formatting; GFM uses
  cmark-gfm for headings, lists, aligned tables, task lists, strikethrough,
  autolinks and images (including linked images), and edits as source. Plain
  Text drops formatting and uses PingFang SC 14. See [GFM support](docs/GFM.md)
  for the native renderer's compatibility boundaries. Switch
  globally under **Settings → Text**,
  or per pin via the window's context menu; a per-pin switch stops that
  window from following the global default.
- **Markdown themes**: Colour a whole Markdown pin, paper included:
  *Default* (system colours) and *Everforest Dark Hard*, picked with a live
  preview under **Settings → Text**. The source you edit stays the same; a
  pin you switched to a transparent background keeps it.
- **Image annotation**: Rectangle, ellipse, tapered fancy arrows (drag the
  midpoint handle to curve), line, freehand, text (plain, solid pill box and
  outlined box styles), numbered counters, highlighter (rectangle and freehand
  modes), 3-in-1 redaction (irreversible mosaic, irreversible secure blur and
  opaque solid-colour fill), spotlight (dimmed backdrop with rectangle or
  ellipse cutouts) and crop, all non-destructive and undoable. Single-key
  tools: V/R/O/A/L/P/T/N/H/M/B/S/C. Shift constrains squares/circles and snaps
  lines/arrows to 45°. Drag corner, endpoint or curve handles to reshape; arrow
  keys nudge (Shift = 10 points), ⌘D duplicates, Delete removes. A slider drag
  is one undo step. Interaction ideas follow CleanShot X and
  [Snapzy's annotation editor](https://github.com/duongductrong/Snapzy/blob/master/docs/ANNOTATE.md).
- **Charts in pasted messages**: When a copied message ships its image only
  as an `<img>` reference (typical for Discord, Slack and web chat), the
  picture is fetched and shown inside the pin instead of an empty
  placeholder. Markdown pins show `![alt](url)` pictures the same way.
- **Pin history**: Every pin is recorded locally (latest edited state,
  including editable annotation data). Open History in the menu bar panel to
  search, preview, pin again, copy or delete an entry without leaving the panel.
  In an entry's preview, Return pins it again, Delete removes it and Escape
  goes back to the list.
  Clear History reveals cancel and red trash icons for confirmation and keeps
  records associated with open pins. Retention is configurable in Settings.
- **Transparent text pins**: Text floats directly over the desktop; only
  runs you explicitly give a background to show one.
- **Global hotkey**: `⌃⌥⇧⌘P` (Hyper+P) pins the clipboard from anywhere;
  re-recordable in Settings.
- **URL Scheme**: Drive Pinboard from scripts and other apps (below).

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

- `show` / `hide` / `toggle` never recreate windows; they only change
  visibility, preserving each pin's content, frame and editing state.
- `toggle` hides everything when at least one pin is visible, otherwise
  shows all hidden pins; with no pins it does nothing.
- Unknown commands are ignored safely.
- `open -a Pinboard note.md` pins a file: Markdown (`.md`, `.markdown`) opens
  as a Markdown pin, RTF/RTFD as rich text, images as image pins and other
  UTF-8 text as a text pin.
- Commands do not steal keyboard focus from the app you're using.
- The status panel provides pin creation and individual or bulk Show/Hide/Close
  controls through the same window manager. `toggle` remains available via URL.

## Installation

Download a DMG from [GitHub Releases](https://github.com/vizmoe/pinboard/releases):
choose `arm64` for Apple Silicon or `x86_64` for Intel. Open the disk image,
drag `Pinboard.app` onto the **Applications** shortcut, then eject the image
and open Pinboard from Applications. The minimum supported macOS version is defined
in [Info.plist](Resources/Info.plist) (`LSMinimumSystemVersion`).

The app inside each DMG is ad-hoc signed and is **not notarized**. If macOS blocks the
first launch, follow Apple's [instructions for opening an app from an unidentified
developer](https://support.apple.com/en-us/102445) in System Settings → Privacy &
Security. Approve the app only if you trust the downloaded release.

Each release includes `SHA256SUMS`. To verify one downloaded DMG, keep both files
in the same directory and check the matching entry, for example:

```bash
grep 'macos-arm64[.]dmg$' SHA256SUMS | shasum -a 256 -c -
```

## Building

Requires Xcode (Swift toolchain) on macOS 13+.

```bash
./scripts/build-app.sh          # builds .build/Pinboard.app (release)
open .build/Pinboard.app        # launch
swift test                      # headless unit tests
```

If `xcode-select` points at CommandLineTools, prefix SwiftPM commands with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

## Releasing

The [release workflow](.github/workflows/release.yml) runs tests and verifies
installable DMGs on both supported architectures for PRs and `main`.
Only version tags publish a Release, after all checks pass.

Update `CFBundleShortVersionString` and `CFBundleVersion` in
[Info.plist](Resources/Info.plist) through a PR. Once merged, tag the verified
`main` commit with `v` followed by that version and push the tag:

```bash
git fetch origin
git switch main
git pull --ff-only origin main
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
git tag -a "v$VERSION" origin/main -m "Pinboard v$VERSION"
git push origin "v$VERSION"
```

Use a fresh version for each release. Tags must have the form `vMAJOR.MINOR.PATCH`
and match the bundle version. Failed runs can resume an unpublished draft;
the workflow refuses to overwrite a published release.

To build and verify a release DMG for the current Mac locally:

```bash
./scripts/package-release.sh
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
./Tests/ReleasePackagingTests.sh "v$VERSION" "$(uname -m)"
```

DMGs and checksums are written to the ignored `dist/` directory. Verification
mounts each image read-only, checks the Applications shortcut, and copies the
app to a temporary directory to validate installation without replacing an
existing app. Test volumes are detached when verification exits.

## Data & Privacy

All clipboard processing happens locally. The one exception is deliberate and
narrow: when pasted content references its image only by URL (no image bytes on
the clipboard; common for Discord, Slack and web chat) or when a Markdown pin
contains `![alt](url)`, that single image is downloaded once so the pin can
show it. Nothing is ever uploaded and the request carries no cookies or URL
credentials. HTTP(S) image connections reject local/private/reserved addresses
at socket creation, including redirect destinations; downloads are limited to
20 MiB each, four concurrent requests and 64 pending URLs. Local `file:` images
and image `data:` URIs remain supported. Raw HTML in Markdown is shown literally. Pin history is
stored under `~/Library/Application Support/Pinboard/History/` and can be
cleared in the menu bar's History page or bounded by retention in Settings.
