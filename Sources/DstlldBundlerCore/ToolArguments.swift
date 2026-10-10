//
//  ToolArguments.swift
//  DstlldBundlerCore
//
//  The `dstlld-bundler` tool's command line. Parsed by hand: a dependency on ArgumentParser would
//  be fetched by every project that uses the plugin.
//
//    dstlld-bundler --product <name> --executable <path> --app-directory <dir> --output <x.app>
//                   [--configuration debug|release] [--resource-bundle <path>]… [--no-get-task-allow]
//
//    dstlld-bundler export --product <name> --executable <path> --app-directory <dir>
//                   --output-directory <dir> --work-directory <dir> [--resource-bundle <path>]…
//                   [--identity <certificate>] [--notary-profile <name>] [--no-notarize]
//

import Foundation

public enum ToolArguments {
    public static func parse(_ arguments: [String]) throws(BundlerError) -> BundleSpec {
        var values: [String: String] = [:]
        var resourceBundles: [URL] = []
        var getTaskAllow = true
        var index = arguments.startIndex
        func value(for option: String) throws(BundlerError) -> String {
            let next = arguments.index(after: index)
            guard next < arguments.endIndex else { throw BundlerError("\(option) needs a value") }
            index = next
            return arguments[next]
        }
        while index < arguments.endIndex {
            let option = arguments[index]
            switch option {
            case "--product", "--executable", "--app-directory", "--output", "--configuration":
                values[option] = try value(for: option)
            case "--resource-bundle":
                resourceBundles.append(URL(filePath: try value(for: option)))
            case "--no-get-task-allow":
                getTaskAllow = false
            default:
                throw BundlerError("unknown argument '\(option)'")
            }
            index = arguments.index(after: index)
        }
        func required(_ option: String) throws(BundlerError) -> String {
            guard let value = values[option] else { throw BundlerError("missing \(option)") }
            return value
        }
        let configurationName = values["--configuration"] ?? BuildConfiguration.debug.rawValue
        guard let configuration = BuildConfiguration(rawValue: configurationName) else {
            throw BundlerError("--configuration must be debug or release, not '\(configurationName)'")
        }
        return BundleSpec(
            productName: try required("--product"),
            executable: URL(filePath: try required("--executable")),
            appDirectory: URL(filePath: try required("--app-directory"), directoryHint: .isDirectory),
            output: URL(filePath: try required("--output"), directoryHint: .isDirectory),
            configuration: configuration,
            resourceBundles: resourceBundles,
            getTaskAllow: getTaskAllow
        )
    }

    /// The inverse of `parse`, used by the plugin.
    public static func arguments(for spec: BundleSpec) -> [String] {
        var result = [
            "--product", spec.productName,
            "--executable", spec.executable.path,
            "--app-directory", spec.appDirectory.path,
            "--output", spec.output.path,
            "--configuration", spec.configuration.rawValue,
        ]
        for bundle in spec.resourceBundles {
            result += ["--resource-bundle", bundle.path]
        }
        if !spec.getTaskAllow { result.append("--no-get-task-allow") }
        return result
    }

    /// The `export` subcommand's arguments, after the word `export`.
    public static func parseExport(_ arguments: [String]) throws(BundlerError) -> ExportSpec {
        var values: [String: String] = [:]
        var resourceBundles: [URL] = []
        var notarize = true
        var index = arguments.startIndex
        func value(for option: String) throws(BundlerError) -> String {
            let next = arguments.index(after: index)
            guard next < arguments.endIndex else { throw BundlerError("\(option) needs a value") }
            index = next
            return arguments[next]
        }
        while index < arguments.endIndex {
            let option = arguments[index]
            switch option {
            case "--product", "--executable", "--app-directory", "--output-directory", "--work-directory",
                "--identity", "--notary-profile":
                values[option] = try value(for: option)
            case "--resource-bundle":
                resourceBundles.append(URL(filePath: try value(for: option)))
            case "--no-notarize":
                notarize = false
            default:
                throw BundlerError("unknown argument '\(option)'")
            }
            index = arguments.index(after: index)
        }
        func required(_ option: String) throws(BundlerError) -> String {
            guard let value = values[option] else { throw BundlerError("missing \(option)") }
            return value
        }
        return ExportSpec(
            productName: try required("--product"),
            executable: URL(filePath: try required("--executable")),
            appDirectory: URL(filePath: try required("--app-directory"), directoryHint: .isDirectory),
            outputDirectory: URL(filePath: try required("--output-directory"), directoryHint: .isDirectory),
            workDirectory: URL(filePath: try required("--work-directory"), directoryHint: .isDirectory),
            resourceBundles: resourceBundles,
            signingIdentity: values["--identity"],
            notaryProfile: values["--notary-profile"],
            notarize: notarize
        )
    }

    /// The inverse of `parseExport`, `export` included.
    public static func arguments(for spec: ExportSpec) -> [String] {
        var result = [
            "export",
            "--product", spec.productName,
            "--executable", spec.executable.path,
            "--app-directory", spec.appDirectory.path,
            "--output-directory", spec.outputDirectory.path,
            "--work-directory", spec.workDirectory.path,
        ]
        for bundle in spec.resourceBundles {
            result += ["--resource-bundle", bundle.path]
        }
        if let identity = spec.signingIdentity { result += ["--identity", identity] }
        if let profile = spec.notaryProfile { result += ["--notary-profile", profile] }
        if !spec.notarize { result.append("--no-notarize") }
        return result
    }
}
