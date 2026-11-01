# Snapshot review and implementation follow-up

Reviewed the current repository snapshot at `33c97c5`, then implemented the
requested repairs and interaction changes. No target branch was supplied;
this is not presented as a detached-worktree comparison. Findings below describe
the original behavior and link to the corresponding repair in the working tree.

1. **[P1] Reject private destinations before connecting to pasted image URLs.**
   The original loader passed arbitrary clipboard HTTP(S) URLs and redirects to
   URLSession, allowing pasted content to contact loopback/private services.
   [Socket policy](../Sources/SafeImageDownload/SafeImageDownload.c) now checks
   the exact DNS-resolved address used to connect, including redirects; credentials
   and proxy routing are disabled. Local-address and actual transport tests cover
   rejection. Public IP HTTPS was verified; the machine's Fake-IP DNS mapping of
   GitHub to 198.18.54.19 is intentionally rejected and remains a compatibility
   limitation for domain-based remote images on this network.

2. **[P2] Enforce image limits while downloading, with bounded concurrency.**
   The former data-task completion checked size after buffering the entire body,
   and repeated renders could start overlapping downloads. The C receive callback
   now aborts oversized transfers; [RemoteImageLoader](../Sources/PinboardKit/Clipboard/RemoteImageLoader.swift)
   limits active requests to four, pending URLs to 64, and coalesces repeated URLs.
   Cache/coalescing tests pass, and the public HTTPS smoke test returns no bytes
   when its size limit is exceeded.

3. **[P2] Update theme paper even after an explicit opacity choice.**
   `applyThemeBackground` used to return before updating the palette whenever
   the user had chosen opaque/transparent paper. A later theme or mode change
   could leave text on the wrong background. [PinWindowController](../Sources/PinboardKit/Windows/PinWindowController.swift)
   now preserves only the visibility choice while updating the paper. A regression
   test reproduced the stale background before the fix and passes afterward.

4. **[P2] Commit annotation text before copy/export.**
   Rendering read only the committed store, so an open text field's last draft
   was missing from the exported image.
   [ImagePinView](../Sources/PinboardKit/Image/ImagePinView.swift) now commits the
   draft before rendering. Tests cover draft export and deleting a draft without
   resurrecting it on edit completion.

5. **[P2] Reject corrupt annotation payloads instead of silently removing markup.**
   The previous `try?` decode returned without annotations; a repin/copy could
   then produce the unmarked original, including loss of blur or mosaic regions.
   [AnnotationStore](../Sources/PinboardKit/Image/Annotation/AnnotationStore.swift)
   now decodes with throwing validation before pin construction. The history UI
   reports the error and refuses the operation; missing required annotation files
   also fail reading. Valid legacy font fields still decode. Live encoding no
   longer converts an invariant failure into absent annotation data.

6. **[P2] Hit-test freehand segments, not only sampled points.**
   Fast strokes can have distant samples; the visible line between them could
   not be selected. [Annotation](../Sources/PinboardKit/Image/Annotation/Annotation.swift)
   now checks segment distances using its existing geometry helper. The original
   two-point stroke regression fails before the fix and passes afterward.

7. **[P2] Report PNG save failures at the UI boundary.**
   The save panel completion previously ignored `Data.write` errors, so a failed
   export appeared to finish normally. [ImagePinView](../Sources/PinboardKit/Image/ImagePinView.swift)
   now writes atomically and shows an error alert for encoding or write failure.

The GFM audit and its explicit presentation limitations are in [GFM.md](GFM.md).
Changes also implement the requested text-mode order, Snapzy-inspired annotation
controls, current-pin menu, double-click copy-and-close, and pointer placement.
Snapzy was used as an interaction reference; no Snapzy source was copied.

Validation: 229 XCTest cases pass; release bundle builds; `git diff --check` and
bundle signature verification pass. The existing running app was left open to
preserve live pins, since launch restoration is not implemented. The replacement
bundle is `.build/Pinboard.app` and takes effect after restarting it.

Overall verdict after repairs: **correct** for the tested paths. Remaining
compatibility boundaries are explicit: no full HTML-output GFM conformance, no
full official GFM suite run, and Fake-IP/private network HTTP images are blocked.

## Human Reviewer Callouts (Non-Blocking)

- **This change introduces a new dependency:** `swift-cmark` 0.9.0, pinned in
  `Package.swift` / `Package.resolved`; the download target links macOS system
  libcurl. Third-party notices are included in the app bundle.
- **This change changes a dependency (or the lockfile):** adds `Package.resolved`.
- **This change modifies auth/permission behavior:** image downloads reject URL
  credentials, private/reserved IPs and proxies, including redirect destinations.
- **This change introduces backwards-incompatible public schema/API/contract changes:**
  new annotation records may contain the `counter` tool, which older binaries
  cannot decode; existing records remain readable by this version. Idle double-click
  now copies and closes; editing uses the pencil/context menu.
- **This change changes configuration defaults:** annotation sessions initially
  select the Selection tool instead of Rectangle. Pointer placement remains
  enabled by default, with cascading offsets removed from that mode.
