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
- `Core` — `PinContent`, `PinSnapshot`, `Preferences`, `HistoryStore`,
  `TextContentMode`
- `History` — `HistoryPanelViewController`/`HistoryViewModel` inside the status
  popover (search, preview, Pin Again, Copy, Delete, confirmed Clear; list keeps
  `updatedAt`-desc records). Clear preserves records associated with open pins.
- `Clipboard` — pasteboard resolution (RTFD > RTF > image > HTML > plain),
  `HTMLImages` (parses `<img src>` out of pasted HTML), `RemoteImageLoader`
  (fetches remote images off the main thread; session cache)
- `Windows` — `PinPanel`, `PinRootView`, `PinWindowController`,
  `PinWindowManager`, drag/resize event loops, hover chrome
- `Text` — `TextPinView` / `PinTextView` (rich text / plain text / Markdown
  source editing), `TextFormatter` (attribute logic, unit tested),
  `TextFormatToolbar`, `TextDefaults` (PingFang SC 14, the app-wide default
  typography), `DeferredImages` (attachment tags for images that load later)
- `Markdown` — `MarkdownRenderer` (cmark-gfm tree → display-only AppKit attributed
  string; tables use `NSTextTable`, images use `DeferredImages`) and `MarkdownTheme`.
  GFM support and deliberate presentation differences are in `docs/GFM.md`.
- `SafeImageDownload` — C/libcurl transport; checks the resolved socket address
  on every connection/redirect and caps response bytes while streaming.
- `Image` — `ImagePinView` plus `Image/Annotation` (model, store with undo,
  renderer, canvas, toolbar, Core Image effects)
- `Settings` — SwiftUI preferences window

Window management never inspects content specifics: pin views conform to
`PinContentDisplaying`.

## Conventions that matter

- Pin panels disable AppKit cursor rects; `PinRootView.cursor(at:)` is the only
  place that decides pointer feedback, and it must stay in sync with
  `resizeEdge(at:)` so feedback matches the gesture.
- Idle pins drag on a single click and copy-and-close on double-click. Editing
  starts from the pencil/context menu; active editors retain native double-click
  behavior. `copyAndClose` commits edits and closes only after clipboard success.
  Placement captures the pointer once at `createPin`, with screen-edge clamping.
- Annotations are stored in **image pixel coordinates**; the canvas only applies
  a scale transform, so the same `AnnotationRenderer` code paints the screen and
  the export. Never bake annotations into `baseImage`.
- `AnnotationStore.undoManager` has `groupsByEvent = false`; mutations must go
  through `transaction { … }` so one gesture is one undo step (edits happen
  inside modal mouse-tracking loops where run loop boundaries are unreliable).
  Slider tracking opens an outer undo group. Control-point drags preview locally
  and commit once; handles are hit-tested in view points. Decode annotation
  payloads at the history boundary before creating a pin; corrupt data reports an
  error rather than becoming an unannotated image.
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
  not a global preference — new pins are always 100%. Text pins paint an
  opaque paper (`BackgroundPolicy.automatic`); opacity only changes the
  window's alpha.
- Annotation style is per-annotation (`Annotation.style`), editable via the
  toolbar when a shape is selected (`canvas.updateSelectedStyle` — never the
  global `Preferences` seed). `AnnotationStyle.fontName` is optional so old
  payloads still decode. Settings hosts Keyboard Shortcuts, Pins (placement),
  Text (mode and Markdown theme) and History.
- Text pins have three modes (`TextContentMode`). A Markdown pin's canonical
  content is the **raw source** (kept as the `.text` attributed string), the
  idle display is `MarkdownRenderer.render(source)`, and editing shows the
  source with no format toolbar; a Plain Text pin shows the same characters in
  `TextDefaults` typography (PingFang SC 14) with formatting dropped; a rich
  pin is unchanged. All default typography lives in `TextDefaults` —
  `ClipboardReader.defaultTextAttributes`, `TextFormatter.baseFont`,
  `MarkdownRenderer.Style.default` and the raw-source editor all read it.
  PingFang SC has no italic face, so `MarkdownRenderer` adds `obliqueness` to
  emphasised runs when the resolved font lacks the trait.
  `Preferences.textMode` is the default for new pins and for pins whose
  `hasExplicitTextMode` is false; the context menu's *Text Mode* submenu sets
  it explicitly. `setTextMode` keeps a one-step `modeBackup` so switching back
  before the next edit restores the exact previous representation.
- Markdown themes (`MarkdownTheme`, picked in Settings → Text, persisted as
  `Preferences.markdownTheme`) are display-only, like the rendered document:
  they colour the render, the raw-source editor (text, caret, selection,
  `linkTextAttributes` — AppKit paints `.link` runs with those, not the run
  colour) and the pin paper (`PinRootView.themedBackground`). `.standard`
  keeps the system colours on the standard text paper; `everforestDarkHard`
  paints its bg0 paper. A programmatic `setBackgroundVisible` sets
  `BackgroundPolicy.explicit`, which `applyThemeBackground` always honours.
  Rich and plain pins keep their own colours, and switching a themed pin to
  rich text re-renders with the standard palette. The palette literals are the
  published Everforest Dark Hard values.
- History: one directory per record under
  `~/Library/Application Support/Pinboard/History/<uuid>/` (`record.json` +
  payload files) so a corrupt record can only lose itself. Pins link to their
  record via `PinWindowController.historyRecordID`; edits call
  `contentDidChange()` and are debounced (`PinWindowManager.historyWriteDelay`)
  into `HistoryStore.upsert` — the record holds the *latest* state, never
  duplicates. Image records store base pixels + `annotations.json` (restore via
  `AnnotationStore.restore`), never a flattened bitmap. Text records store the
  source RTF plus `textMode` (absent = legacy = rich text; `upsert` without a
  mode keeps the stored one); re-pinning restores the record's mode explicitly.
  Retention prunes by `updatedAt`, always sparing records whose pins are still
  open. `PinWindowManager.historyStore` is nil by default — tests inject a
  temp-dir store. A pin created before the store exists gets its record when
  the store is installed: `pinboard://paste` at launch delivers its URL event
  before `applicationDidFinishLaunching` runs. `historyWasDeleted` keeps a pin
  whose record the user deleted out of that adoption.
- Both floating strips (`TextFormatToolbar`, `AnnotationToolbar`) subclass
  `AttachedToolbar`: a child panel below the pin. Controls must be
  `FirstMouseButton`/`FirstMouseSlider` because pin panels are non-activating.
  A pin stays in edit mode while its own toolbar, the colour panel or the font
  panel holds key focus (see `handleResignKey`).
- Markdown images become tagged attachments (`DeferredImages.sourceAttribute` /
  `altAttribute`); linked images retain both the image source and the enclosing
  link. cmark-gfm extensions are explicitly enabled, including autolink.
- Images the text only references are resolved by
  `TextPinView.resolveDeferredImages`, which runs after
  `PinWindowManager.createPin` places the pin (so they are sized against the
  real wrap width), after `setTextMode` and after `endEditing` (a re-render can
  bring new ones). `data:`/`file:` read locally, `http(s)` go through
  `RemoteImageLoader` (injected as `PinWindowManager.remoteImageLoader` so
  tests never hit the network; successful downloads are cached for the
  session, so re-rendering a Markdown pin does not refetch). A source that
  cannot be loaded leaves the producer's alt text in place — pasted HTML has
  none, so its placeholder simply stays empty. `TextPinView.imageLoader` is
  the view-level knob; the manager overwrites it at creation.
- AppKit's HTML importer never resolves `<img>` content — not `http(s):`, not
  `file:`, not even `data:` URIs; it leaves a placeholder attachment.
  `ClipboardReader` therefore tags each `<img>` with
  `DeferredImages.sourceAttribute`, and `PinWindowManager.createPin` asks the
  view to `resolveDeferredImages()` once the window exists. Installed images
  are fitted to the wrap width and the window `growToFitContent()`, and RTFD
  serialization encodes the attachment from the image, so copy-out and history
  carry the real pixels. `TextPinView.displayAttributedString` measures the
  live text storage while idle (a fresh Markdown render would measure empty
  placeholders, so the window would never grow for an arriving picture).

## Verification notes

- A running Pinboard keeps its old binary: after changing app code, rebuild
  (`./scripts/build-app.sh`) and relaunch the instance (`pkill -x Pinboard`
  then `open .build/Pinboard.app`) so the visible app matches the source.
- The agent sandbox has no Screen Recording permission, so `screencapture` fails.
  Window geometry can still be inspected with `CGWindowListCopyWindowInfo`
  (owner PID + bounds + layer), which is how pin creation/hide/show was verified.
- Status items do not appear in `CGWindowListCopyWindowInfo`; check the
  `com.apple.appkit.status-items` scene in `log show --predicate 'process == "Pinboard"'`.
