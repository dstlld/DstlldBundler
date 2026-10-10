# DstlldBundler

Turns a SwiftPM executable into a signed macOS `.app`, with no Xcode project. It can also put the app on a signed, notarized disk image that any Mac will open.

```bash
swift package bundle-app                      # the only app product, debug
swift package bundle-app --product MyApp -c release
swift package --disable-sandbox export-app    # a disk image for other Macs
```

For `bundle-app`, the last line of output is the path of the `.app`, under `.build/plugins/BundleApp/outputs/<configuration>/`. For `export-app`, it is the path of the `.dmg`, in `Exports/`.

## Products

| Product | What it is | When to use it |
|---|---|---|
| `BundleApp` | The `bundle-app` command plugin. | To turn your executable into an app. No target needs to depend on it. |
| `ExportApp` | The `export-app` command plugin. | To give your app to people with other Macs. |
| `DstlldBundlerCore` | The library behind the plugins: `Info.plist`, entitlements, icons, bundle layout, signing, disk images and notarization. | Only if you want to build apps from your own tool. |

Both are macOS only.

## Requirements

- macOS 13 or later.
- Swift 6.2 or later: Xcode 26 or later, or the matching Command Line Tools.
- `codesign` at `/usr/bin/codesign`, which comes with macOS.
- For an app icon: Xcode, because only its `actool` compiles Icon Composer icons. Without it, the app has no icon and you get a warning.
- For an export that other Macs will open: a paid Apple Developer Program membership, for the Developer ID certificate and the notary service.

## Installation

Add the package as a dependency. No target needs to depend on it:

```swift
dependencies: [
    .package(url: "https://github.com/dstlld/DstlldBundler.git", branch: "main"),
],
```

To use the library in your own tool, add it to that target:

```swift
.product(name: "DstlldBundlerCore", package: "DstlldBundler")
```

## Usage

1. Add `App/<Product>/Info.plist` next to `Package.swift`, with a `CFBundleIdentifier`.
2. Run `swift package bundle-app`.
3. Open the `.app` at the path on the last line of output.

The sections below say what goes in the folder, how the app is signed, and which options you can pass.

## The `App/<Product>/` folder

An executable product becomes an app when `App/<Product>/Info.plist` exists, next to `Package.swift`:

```
App/MyApp/Info.plist            CFBundleIdentifier is required
App/MyApp/MyApp.entitlements    optional; without it the app gets the App Sandbox
App/MyApp/Resources/            copied into Contents/Resources; read it with Bundle.main
App/MyApp/AppIcon.icon          optional; an Icon Composer icon, compiled into the app
App/MyApp/Distribution.plist    optional; how export-app signs and notarizes
App/MyApp/DiskImage/            optional; background.png and background@2x.png for the disk image
```

The bundler fills in the keys every app needs: `CFBundleExecutable`, `CFBundlePackageType`, `CFBundleName`, the version keys and `NSPrincipalClass`. Anything you set in `Info.plist` wins, except `CFBundleExecutable`.

## Signing

`bundle-app` signs apps ad hoc (`codesign -s -`), so they run on the Mac that built them. To give an app to other people, use `export-app`, described below. The designated requirement is pinned to the bundle identifier, so the App Sandbox container survives rebuilds.

- Debug builds add `com.apple.security.get-task-allow`, so a debugger can attach. Pass `--no-get-task-allow` to leave it out.
- Release builds always remove it.

## Exporting for other Macs

`export-app` builds a release of the app and signs it. It then puts the app on a disk image with a link to Applications, and sends the image to Apple's notary service. Every step that can't be done is reported as a warning.

```bash
swift package --disable-sandbox export-app --product MyApp
```

It needs `--disable-sandbox`. Inside SwiftPM's plugin sandbox, the keychain's certificates are hidden and disk images can't be mounted. The plugin stops early and says so if you leave the option out.

**Signing.** The export uses the first certificate it finds, in this order:

1. Developer ID Application. This is the only kind other Macs accept, and the only kind the notary service takes.
2. Apple Development. Only Macs registered to your team trust it, and it can't be notarized.
3. Ad hoc. Only the Mac that built the app will open it.

With a certificate, the app is signed with the hardened runtime and a secure timestamp, which notarization needs. To make a Developer ID certificate, open Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates.

**Notarizing.** Make a keychain profile once:

```bash
xcrun notarytool store-credentials my-notary --apple-id you@example.com --team-id ABCDE12345
```

Then name the profile in `App/MyApp/Distribution.plist`, or pass `--notary-profile`. Notarizing usually takes a few minutes. The ticket is then stapled to the disk image, so Gatekeeper can check it offline.

**`Distribution.plist`.** Every key is optional. The file holds names, never passwords.

| Key | Meaning |
|---|---|
| `SigningIdentity` | A certificate's SHA-1, its name or the start of its name, or `-` for ad hoc. |
| `NotaryProfile` | The `notarytool` keychain profile. Without one, the export is not notarized. |
| `DiskImageName` | The disk image's file and volume name. Defaults to `<CFBundleName> <version>`. |

**The disk image's window.** It is 660 × 400 points. The app sits on the left and Applications on the right, with an arrow between them. The background is drawn from the two main colours of the app's icon, with the app's name above the arrow. To use your own picture, add `App/MyApp/DiskImage/background.png`, and `background@2x.png` for Retina screens. Leave the bottom 30 points plain, because Finder's path bar can cover them. The layout is written straight into the image's `.DS_Store`, without scripting Finder.

## Resources

SwiftPM's `Bundle.module` looks for its resource bundle at the root of the `.app`, where code signing does not allow files. Put app resources in `App/<Product>/Resources` and load them with `Bundle.main`. If a target still has SwiftPM resources, the bundler copies them into `Contents/Resources` and prints a warning.

## Options

| Option | Meaning |
|---|---|
| `--product <name>` | The app to bundle. Needed when there is more than one. |
| `-c`, `--configuration debug\|release` | Defaults to `debug`. |
| `--executable <path>` | Bundle an executable that is already built instead of building it. |
| `--no-get-task-allow` | Leave the debugger entitlement out of a debug build. |

`export-app` takes these:

| Option | Meaning |
|---|---|
| `--product <name>` | The app to export. Needed when there is more than one. |
| `--executable <path>` | Export a release build that is already built instead of building it. |
| `--output <dir>` | Where the `.dmg` goes. Defaults to `Exports` in the package. |
| `--identity <certificate>` | Overrides `SigningIdentity`. |
| `--notary-profile <name>` | Overrides `NotaryProfile`. |
| `--no-notarize` | Skip the notary service, for a quick look at the disk image. |

## How it works

A package plugin cannot import a library, so the work is split into three layers. `DstlldBundlerCore` holds the logic: `Info.plist`, entitlements, icons, bundle layout, signing, disk images and notarization. The `dstlld-bundler` tool wraps the core. The `BundleApp` and `ExportApp` plugins build your product, then run that tool. The `.app` is written from scratch on every run.

A disk image is made blank and writable with `diskutil image`, mounted at a private mount point, filled, and then compressed with LZFSE. It has to be mounted while it is laid out: the window's background is found through an alias, and an alias names the volume's creation date and the file's catalogue ids.

## Testing

```bash
swift test
```

Some tests sign a real bundle, so they need `codesign`.

To try the plugin from start to finish, run `swift package bundle-app` in `Fixtures/HelloApp`. That sample app needs Swift 6.4 and macOS 27.

## Status and licence

Pre-1.0. There are no tagged releases, so depend on the `main` branch. The API may change without notice.

MIT licence. See [LICENSE](LICENSE).
