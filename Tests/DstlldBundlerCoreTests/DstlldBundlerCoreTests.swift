//
//  DstlldBundlerCoreTests.swift
//  DstlldBundlerCoreTests
//

import DstlldBundlerCore
import Foundation
import Testing

@Suite struct InfoPlistTests {
    @Test func fillsDefaultsAndOwnsTheExecutable() throws {
        let result = try InfoPlist.prepare(
            ["CFBundleIdentifier": "com.example.Notes", "CFBundleExecutable": "Wrong", "CFBundleName": "Mine"],
            executableName: "Notes",
            productName: "Notes"
        )
        #expect(result["CFBundleExecutable"] as? String == "Notes")
        #expect(result["CFBundlePackageType"] as? String == "APPL")
        #expect(result["CFBundleName"] as? String == "Mine")
        #expect(result["CFBundleVersion"] as? String == "1")
        #expect(result["CFBundleSupportedPlatforms"] as? [String] == ["MacOSX"])
    }

    @Test func requiresABundleIdentifier() {
        #expect(throws: BundlerError.self) {
            try InfoPlist.prepare([:], executableName: "Notes", productName: "Notes")
        }
    }

    @Test(arguments: [
        ("com.example.Notes", true),
        ("com.example.my-app", true),
        ("com.example.my_app", false),
        ("com.example.app ", false),
        (".com.example", false),
        ("com.exämple.app", false),
    ])
    func validatesBundleIdentifiers(identifier: String, valid: Bool) {
        #expect(InfoPlist.isValidBundleIdentifier(identifier) == valid)
    }

    @Test func missingFileNamesThePath() throws {
        let file = URL(filePath: "/nonexistent/App/Notes/Info.plist")
        do {
            _ = try InfoPlist.load(file, executableName: "Notes", productName: "Notes")
            Issue.record("expected an error")
        } catch {
            #expect(error.file == file)
            #expect(error.description.hasPrefix("/nonexistent/App/Notes/Info.plist:1:1: error:"))
        }
    }
}

@Suite struct EntitlementsTests {
    @Test func debugAddsGetTaskAllow() {
        let result = Entitlements.prepare([Entitlements.appSandbox: true], configuration: .debug, getTaskAllow: true)
        #expect(result[Entitlements.getTaskAllow] as? Bool == true)
        #expect(result[Entitlements.appSandbox] as? Bool == true)
    }

    @Test func debugCanOptOut() {
        let result = Entitlements.prepare([Entitlements.appSandbox: true], configuration: .debug, getTaskAllow: false)
        #expect(result[Entitlements.getTaskAllow] == nil)
    }

    @Test func releaseRemovesGetTaskAllow() {
        let result = Entitlements.prepare([Entitlements.getTaskAllow: true], configuration: .release, getTaskAllow: true)
        #expect(result[Entitlements.getTaskAllow] == nil)
    }

    @Test func missingFileMeansSandboxed() throws {
        let result = try Entitlements.load(URL(filePath: "/nonexistent/x.entitlements"), configuration: .release, getTaskAllow: true)
        #expect(result[Entitlements.appSandbox] as? Bool == true)
    }
}

@Suite struct ArgumentTests {
    @Test func roundTrips() throws {
        let spec = BundleSpec(
            productName: "Notes",
            executable: URL(filePath: "/b/debug/Notes"),
            appDirectory: URL(filePath: "/p/App/Notes", directoryHint: .isDirectory),
            output: URL(filePath: "/w/debug/Notes.app", directoryHint: .isDirectory),
            configuration: .release,
            resourceBundles: [URL(filePath: "/b/debug/Notes_Notes.bundle")],
            getTaskAllow: false
        )
        let parsed = try ToolArguments.parse(ToolArguments.arguments(for: spec))
        #expect(parsed.productName == spec.productName)
        #expect(parsed.executable.path == spec.executable.path)
        #expect(parsed.appDirectory.path == spec.appDirectory.path)
        #expect(parsed.output.path == spec.output.path)
        #expect(parsed.configuration == .release)
        #expect(parsed.resourceBundles.map(\.path) == ["/b/debug/Notes_Notes.bundle"])
        #expect(parsed.getTaskAllow == false)
    }

    @Test func rejectsUnknownArguments() {
        #expect(throws: BundlerError.self) { try ToolArguments.parse(["--frobnicate"]) }
        #expect(throws: BundlerError.self) { try ToolArguments.parse(["--product"]) }
    }

    @Test func codesignArguments() {
        let arguments = CodeSigner.arguments(
            bundle: URL(filePath: "/w/Notes.app"),
            entitlements: URL(filePath: "/w/Notes.entitlements.plist"),
            identifier: "com.example.Notes"
        )
        #expect(arguments.first == "--force")
        #expect(arguments.contains("-r=designated => identifier \"com.example.Notes\""))
        #expect(arguments.last == "/w/Notes.app")
    }
}

/// Assembles and signs a real bundle around a copy of `/bin/echo`.
@Suite struct AssemblyTests {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "DstlldBundlerTests-\(UUID().uuidString)")
        let app = root.appending(path: "App/Echo")
        try FileManager.default.createDirectory(at: app.appending(path: "Resources/Nested"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "com.example.dstlld-bundler-tests.Echo"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appending(path: "Info.plist"))
        try Data("hello".utf8).write(to: app.appending(path: "Resources/greeting.txt"))
        try Data("nested".utf8).write(to: app.appending(path: "Resources/Nested/inner.txt"))
        try FileManager.default.createDirectory(at: root.appending(path: "build"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(filePath: "/bin/echo"), to: root.appending(path: "build/Echo"))
    }

    func spec(configuration: BuildConfiguration = .debug) -> BundleSpec {
        BundleSpec(
            productName: "Echo",
            executable: root.appending(path: "build/Echo"),
            appDirectory: root.appending(path: "App/Echo", directoryHint: .isDirectory),
            output: root.appending(path: "out/Echo.app", directoryHint: .isDirectory),
            configuration: configuration
        )
    }

    @Test func layoutAndSignature() throws {
        try FileManager.default.createDirectory(at: root.appending(path: "out"), withIntermediateDirectories: true)
        let result = try BundleAssembler.assemble(spec())
        let contents = result.app.appending(path: "Contents")
        #expect(FileManager.default.isExecutableFile(atPath: contents.appending(path: "MacOS/Echo").path))
        #expect(FileManager.default.fileExists(atPath: contents.appending(path: "Resources/greeting.txt").path))
        #expect(FileManager.default.fileExists(atPath: contents.appending(path: "Resources/Nested/inner.txt").path))
        #expect(try String(contentsOf: contents.appending(path: "PkgInfo"), encoding: .utf8) == "APPL????")
        #expect(result.executable == contents.appending(path: "MacOS/Echo"))

        let verify = try run("/usr/bin/codesign", ["--verify", "--strict", result.app.path])
        #expect(verify.status == 0, "\(verify.output)")
        let entitlements = try run("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", result.app.path])
        #expect(entitlements.output.contains("com.apple.security.app-sandbox"))
        #expect(entitlements.output.contains("com.apple.security.get-task-allow"))
        let requirement = try run("/usr/bin/codesign", ["-d", "-r-", result.app.path])
        #expect(requirement.output.contains("identifier \"com.example.dstlld-bundler-tests.Echo\""))

        // A second run replaces the bundle rather than failing or merging.
        let again = try BundleAssembler.assemble(spec(configuration: .release))
        let releaseEntitlements = try run("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", again.app.path])
        #expect(!releaseEntitlements.output.contains("get-task-allow"))
    }

    @Test func resourceBundlesAreCopiedWithAWarning() throws {
        let bundle = root.appending(path: "build/Echo_Echo.bundle")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "out"), withIntermediateDirectories: true)
        var spec = spec()
        spec.resourceBundles = [bundle]
        let result = try BundleAssembler.assemble(spec, sign: false)
        #expect(FileManager.default.fileExists(atPath: result.app.appending(path: "Contents/Resources/Echo_Echo.bundle").path))
        #expect(result.warnings.count == 1)
    }

    private func run(_ path: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(filePath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
