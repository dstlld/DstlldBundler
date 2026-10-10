//
//  ExportApp.swift
//  ExportApp
//
//  swift package --disable-sandbox export-app [--product <name>] [--executable <path>] [--output <dir>]
//                [--identity <certificate>] [--notary-profile <name>] [--no-notarize]
//
//  Builds a release of the product (unless `--executable` names one already built), then hands it
//  to `dstlld-bundler export`, which signs it, makes `<output>/<Name> <version>.dmg` and notarizes
//  it. The output folder defaults to `Exports` in the package. The last line of output is the
//  `.dmg`'s path.
//
//  It must run with `--disable-sandbox`: SwiftPM's plugin sandbox hides the keychain's signing
//  keys and refuses to mount disk images, so nothing an export does would work inside it.
//
//  Choosing the product and finding its resource bundles repeats BundleApp's code, because a
//  plugin cannot share code with another plugin.
//

import Foundation
import PackagePlugin

@main
struct ExportApp: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        var extractor = ArgumentExtractor(arguments)
        let productOption = extractor.extractOption(named: "product").last
        let prebuilt = extractor.extractOption(named: "executable").last
        let outputOption = extractor.extractOption(named: "output").last
        let identity = extractor.extractOption(named: "identity").last
        let notaryProfile = extractor.extractOption(named: "notary-profile").last
        let noNotarize = extractor.extractFlag(named: "no-notarize") > 0
        if let unknown = extractor.unextractedOptionsOrFlags.first ?? extractor.remainingArguments.first {
            throw PluginError("unknown argument '\(unknown)'")
        }

        let package = context.package
        try requireNoSandbox(package.directoryURL)
        let appsFolder = package.directoryURL.appending(path: "App", directoryHint: .isDirectory)
        let executables = package.products.compactMap { $0 as? ExecutableProduct }
        let apps = executables.filter { product in
            FileManager.default.fileExists(atPath: appsFolder.appending(path: "\(product.name)/Info.plist").path)
        }
        let product = try choose(productOption, from: apps, allExecutables: executables)

        let executable: URL
        if let prebuilt {
            executable = URL(filePath: prebuilt)
        } else {
            print("note: building \(product.name) for release")
            let result = try packageManager.build(
                .product(product.name), parameters: .init(configuration: .release, logging: .concise))
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
            (product.targets + product.targets.flatMap(\.recursiveTargetDependencies))
                .map { "\(package.displayName)_\($0.name).bundle" })
        let buildDirectory = executable.deletingLastPathComponent()
        let resourceBundles = ((try? FileManager.default.contentsOfDirectory(at: buildDirectory, includingPropertiesForKeys: nil)) ?? [])
            .filter { bundleNames.contains($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        let output = outputOption.map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? package.directoryURL.appending(path: "Exports", directoryHint: .isDirectory)
        var toolArguments = [
            "export",
            "--product", product.name,
            "--executable", executable.path,
            "--app-directory", appsFolder.appending(path: product.name, directoryHint: .isDirectory).path,
            "--output-directory", output.path,
            "--work-directory", context.pluginWorkDirectoryURL.appending(path: product.name).path,
        ]
        for bundle in resourceBundles {
            toolArguments += ["--resource-bundle", bundle.path]
        }
        if let identity { toolArguments += ["--identity", identity] }
        if let notaryProfile { toolArguments += ["--notary-profile", notaryProfile] }
        if noNotarize { toolArguments.append("--no-notarize") }

        let process = Process()
        process.executableURL = try context.tool(named: "dstlld-bundler").url
        process.arguments = toolArguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw PluginError("exporting \(product.name) failed")
        }
    }

    /// Fails early, with the fix, when SwiftPM's sandbox is on. Inside it the package folder is
    /// read-only, which is quicker to test than the keychain or a disk image.
    private func requireNoSandbox(_ packageDirectory: URL) throws {
        let probe = packageDirectory.appending(path: ".export-app-\(ProcessInfo.processInfo.processIdentifier)")
        guard FileManager.default.createFile(atPath: probe.path, contents: nil) else {
            throw PluginError(
                "export-app needs `swift package --disable-sandbox export-app`: SwiftPM's plugin sandbox hides the "
                    + "keychain's signing certificates and cannot mount disk images")
        }
        // The probe was just made; if it is somehow gone already, there is nothing to clean up.
        try? FileManager.default.removeItem(at: probe)
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
