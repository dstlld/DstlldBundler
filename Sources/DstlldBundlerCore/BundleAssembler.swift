//
//  BundleAssembler.swift
//  DstlldBundlerCore
//
//  Writes the `.app` from scratch every time, then signs it:
//
//    <Product>.app/Contents/Info.plist
//    <Product>.app/Contents/PkgInfo
//    <Product>.app/Contents/MacOS/<executable>
//    <Product>.app/Contents/Resources/…     (App/<Product>/Resources, then any SwiftPM bundles)
//
//  Everything is copied, never linked: codesign seals the bundle's own files.
//

import Foundation

public struct BundleResult: Sendable, Equatable {
    public let app: URL
    public let executable: URL
    public let warnings: [String]
}

public enum BundleAssembler {
    public static func assemble(_ spec: BundleSpec, sign: Bool = true) throws(BundlerError) -> BundleResult {
        let files = FileManager.default
        guard files.isExecutableFile(atPath: spec.executable.path) else {
            throw BundlerError("the built executable is missing: \(spec.executable.path)")
        }
        let executableName = spec.executable.lastPathComponent
        let info = try InfoPlist.load(spec.infoPlistFile, executableName: executableName, productName: spec.productName)
        let entitlements = try Entitlements.load(
            spec.entitlementsFile,
            configuration: spec.configuration,
            getTaskAllow: spec.getTaskAllow
        )
        var warnings: [String] = []

        let contents = spec.output.appending(path: "Contents", directoryHint: .isDirectory)
        let macOS = contents.appending(path: "MacOS", directoryHint: .isDirectory)
        let resources = contents.appending(path: "Resources", directoryHint: .isDirectory)
        let bundledExecutable = macOS.appending(path: executableName)

        try attempt("could not write \(spec.output.lastPathComponent)") {
            if files.fileExists(atPath: spec.output.path) {
                try files.removeItem(at: spec.output)
            }
            try files.createDirectory(at: macOS, withIntermediateDirectories: true)
            try files.createDirectory(at: resources, withIntermediateDirectories: true)
            try files.copyItem(at: spec.executable, to: bundledExecutable)
            let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try plist.write(to: contents.appending(path: "Info.plist"))
            try Data("APPL????".utf8).write(to: contents.appending(path: "PkgInfo"))
        }

        if files.fileExists(atPath: spec.resourcesDirectory.path) {
            try attempt("could not copy App/\(spec.productName)/Resources") {
                for item in try files.contentsOfDirectory(at: spec.resourcesDirectory, includingPropertiesForKeys: nil)
                where item.lastPathComponent != ".DS_Store" {
                    try files.copyItem(at: item, to: resources.appending(path: item.lastPathComponent))
                }
            }
        }

        for bundle in spec.resourceBundles {
            try attempt("could not copy \(bundle.lastPathComponent)") {
                let target = resources.appending(path: bundle.lastPathComponent)
                if files.fileExists(atPath: target.path) { try files.removeItem(at: target) }
                try files.copyItem(at: bundle, to: target)
            }
            warnings.append(Diagnostic.warning(
                "\(bundle.lastPathComponent) was copied into Contents/Resources, where Bundle.module does not look; "
                    + "put app resources in App/\(spec.productName)/Resources and load them with Bundle.main"
            ))
        }

        if sign {
            let entitlementsFile = spec.output.deletingLastPathComponent()
                .appending(path: "\(spec.output.deletingPathExtension().lastPathComponent).entitlements.plist")
            try attempt("could not write the signing entitlements") {
                let data = try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0)
                try data.write(to: entitlementsFile)
            }
            let identifier = info[InfoPlist.bundleIdentifierKey] as? String ?? ""
            try CodeSigner.sign(bundle: spec.output, entitlements: entitlementsFile, identifier: identifier)
        }
        return BundleResult(app: spec.output, executable: bundledExecutable, warnings: warnings)
    }

    private static func attempt(_ what: String, _ body: () throws -> Void) throws(BundlerError) {
        do {
            try body()
        } catch {
            throw BundlerError("\(what): \(error.localizedDescription)")
        }
    }
}
