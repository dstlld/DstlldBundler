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
}
