# DstlldBundler

Turns a SwiftPM executable into a signed macOS `.app`, with no Xcode project.

```bash
swift package bundle-app                      # the only app product, debug
swift package bundle-app --product MyApp -c release
```

The last line of output is the path of the `.app`, under `.build/plugins/BundleApp/outputs/<configuration>/`.

## Setup

Add the package as a dependency. No target needs to depend on it:

```swift
dependencies: [
    .package(url: "https://github.com/dstlld/DstlldBundler.git", branch: "main"),
],
```

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
