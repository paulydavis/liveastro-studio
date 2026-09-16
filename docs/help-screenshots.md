# Help screenshots

The four `help-*.png` resources show native production SwiftUI controls from
v3.6.9 (base `5f22bde`), not reconstructed UI. They are documentation examples,
not a recording of a running acquisition or evidence that processing succeeds.

`HelpScreenshotCaptureTests` hosts the real views with isolated preferences and
an empty temporary calibration library. It never starts a pipeline. Source uses
`/Example/Capture/Lights` and the illustrative prefix `Light_`; Display is idle;
outputs shows a replay-only example with Folder and Master unavailable. Captions
explain those states. No user filenames, preferences, or astronomy data are used.

## Regeneration

From a GUI-capable macOS development session, with no competing build/test:

```sh
capture_dir=$(mktemp -d /private/tmp/liveastro-help-images.XXXXXX)
LAS_HELP_CAPTURE_DIR="$capture_dir" swift test --filter HelpScreenshotCaptureTests
```

Inspect all four PNGs before copying them into
`Sources/LiveAstroStudio/Resources/`. The exporter checks selected labels using
OCR, but that does not establish that every label is legible or the crop is
complete. Review crops after layout changes; the output crop deliberately omits
the version label, which otherwise shows XCTest's host version. Update the
example-version labels in `HelpIllustrationView` when recapturing newer UI.

Run `HelpIllustrationTests`, `HelpCatalogTests`, and `HelpSectionTests` after
replacement. Manually open each guide, enlarge it, and dismiss with Done/Escape
in the app. Check both the Help tab and a focused Help popover. The capture test
is opt-in and skipped by ordinary test runs; resource decoding tests always run.
