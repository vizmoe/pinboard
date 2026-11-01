# GitHub Flavored Markdown support

Pinboard parses Markdown with **swift-cmark 0.9.0 (cmark-gfm)**, pinned in
`Package.resolved`. It enables `table`, `strikethrough`, `tasklist`, `autolink`
and `tagfilter` explicitly. The prior Foundation `PresentationIntent` renderer
lost linked images, approximated task markers after parsing, and used fixed
column tabs. Swift Markdown's default parser was also checked: it does not
activate the autolink extension, so Pinboard uses the cmark API directly.

Reference: [GFM specification](https://github.github.com/gfm/).

| Feature | Native presentation | Verification |
| --- | --- | --- |
| Headings, emphasis, code, rules | Fonts, spacing, backgrounds | MarkdownRendererTests |
| Ordered/unordered/nested lists and quotes | Markers and indentation, composed together | MarkdownRendererTests, GFMCompatibilityTests |
| Task lists | Parsed checkbox state, displayed as ☐ / ☑ | Syntax/escaped/code-marker tests |
| Tables | NSTextTable cells, empty cells and column alignment | Grid/empty-cell/alignment tests |
| Strikethrough | AppKit strikethrough attribute | Inline rendering tests |
| Autolinks | HTTP(S), www and email link attributes | URL punctuation/email tests |
| Images and linked images | Deferred attachment plus enclosing link | MarkdownImageTests |
| Malformed source | CommonMark literal interpretation | Malformed Markdown tests |

## Deliberate differences from GitHub HTML output

This is a native attributed-text viewer, not an HTML engine, and is **not
claimed to be fully GFM-conformant at the HTML output level**:

- All raw HTML is displayed literally, including otherwise allowed tags.
  No script, iframe, CSS or raw HTML image is executed/loaded by this renderer.
- Soft line breaks remain visible line breaks; GFM permits either spaces or
  line endings when rendering soft breaks.
- Checked tasks also receive a strikethrough and are not interactive checkboxes.
- Code blocks are monospaced without language syntax highlighting.
- GitHub site features such as mentions, issue references and emoji shortcodes
  are outside the GFM syntax specification and are not resolved.
- Wide tables wrap inside the pin; their layout is AppKit's, not GitHub CSS.
- Relative image URLs have no document base and display alt text. Public remote
  images load with bounded, anonymous HTTP(S); local/private HTTP endpoints are
  rejected. DNS tools using synthetic `198.18.0.0/15` (Fake-IP) answers are also
  rejected; these hosts need real public DNS answers to load. `file:` and image
  `data:` sources continue to resolve locally.

The focused tests cover representative extensions and regressions. They do not
constitute execution of the complete official GFM example suite. Canonical
source, clipboard output and history stay unchanged by rendering or themes.
