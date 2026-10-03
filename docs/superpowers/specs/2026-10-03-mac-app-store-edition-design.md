# Mac App Store Edition Design

## Goal

Prepare LiveAstro Studio for Mac App Store distribution without weakening the
existing direct-download edition.

The App Store edition will use the sandbox-safe Store Preview feature boundary:

- native stacking of user-selected folders;
- Seestar and ASIAIR mounted-share discovery and relay;
- display and detached broadcast windows;
- OBS connection/status checks and local recording;
- no GraXpert processing;
- no one-click public-stream or scene-automation controls.

The direct GitHub edition keeps its current full feature set.

## Why a separate distribution target

The direct edition currently has an empty entitlement file and is signed for
Developer ID distribution. The repository already has `StorePreviewConfiguration`
and Store Preview packaging with App Sandbox, user-selected read/write access,
app-scoped bookmarks, and network-client access. A separate App Store target
lets us preserve both behaviors and makes the App Store restrictions explicit at
compile/package time rather than relying on runtime accidents.

The App Store target should use its own bundle identifier, for example
`com.pauldavis.liveastrostudio.appstore`, so it can coexist with the direct
edition during development and testing. The exact identifier must be registered
in Apple Developer and App Store Connect before upload.

## Architecture

### Distribution configuration

Extend `StorePreviewConfiguration` with an explicit App Store distribution
kind, rather than treating every sandboxed build as an informal preview. The
configuration controls:

- bundle identifier and display name;
- container root and catalog location;
- allowed processor backends;
- OBS capabilities exposed in the UI;
- packaging and entitlement selection.

The existing Store Preview behavior remains available for local validation. The
App Store target should select the same sandbox-safe capability set initially.

### File access

All source, calibration, and output folders in the App Store edition must come
from user-selected URLs and be retained through security-scoped bookmarks. Each
operation that crosses an app/container boundary must acquire and release its
access lease. The app must not assume access to arbitrary paths under the home
directory, `/Volumes`, or the camera share after a restart without restoring the
bookmark.

Camera-share detection may inspect mounted SMB locations only after the user has
authorized the relevant folder. Detection must not silently enumerate unrelated
volumes. The existing cancellation and stale-result guards remain required.

### Processing

The App Store edition disables GraXpert and any external processor that cannot
run inside the sandbox. Native processing remains available. The UI must explain
that the direct edition supports the additional external processor.

### OBS

The App Store edition retains network-client access for OBS status checks and
local recording controls. It does not launch public streaming or scene
automation. Users detach the broadcast window and operate public streaming in
OBS itself. The UI and Help text must state this consistently.

### Entitlements and signing

The App Store target needs App Sandbox and only the minimum capabilities:

- `com.apple.security.app-sandbox`;
- `com.apple.security.files.user-selected.read-write`;
- `com.apple.security.files.bookmarks.app-scope`;
- `com.apple.security.network.client`.

No network-server, device, scripting, or unrestricted file entitlement should be
added without a demonstrated requirement. The target must be archived and
signed with the Mac App Store distribution identity, not the Developer ID
identity used by GitHub releases.

## Packaging and submission flow

1. Register the App Store bundle identifier and create a macOS app record in App
   Store Connect.
2. Add an App Store packaging script/target that builds the sandboxed bundle,
   validates its entitlements, and produces an uploadable archive/package.
3. Upload the first build with Xcode or Transporter.
4. Configure metadata, screenshots, privacy answers, pricing, and availability.
5. Test the build through TestFlight/internal distribution before review.
6. Submit the selected build for App Review.

The direct-release script and GitHub artifacts must remain unchanged by this
work except for shared, distribution-neutral fixes.

## Testing strategy

Automated tests should cover:

- App Store configuration selects the sandbox-safe capability set;
- GraXpert and public-stream controls are absent or disabled only for the App
  Store configuration;
- security-scoped folder selection, bookmark restoration, and access release;
- camera-share authorization, cancellation, stale-result rejection, and relay
  startup;
- OBS status/local-recording controls without public stream commands;
- entitlement plist contains exactly the approved keys;
- App Store bundle identifier and display name are correct;
- direct distribution configuration retains its existing capabilities.

Manual TestFlight checks should cover a clean install, folder selection after
restart, mounted Seestar/ASIAIR access, native stacking, detached broadcast
capture in OBS, local recording, and the explanatory UI for unavailable direct
edition features.

## Non-goals

- Rewriting the direct distribution path.
- Making GraXpert sandbox-compatible in this phase.
- Automating public YouTube streaming from the App Store edition.
- Publishing to the Mac App Store before sandbox behavior is validated through
  TestFlight.

## Open implementation decisions

- Final App Store bundle identifier and SKU.
- Whether to share one target with configuration flags or add a dedicated
  executable target; the recommendation is a dedicated packaging target using
  shared sources and explicit distribution configuration.
- App Store pricing and availability.
- Final privacy labels and screenshots.
