# Pinboard

macOS menu bar app that turns clipboard content (RTF / plain text / images) into
borderless always-on-top pin windows, built with Swift + AppKit (SwiftUI only for
settings).

## Build & run

```bash
./scripts/build-app.sh            # release bundle at .build/Pinboard.app
./scripts/build-app.sh debug      # debug bundle
open .build/Pinboard.app
swift build                       # compile only (no bundle)
swift test                        # headless unit tests (AppKit, runs in the user session)
```

`xcode-select` on this machine points at CommandLineTools, whose toolchain cannot
link the SwiftPM manifest. Export `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
before running `swift build` directly; `scripts/build-app.sh` does this automatically.

## URL scheme

```bash
open "pinboard://paste"   # pin current clipboard content
open "pinboard://show"    # show all pins
open "pinboard://hide"    # hide all pins (windows stay alive)
open "pinboard://toggle"  # any visible -> hide all, otherwise show all
```

A second app (`~/workspace/pinboard/build/DerivedData/Build/Products/Debug/Pin.app`)
also registers the `pinboard` scheme on this machine, so bare `open "pinboard://…"`
may launch that one instead. Target this build explicitly while testing:

```bash
open -a .build/Pinboard.app "pinboard://paste"
```

## Layout

`Sources/PinboardApp` is only `main.swift`; everything else is the `PinboardKit`
library so it can be unit tested (`@testable import PinboardKit`).

- `App` — delegate, main menu, status bar menu, URL router, toast, `HotKeyManager`
  (Carbon `RegisterEventHotKey`; default `⌃⌥⇧⌘P`, persisted in `Preferences`)
- `Core` — `PinContent`, `PinSnapshot`, `Preferences`, `HistoryStore`
- `History` — `HistoryView`/`HistoryWindowController` (search, Pin Again, Copy,
  Delete, Clear; list keeps `updatedAt`-desc records)
- `Clipboard` — pasteboard resolution (RTFD > RTF > image > HTML > plain)
- `Windows` — `PinPanel`, `PinRootView`, `PinWindowController`,
  `PinWindowManager`, drag/resize event loops, hover chrome
- `Text` — `TextPinView` / `PinTextView` (rich text editing), `TextFormatter`
  (attribute logic, unit tested), `TextFormatToolbar`
- `Image` — `ImagePinView` plus `Image/Annotation` (model, store with undo,
  renderer, canvas, toolbar, Core Image effects)
- `Settings` — SwiftUI preferences window

Window management never inspects content specifics: pin views conform to
`PinContentDisplaying`.

## Conventions that matter

- Pin panels disable AppKit cursor rects; `PinRootView.cursor(at:)` is the only
  place that decides pointer feedback, and it must stay in sync with
  `resizeEdge(at:)` so feedback matches the gesture.
- Annotations are stored in **image pixel coordinates**; the canvas only applies
  a scale transform, so the same `AnnotationRenderer` code paints the screen and
  the export. Never bake annotations into `baseImage`.
- `AnnotationStore.undoManager` has `groupsByEvent = false`; mutations must go
  through `transaction { … }` so one gesture is one undo step (edits happen
  inside modal mouse-tracking loops where run loop boundaries are unreliable).
- Text attribute changes go through `TextFormatter`, which brackets every edit
  with `shouldChangeText(in:replacementString:)` / `didChangeText()` (how AppKit
  records attribute-only undo) and transforms fonts run by run so untouched RTF
  runs keep their family, size and colour.
- Text pins build an explicit **TextKit 1** stack (`NSTextStorage` +
  `NSLayoutManager` + `NSTextContainer`). TextKit 2 lays out through the display
  cycle, which is skipped while the run loop is in `NSEventTrackingRunLoopMode`,
  so text would not re-wrap during a live edge resize. `TextPinView.syncWrapWidth()`
  additionally forces `ensureLayout(for:)` + `sizeToFit()` on every geometry change.
- Colour controls use `ColorSwatchButton` + a custom `ColorPickerView` popover,
  never `NSColorWell` or the shared `NSColorPanel`: a well in a non-activating
  panel never activates, and an orphaned colour panel with a nil target forwards
  `changeColor:` up the responder chain — letting a background pick silently
  overwrite the foreground colour.
- Opacity is per-pin (`PinWindowController.opacity`, context-menu slider),
  not a global preference — new pins are always 100%. Text pins' transparent
  background is a separate concept and must stay regardless of opacity.
- Annotation style is per-annotation (`Annotation.style`), editable via the
  toolbar when a shape is selected (`canvas.updateSelectedStyle` — never the
  global `Preferences` seed). `AnnotationStyle.fontName` is optional so old
  payloads still decode. Settings only hosts Keyboard Shortcuts + History;
  other preferences persist silently as fixed defaults.
- History: one directory per record under
  `~/Library/Application Support/Pinboard/History/<uuid>/` (`record.json` +
  payload files) so a corrupt record can only lose itself. Pins link to their
  record via `PinWindowController.historyRecordID`; edits call
  `contentDidChange()` and are debounced (`PinWindowManager.historyWriteDelay`)
  into `HistoryStore.upsert` — the record holds the *latest* state, never
  duplicates. Image records store base pixels + `annotations.json` (restore via
  `AnnotationStore.restore`), never a flattened bitmap. Retention prunes by
  `updatedAt`, always sparing records whose pins are still open.
  `PinWindowManager.historyStore` is nil by default — tests inject a temp-dir
  store.
- Both floating strips (`TextFormatToolbar`, `AnnotationToolbar`) subclass
  `AttachedToolbar`: a child panel below the pin. Controls must be
  `FirstMouseButton`/`FirstMouseSlider` because pin panels are non-activating.
  A pin stays in edit mode while its own toolbar, the colour panel or the font
  panel holds key focus (see `handleResignKey`).

## Verification notes

- The agent sandbox has no Screen Recording permission, so `screencapture` fails.
  Window geometry can still be inspected with `CGWindowListCopyWindowInfo`
  (owner PID + bounds + layer), which is how pin creation/hide/show was verified.
- Status items do not appear in `CGWindowListCopyWindowInfo`; check the
  `com.apple.appkit.status-items` scene in `log show --predicate 'process == "Pinboard"'`.
