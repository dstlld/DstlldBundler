//
//  BundleApp.swift
//  BundleApp
//
//  swift package bundle-app [--product <name>] [-c debug|release] [--executable <path>] [--no-get-task-allow]
//
//  Builds the product (unless `--executable` names one already built), then hands it to
//  `dstlld-bundler`, which writes and signs `<work directory>/<configuration>/<Product>.app`. The
//  last line of output is the `.app`'s path.
//
//  An executable product is an app when `App/<Product>/Info.plist` exists.
//

import Foundation
import PackagePlugin

@main
struct BundleApp: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        var extractor = ArgumentExtractor(arguments.map { $0 == "-c" ? "--configuration" : $0 })
        let productOption = extractor.extractOption(named: "product").last
        let configurationName = extractor.extractOption(named: "configuration").last ?? "debug"
        let prebuilt = extractor.extractOption(named: "executable").last
        let noGetTaskAllow = extractor.extractFlag(named: "no-get-task-allow") > 0
        if let unknown = extractor.unextractedOptionsOrFlags.first ?? extractor.remainingArguments.first {
            throw PluginError("unknown argument '\(unknown)'")
        }
        guard configurationName == "debug" || configurationName == "release" else {
            throw PluginError("--configuration must be debug or release, not '\(configurationName)'")
        }

        let package = context.package
        let appsFolder = package.directoryURL.appending(path: "App", directoryHint: .isDirectory)
        let apps = package.products.compactMap { $0 as? ExecutableProduct }.filter { product in
            FileManager.default.fileExists(atPath: appsFolder.appending(path: "\(product.name)/Info.plist").path)
        }
        let product = try choose(productOption, from: apps, allExecutables: package.products.compactMap { $0 as? ExecutableProduct })

        let executable: URL
        if let prebuilt {
            executable = URL(filePath: prebuilt)
        } else {
            let result = try packageManager.build(
                .product(product.name),
                parameters: .init(configuration: configurationName == "release" ? .release : .debug, logging: .concise)
            )
            guard result.succeeded else {
                print(result.logText)
                throw PluginError("building \(product.name) failed")
            }
            guard let built = result.builtArtifacts.first(where: { $0.kind == .executable }) else {
                throw PluginError("building \(product.name) produced no executable")
            }
            executable = built.url
        }

        let bundleNames = Set(
            (product.targets + product.targets.flatMap(\.recursiveTargetDependencies)).map { "\(package.displayName)_\($0.name).bundle" }
        )
        let buildDirectory = executable.deletingLastPathComponent()
        let resourceBundles = ((try? FileManager.default.contentsOfDirectory(at: buildDirectory, includingPropertiesForKeys: nil)) ?? [])
            .filter { bundleNames.contains($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        let output = context.pluginWorkDirectoryURL
            .appending(path: configurationName, directoryHint: .isDirectory)
            .appending(path: "\(product.name).app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)

        var toolArguments = [
            "--product", product.name,
            "--executable", executable.path,
            "--app-directory", appsFolder.appending(path: product.name, directoryHint: .isDirectory).path,
            "--output", output.path,
            "--configuration", configurationName,
        ]
        for bundle in resourceBundles {
            toolArguments += ["--resource-bundle", bundle.path]
        }
        if noGetTaskAllow { toolArguments.append("--no-get-task-allow") }

        let process = Process()
        process.executableURL = try context.tool(named: "dstlld-bundler").url
        process.arguments = toolArguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw PluginError("bundling \(product.name) failed")
        }
    }

    private func choose(_ name: String?, from apps: [ExecutableProduct], allExecutables: [ExecutableProduct]) throws -> ExecutableProduct {
        if let name {
            if let app = apps.first(where: { $0.name == name }) { return app }
            if allExecutables.contains(where: { $0.name == name }) {
                throw PluginError("\(name) is not an app: create App/\(name)/Info.plist")
            }
            throw PluginError("there is no executable product named \(name)")
        }
        switch apps.count {
        case 1:
            return apps[0]
        case 0:
            throw PluginError("no app products: an executable product becomes an app when App/<Product>/Info.plist exists")
        default:
            throw PluginError("choose an app with --product: \(apps.map(\.name).joined(separator: ", "))")
        }
    }
}

struct PluginError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
