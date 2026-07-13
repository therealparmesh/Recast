# Recast

Recast turns Apple-centric, space-saving and professional media into everyday
files that work nearly everywhere. Drop in HEIC/HEIF photos or HEVC/ProRes
video; get back JPEG, PNG, or broadly compatible H.264 MP4 files. Requires
macOS 26+.

## Features

- HEIC/HEIF → everyday JPEG or PNG, with adjustable JPEG quality
- HEVC/ProRes MOV or MP4 → broadly compatible H.264 MP4
- H.264 video passes through when MP4-compatible and otherwise re-encodes cleanly
- Drag-and-drop, file picker, and keyboard-driven file management
- Clear current-file status and cancellation during long conversions
- Successful files leave the queue; failures remain visible and retryable
- Automatic output naming avoids overwriting existing files
- Automatic updates via Sparkle

## Build

```sh
mise run icon
mise run app
open dist/Recast.app
```

For a plain SwiftPM build:

```sh
swift build
```

## Release

A distributable build is a signed, notarized `.app`:

```sh
RECAST_VERSION=1.0.0 ./Scripts/bundle.sh --sign "Developer ID Application: …" --zip
```

`Scripts/bundle.sh` assembles the app from the SwiftPM build, embeds
`Sparkle.framework`, signs Sparkle's nested helpers inside-out, and signs the
app with its sandbox entitlements. Notarize and staple the resulting `.zip`
before publishing it alongside the Sparkle `appcast.xml`.

## Sandbox

Recast runs sandboxed. It holds the user-selected file entitlement (to read
dropped files and write conversions) and the network-client entitlement plus a
mach-lookup exception (both required for Sparkle updates) — nothing more.

## Updates

Updates use [Sparkle](https://sparkle-project.org). The app checks the
`SUFeedURL` appcast in `Info.plist`; releases are signed with the EdDSA key
whose public half is stored as `SUPublicEDKey`.
