//
//  IconCompiler.swift
//  DstlldBundlerCore
//
//  `App/<Product>/AppIcon.icon`, made in Icon Composer, becomes `Contents/Resources/AppIcon.icns`
//  and `Assets.car`. Only `actool` can compile it, and `actool` ships with Xcode, not the Command
//  Line Tools: without it the app is bundled with no icon and a warning, never an error, so a Run
//  never fails over artwork.
//

import Foundation

public enum IconCompiler {
    public static let iconName = "AppIcon"

    /// `actool`'s arguments for compiling `icon` into `resources`.
    public static func arguments(icon: URL, resources: URL, partialInfoPlist: URL, minimumSystemVersion: String)
        -> [String]
    {
        [
            icon.path,
            "--compile", resources.path,
            "--platform", "macosx",
            "--minimum-deployment-target", minimumSystemVersion,
            "--app-icon", iconName,
            "--output-partial-info-plist", partialInfoPlist.path,
            "--output-format", "human-readable-text",
            "--errors", "--warnings",
        ]
    }

    public enum Outcome: Sendable, Equatable {
        /// There is no `AppIcon.icon`.
        case noIcon
        /// The Info.plist keys `actool` asked for: `CFBundleIconFile` and `CFBundleIconName`.
        case compiled(infoPlistKeys: [String: String])
        /// The icon could not be compiled; the message says why.
        case skipped(warning: String)
    }

    /// Compiles `icon`, if it exists, into `resources`.
    public static func compile(icon: URL, into resources: URL, minimumSystemVersion: String) -> Outcome {
        guard FileManager.default.fileExists(atPath: icon.path) else { return .noIcon }
        guard Command.run(URL(filePath: "/usr/bin/xcrun"), ["--find", "actool"]).succeeded else {
            return .skipped(warning: Diagnostic.warning(
                "the app has no icon: compiling AppIcon.icon needs Xcode, and only the Command Line Tools are selected "
                    + "(`xcode-select -s /Applications/Xcode.app`)", file: icon))
        }
        let partial = FileManager.default.temporaryDirectory.appending(path: "dstlld-icon-\(UUID().uuidString).plist")
        // A temporary file that may not exist if actool failed early; nothing to report.
        defer { try? FileManager.default.removeItem(at: partial) }
        let result = Command.xcrun(
            "actool",
            arguments(icon: icon, resources: resources, partialInfoPlist: partial,
                      minimumSystemVersion: minimumSystemVersion))
        guard result.succeeded else {
            return .skipped(warning: Diagnostic.warning(
                "the app has no icon: actool could not compile AppIcon.icon: \(Self.problems(in: result.output))",
                file: icon))
        }
        do {
            let data = try Data(contentsOf: partial)
            let keys = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] ?? [:]
            return .compiled(infoPlistKeys: keys)
        } catch {
            return .skipped(warning: Diagnostic.warning(
                "the app has no icon: actool's Info.plist keys could not be read: \(error.localizedDescription)",
                file: icon))
        }
    }

    /// actool's error and warning lines, without its banner.
    static func problems(in output: String) -> String {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
            .filter { !$0.hasPrefix("/*") && !$0.isEmpty }
        return lines.isEmpty ? "no reason given" : lines.joined(separator: "; ")
    }
}
