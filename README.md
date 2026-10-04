# DstlldBundler

Turns a SwiftPM executable into a signed macOS `.app`, with no Xcode project.

```bash
swift package bundle-app                      # the only app product, debug
swift package bundle-app --product MyApp -c release
```

The last line of output is the path of the `.app`, under `.build/plugins/BundleApp/outputs/<configuration>/`.

## Products

| Product | What it is | When to use it |
|---|---|---|
| `BundleApp` | The `bundle-app` command plugin. | To turn your executable into an app. No target needs to depend on it. |
| `DstlldBundlerCore` | The library behind the plugin: `Info.plist`, entitlements, bundle layout and signing. | Only if you want to build apps from your own tool. |

Both are macOS only.

## Requirements

- macOS 13 or later.
- Swift 6.2 or later: Xcode 26 or later, or the matching Command Line Tools.
- `codesign` at `/usr/bin/codesign`, which comes with macOS.

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
```

The bundler fills in the keys every app needs: `CFBundleExecutable`, `CFBundlePackageType`, `CFBundleName`, the version keys and `NSPrincipalClass`. Anything you set in `Info.plist` wins, except `CFBundleExecutable`.

## Signing

Apps are signed ad hoc (`codesign -s -`), so they run on the Mac that built them. The designated requirement is pinned to the bundle identifier, so the App Sandbox container survives rebuilds.

- Debug builds add `com.apple.security.get-task-allow`, so a debugger can attach. Pass `--no-get-task-allow` to leave it out.
- Release builds always remove it.

## Resources

SwiftPM's `Bundle.module` looks for its resource bundle at the root of the `.app`, where code signing does not allow files. Put app resources in `App/<Product>/Resources` and load them with `Bundle.main`. If a target still has SwiftPM resources, the bundler copies them into `Contents/Resources` and prints a warning.

## Options

| Option | Meaning |
|---|---|
| `--product <name>` | The app to bundle. Needed when there is more than one. |
| `-c`, `--configuration debug\|release` | Defaults to `debug`. |
| `--executable <path>` | Bundle an executable that is already built instead of building it. |
| `--no-get-task-allow` | Leave the debugger entitlement out of a debug build. |

## How it works

A package plugin cannot import a library, so the work is split into three layers. `DstlldBundlerCore` holds the logic: `Info.plist`, entitlements, bundle layout and signing. The `dstlld-bundler` tool wraps the core. The `BundleApp` plugin builds your product, then runs that tool. The `.app` is written from scratch on every run.

## Testing

```bash
swift test
```

Some tests sign a real bundle, so they need `codesign`.

To try the plugin from start to finish, run `swift package bundle-app` in `Fixtures/HelloApp`. That sample app needs Swift 6.4 and macOS 27.

## Status and licence

Pre-1.0. There are no tagged releases, so depend on the `main` branch. The API may change without notice.

No licence has been granted yet, so all rights are reserved.
