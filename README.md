# Recast

Your iPhone saves photos as HEIC and video as HEVC. Your camera might shoot
ProRes. They look great on a Mac and nowhere else. Recast turns them into JPEG,
PNG, and H.264 MP4, so the files open on any phone, browser, or old laptop.

Drop files in, click Convert. That is the whole app.

## Install

Download `Recast.zip` from the
[latest release](https://github.com/therealparmesh/Recast/releases/latest),
unzip it, and move `Recast.app` to Applications. It needs macOS 26 or later.

Recast is signed and notarized, and it updates itself.

## What it does

| You drop in | You get |
| --- | --- |
| HEIC or HEIF photo | JPEG or PNG |
| HEVC or ProRes video (`.mov`, `.mp4`) | H.264 MP4 |
| H.264 video | H.264 MP4, copied as-is when possible |

- Recast saves each new file next to its original, or in a folder you choose
  under **Save to**. It remembers that folder.
- It never overwrites a file. If `photo.jpg` exists, you get `photo 2.jpg`.
- It keeps your originals.
- When a file converts, it leaves the list. When a file fails, it stays there
  with the reason, so you can try it again.
- A Live Photo or burst becomes a single picture: the main one.

## Keyboard

| Keys | Action |
| --- | --- |
| `⌘O` | Add files |
| `⇧⌘O` | Choose a save folder |
| `Return` | Convert |
| `Esc` | Cancel |
| `⇧⌘⌫` | Clear the list |

## Build from source

You need Xcode 26 and [mise](https://mise.jdx.dev).

```sh
mise run run    # build a debug app and open it
mise run test
mise run lint
mise run app    # build a release app in dist/
```

## Release

Push a tag that matches `CFBundleShortVersionString` in
`Sources/Recast/Info.plist`:

```sh
git tag v1.0.0
git push origin v1.0.0
```

GitHub Actions builds the app, signs and notarizes it, and publishes
`Recast.zip` and the Sparkle `appcast.xml` as a release. It needs these
repository secrets: `CERT_P12`, `CERT_PASSWORD`, `SIGN_IDENTITY`, `APPLE_ID`,
`TEAM_ID`, `APP_PASSWORD`, and `SPARKLE_ED_PRIVATE_KEY`. The public half of the
Sparkle key is `SUPublicEDKey` in `Info.plist`.

## License

[MIT](LICENSE)
