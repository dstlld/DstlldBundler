//
//  ExportTests.swift
//  DstlldBundlerCoreTests
//

@testable import DstlldBundlerCore
import CoreGraphics
import Foundation
import Testing

@Suite struct SigningIdentityTests {
    static let findIdentityOutput = """
          1) 764B19F116D35E5D75BD7E2176D16561921C9CA3 "Apple Development: Jane Doe (VLLSAEGFTZ)"
          2) 0123456789ABCDEF0123456789ABCDEF01234567 "Developer ID Application: Jane Doe (ABCDE12345)"
          3) FEDCBA9876543210FEDCBA9876543210FEDCBA98 "Apple Distribution: Jane Doe (ABCDE12345)"
             3 valid identities found
        """

    @Test func parsesFindIdentity() {
        let certificates = SigningIdentity.parse(findIdentityOutput: Self.findIdentityOutput)
        #expect(certificates.map(\.kind) == [.development, .developerID, .other])
        #expect(certificates[1].hash == "0123456789ABCDEF0123456789ABCDEF01234567")
        #expect(certificates[1].name == "Developer ID Application: Jane Doe (ABCDE12345)")
        #expect(SigningIdentity.parse(findIdentityOutput: "     0 valid identities found\n").isEmpty)
    }

    @Test func prefersDeveloperIDThenDevelopmentThenAdHoc() throws {
        let all = SigningIdentity.parse(findIdentityOutput: Self.findIdentityOutput)
        #expect(try SigningIdentity.choose(nil, from: all) == .certificate(all[1]))
        #expect(try SigningIdentity.choose(nil, from: [all[0], all[2]]) == .certificate(all[0]))
        #expect(try SigningIdentity.choose(nil, from: [all[2]]) == .adHoc)
        #expect(try SigningIdentity.choose(nil, from: []) == .adHoc)
    }

    @Test func honoursAPreference() throws {
        let all = SigningIdentity.parse(findIdentityOutput: Self.findIdentityOutput)
        #expect(try SigningIdentity.choose("-", from: all) == .adHoc)
        #expect(try SigningIdentity.choose("764b19f116d35e5d75bd7e2176d16561921c9ca3", from: all) == .certificate(all[0]))
        #expect(try SigningIdentity.choose("Apple Development", from: all) == .certificate(all[0]))
        #expect(throws: BundlerError.self) { try SigningIdentity.choose("Developer ID Installer", from: all) }
    }

    @Test func onlyDeveloperIDCanBeNotarized() {
        let all = SigningIdentity.parse(findIdentityOutput: Self.findIdentityOutput)
        #expect(SigningIdentity.certificate(all[1]).canNotarize)
        #expect(!SigningIdentity.certificate(all[0]).canNotarize)
        #expect(!SigningIdentity.adHoc.canNotarize)
    }

    @Test func certificateSigningUsesTheHardenedRuntime() {
        let certificate = SigningIdentity.Certificate(hash: String(repeating: "A", count: 40), name: "Developer ID Application: X")
        let arguments = CodeSigner.arguments(
            bundle: URL(filePath: "/w/Notes.app"), entitlements: URL(filePath: "/w/e.plist"),
            identifier: "com.example.Notes", identity: .certificate(certificate))
        #expect(arguments.contains("runtime"))
        #expect(arguments.contains("--timestamp"))
        #expect(!arguments.contains("--timestamp=none"))
        #expect(!arguments.contains { $0.hasPrefix("-r=") }, "the default requirement names the team")
        #expect(arguments[arguments.firstIndex(of: "--sign")! + 1] == certificate.hash)
        #expect(arguments.last == "/w/Notes.app")
    }
}

@Suite struct DistributionSettingsTests {
    @Test func readsTheKeysThatAreSet() throws {
        let settings = try DistributionSettings(["NotaryProfile": " notary ", "SigningIdentity": ""])
        #expect(settings == DistributionSettings(notaryProfile: "notary"))
        #expect(settings.plist == ["NotaryProfile": "notary"])
    }

    @Test func rejectsBadValues() {
        #expect(throws: BundlerError.self) { try DistributionSettings(["NotaryProfile": 3]) }
        #expect(throws: BundlerError.self) { try DistributionSettings(["DiskImageName": "a/b"]) }
    }

    @Test func aMissingFileIsTheDefaults() throws {
        #expect(try DistributionSettings.load(URL(filePath: "/nonexistent/Distribution.plist")) == DistributionSettings())
    }
}

@Suite struct NotarizerTests {
    @Test func readsTheVerdictAfterProgress() throws {
        let output = """
            Conducting pre-submission checks for Notes.dmg and initiating connection to the Apple notary service...
            {"id":"2efe2717-52ef-43a5-96dc-0797e4ca1041","status":"Invalid","message":"Processing complete"}
            """
        let verdict = try Notarizer.verdict(fromSubmitOutput: output)
        #expect(verdict.id == "2efe2717-52ef-43a5-96dc-0797e4ca1041")
        #expect(verdict.status == "Invalid")
    }

    @Test func aReplyWithoutAnIdIsAnError() {
        #expect(throws: BundlerError.self) {
            try Notarizer.verdict(fromSubmitOutput: #"{"message":"HTTP status code: 401. Unable to authenticate."}"#)
        }
        #expect(throws: BundlerError.self) { try Notarizer.verdict(fromSubmitOutput: "Error: no network") }
    }

    @Test func listsTheLogsIssues() {
        let log = """
            {"issues":[{"severity":"error","path":"Notes.dmg/Notes.app/Contents/MacOS/Notes",
            "message":"The executable does not have the hardened runtime enabled."}]}
            """
        #expect(Notarizer.problems(fromLog: log) == [
            "Notes.dmg/Notes.app/Contents/MacOS/Notes: The executable does not have the hardened runtime enabled."
        ])
    }
}

@Suite struct ExportArgumentTests {
    @Test func roundTrips() throws {
        let spec = ExportSpec(
            productName: "Notes", executable: URL(filePath: "/b/Notes"),
            appDirectory: URL(filePath: "/p/App/Notes", directoryHint: .isDirectory),
            outputDirectory: URL(filePath: "/p/Exports", directoryHint: .isDirectory),
            workDirectory: URL(filePath: "/w", directoryHint: .isDirectory),
            resourceBundles: [URL(filePath: "/b/Notes_Notes.bundle")], signingIdentity: "-",
            notaryProfile: "notary", notarize: false)
        let arguments = ToolArguments.arguments(for: spec)
        #expect(arguments.first == "export")
        #expect(try ToolArguments.parseExport(Array(arguments.dropFirst())) == spec)
    }

    @Test func actoolArguments() {
        let arguments = IconCompiler.arguments(
            icon: URL(filePath: "/p/AppIcon.icon"), resources: URL(filePath: "/a/Resources"),
            partialInfoPlist: URL(filePath: "/t/p.plist"), minimumSystemVersion: "27.0")
        #expect(arguments.first == "/p/AppIcon.icon")
        #expect(arguments.contains("--app-icon"))
        #expect(arguments[arguments.firstIndex(of: "--minimum-deployment-target")! + 1] == "27.0")
    }
}

@Suite struct DSStoreTests {
    /// Reads back what `DSStore.data` wrote, checking the allocator's bookkeeping on the way.
    struct Reader {
        let body: Data

        init(_ file: Data) throws {
            #expect(file.prefix(4) == Data([0, 0, 0, 1]))
            body = file.dropFirst(4).withUnsafeBytes { Data($0) }
            #expect(String(decoding: body.prefix(4), as: UTF8.self) == "Bud1")
        }

        func uint32(_ offset: Int) -> UInt32 {
            body[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
        }

        func block(_ address: UInt32) -> (offset: Int, size: Int) {
            (Int(address & ~0x1F), 1 << Int(address & 0x1F))
        }

        /// Block addresses, the table of contents and the free lists.
        func allocator() -> (addresses: [UInt32], toc: [String: UInt32], free: [[UInt32]]) {
            let root = Int(uint32(4))
            #expect(uint32(4) == uint32(12), "the root offset is written twice")
            let count = Int(uint32(root))
            var addresses: [UInt32] = []
            for index in 0..<count { addresses.append(uint32(root + 8 + index * 4)) }
            var cursor = root + 8 + 256 * 4
            var toc: [String: UInt32] = [:]
            let entries = uint32(cursor)
            cursor += 4
            for _ in 0..<entries {
                let length = Int(body[cursor])
                let name = String(decoding: body[(cursor + 1)..<(cursor + 1 + length)], as: UTF8.self)
                toc[name] = uint32(cursor + 1 + length)
                cursor += 1 + length + 4
            }
            var free: [[UInt32]] = []
            for _ in 0..<32 {
                let entries = Int(uint32(cursor))
                free.append((0..<entries).map { uint32(cursor + 4 + $0 * 4) })
                cursor += 4 + entries * 4
            }
            return (addresses, toc, free)
        }

        /// Each record's name, code and type, in file order.
        func records() -> [(name: String, code: String, type: String)] {
            let (addresses, toc, _) = allocator()
            let tree = block(addresses[Int(toc["DSDB"]!)]).offset
            let leaf = block(addresses[Int(uint32(tree))]).offset
            #expect(uint32(tree + 4) == 0, "one level")
            #expect(uint32(leaf) == 0, "a leaf")
            var cursor = leaf + 8
            var result: [(String, String, String)] = []
            for _ in 0..<uint32(leaf + 4) {
                let length = Int(uint32(cursor))
                let units = (0..<length).map { UInt16(body[cursor + 4 + $0 * 2]) << 8 | UInt16(body[cursor + 5 + $0 * 2]) }
                cursor += 4 + length * 2
                let code = String(decoding: body[cursor..<cursor + 4], as: UTF8.self)
                let type = String(decoding: body[cursor + 4..<cursor + 8], as: UTF8.self)
                cursor += 8
                switch type {
                case "long", "shor", "type": cursor += 4
                case "bool": cursor += 1
                case "blob": cursor += 4 + Int(uint32(cursor))
                case "ustr": cursor += 4 + Int(uint32(cursor)) * 2
                default: Issue.record("unknown type \(type)")
                }
                result.append((String(decoding: units, as: UTF16.self), code, type))
            }
            return result
        }
    }

    @Test func usedAndFreeBlocksTileTheWholeSpace() throws {
        let reader = try Reader(try DSStore.data([DSStore.Record(name: "A.app", code: "Iloc", value: .long(1))]))
        let (addresses, toc, free) = reader.allocator()
        #expect(toc["DSDB"] == 1)
        var spans = addresses.map { reader.block($0) } + [(offset: 0, size: 32)]  // the file header
        for (log2Size, offsets) in free.enumerated() {
            spans += offsets.map { (offset: Int($0), size: 1 << log2Size) }
        }
        spans.sort { $0.offset < $1.offset }
        var end = 0
        for span in spans {
            #expect(span.offset == end, "blocks overlap or leave a gap at \(end)")
            #expect(span.offset % span.size == 0, "a block is aligned to its size")
            end = span.offset + span.size
        }
        #expect(end == 1 << 31)
    }

    @Test func recordsAreSortedCaseInsensitivelyThenByCode() throws {
        let records = [
            DSStore.Record(name: "b.app", code: "Iloc", value: .long(1)),
            DSStore.Record(name: ".", code: "vSrn", value: .long(1)),
            DSStore.Record(name: "Applications", code: "Iloc", value: .blob(Data([1, 2, 3]))),
            DSStore.Record(name: ".", code: "bwsp", value: .blob(Data())),
            DSStore.Record(name: "B.app", code: "Iloc", value: .bool(true)),
            DSStore.Record(name: "c", code: "name", value: .string("ü")),
        ]
        let read = try Reader(try DSStore.data(records)).records()
        #expect(read.map(\.name) == [".", ".", "Applications", "b.app", "B.app", "c"])
        #expect(read.map(\.code) == ["bwsp", "vSrn", "Iloc", "Iloc", "Iloc", "name"])
        #expect(read.map(\.type) == ["blob", "long", "blob", "long", "bool", "ustr"])
    }

    @Test func aDiskImageWindow() throws {
        let records = try DSStore.diskImageWindow(
            size: (660, 400), iconSize: 128, textSize: 13, background: Data([0xAA]),
            positions: [("Notes.app", 165, 205), ("Applications", 495, 205)])
        let iconView = try #require(records.first { $0.code == "icvp" })
        guard case .blob(let data) = iconView.value else { Issue.record("icvp is a blob"); return }
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["backgroundType"] as? Int == 2)
        #expect(plist["backgroundImageAlias"] as? Data == Data([0xAA]))
        #expect(DSStore.iconLocation(x: 165, y: 205) == Data([0, 0, 0, 165, 0, 0, 0, 205, 255, 255, 255, 255, 255, 255, 0, 0]))
        let bounds = try #require(records.first { $0.code == "bwsp" })
        guard case .blob(let window) = bounds.value else { Issue.record("bwsp is a blob"); return }
        let windowPlist = try #require(try PropertyListSerialization.propertyList(from: window, format: nil) as? [String: Any])
        #expect(windowPlist["WindowBounds"] as? String == "{{200, 120}, {660, 432}}")
    }
}

@Suite struct AliasRecordTests {
    @Test func layout() {
        let alias = AliasRecord(
            volumeName: "Notes 1.0", volumeCreated: Date(timeIntervalSince1970: 0), volumeMountPoint: "/Volumes/Notes 1.0",
            parentID: 18, parentName: ".background", fileID: 19, fileName: "background.tiff",
            fileCreated: Date(timeIntervalSince1970: 0), pathInVolume: "/.background/background.tiff")
        let data = alias.data
        let bytes = [UInt8](data)
        #expect(Int(bytes[4]) << 8 | Int(bytes[5]) == data.count, "the size field is the whole record")
        #expect(bytes[6...7] == [0, 2], "version 2")
        #expect(bytes[10] == 9, "the volume name's length")
        #expect(String(decoding: bytes[11..<20], as: UTF8.self) == "Notes 1.0")
        #expect(bytes[38...41] == [0x7C, 0x25, 0xB0, 0x80], "1970 in seconds since 1904")
        #expect(bytes[46...49] == [0, 0, 0, 18], "the parent's id")
        #expect(bytes[50] == 15, "the file name's length")

        // Walk the tags after the 150-byte fixed part.
        var tags: [Int: [UInt8]] = [:]
        var cursor = 150
        while true {
            let tag = Int(Int16(bitPattern: UInt16(bytes[cursor]) << 8 | UInt16(bytes[cursor + 1])))
            let length = Int(bytes[cursor + 2]) << 8 | Int(bytes[cursor + 3])
            if tag == -1 { break }
            tags[tag] = Array(bytes[(cursor + 4)..<(cursor + 4 + length)])
            cursor += 4 + length + length % 2
        }
        #expect(cursor + 4 == data.count)
        #expect(String(decoding: tags[2] ?? [], as: UTF8.self) == "Notes 1.0:.background:background.tiff")
        #expect(String(decoding: tags[18] ?? [], as: UTF8.self) == "/.background/background.tiff")
        #expect(String(decoding: tags[19] ?? [], as: UTF8.self) == "/Volumes/Notes 1.0")
    }
}

@Suite struct BackgroundTests {
    @Test func samePictureEveryTime() throws {
        let first = try #require(BackgroundRenderer.render(name: "Notes", palette: .neutral, scale: 1))
        let second = try #require(BackgroundRenderer.render(name: "Notes", palette: .neutral, scale: 1))
        #expect(first.width == 660 && first.height == 400)
        #expect(first.dataProvider?.data == second.dataProvider?.data)
        let twoX = try #require(BackgroundRenderer.render(name: "Notes", palette: .neutral, scale: 2))
        #expect(twoX.width == 1320 && twoX.height == 800)
    }

    @Test func findsAnIconsColours() throws {
        // Two thirds orange, one third blue.
        let context = try #require(CGContext(
            data: nil, width: 30, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 30, height: 20))
        context.setFillColor(CGColor(srgbRed: 0, green: 0.3, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 20, width: 30, height: 10))
        let palette = BackgroundRenderer.Palette.from(icon: try #require(context.makeImage()))
        #expect(palette.primary.red > 0.9 && palette.primary.blue < 0.1)
        #expect(palette.secondary.blue > 0.9 && palette.secondary.red < 0.1)
    }

    @Test func inkIsReadable() {
        let background = BackgroundRenderer.Colour(red: 0.9, green: 0.95, blue: 0.93)
        let ink = BackgroundRenderer.readableInk(on: background, from: BackgroundRenderer.Colour(red: 0.3, green: 0.9, blue: 0.7))
        #expect(BackgroundRenderer.contrast(ink, background) >= 4.5)
    }
}

/// Exports a real disk image, ad hoc and without the notary service, then mounts it to look.
@Suite struct ExportIntegrationTests {
    @Test func makesADiskImageWithTheAppAndTheLayout() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "DstlldExportTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }  // best-effort cleanup of a temporary folder
        let app = root.appending(path: "App/Echo")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.example.dstlld-bundler-tests.Echo", "CFBundleShortVersionString": "2.1",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appending(path: "Info.plist"))
        try FileManager.default.createDirectory(at: root.appending(path: "build"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(filePath: "/bin/echo"), to: root.appending(path: "build/Echo"))

        var steps: [String] = []
        let result = try ExportPipeline.run(
            ExportSpec(
                productName: "Echo", executable: root.appending(path: "build/Echo"), appDirectory: app,
                outputDirectory: root.appending(path: "Exports"), workDirectory: root.appending(path: "work"),
                notarize: false),
            certificates: []
        ) { steps.append($0) }

        #expect(result.diskImage.lastPathComponent == "Echo 2.1.dmg")
        #expect(result.identity == .adHoc)
        #expect(!result.isNotarized)
        #expect(result.warnings.contains { $0.contains("only this Mac") })
        #expect(steps.count == 3)

        let mountPoint = root.appending(path: "mounted")
        let attach = Command.run(
            URL(filePath: "/usr/sbin/diskutil"),
            ["image", "attach", "--nobrowse", "--readOnly", "--mountPoint", mountPoint.path, result.diskImage.path])
        #expect(attach.succeeded, "\(attach.output)")
        defer { _ = Command.run(URL(filePath: "/usr/sbin/diskutil"), ["eject", mountPoint.path]) }
        let names = try FileManager.default.contentsOfDirectory(atPath: mountPoint.path)
        #expect(Set(names).isSuperset(of: ["Echo.app", "Applications", ".background", ".DS_Store"]))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: mountPoint.appending(path: "Applications").path)
            == "/Applications")
        let records = try DSStoreTests.Reader(try Data(contentsOf: mountPoint.appending(path: ".DS_Store"))).records()
        #expect(records.contains { $0.name == "Echo.app" && $0.code == "Iloc" })
        let verify = Command.run(CodeSigner.codesign, ["--verify", "--deep", "--strict", mountPoint.appending(path: "Echo.app").path])
        #expect(verify.succeeded, "\(verify.output)")
    }
}

@Suite struct IconTests {
    static let fixtureIcon = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "Fixtures/HelloApp/App/HelloApp/AppIcon.icon")
    static let hasActool = Command.run(URL(filePath: "/usr/bin/xcrun"), ["--find", "actool"]).succeeded

    @Test(.enabled(if: hasActool, "compiling an icon needs Xcode"))
    func compilesTheIconIntoTheBundle() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "DstlldIconTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }  // best-effort cleanup of a temporary folder
        let app = root.appending(path: "App/Echo")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Self.fixtureIcon, to: app.appending(path: "AppIcon.icon"))
        let info: [String: Any] = ["CFBundleIdentifier": "com.example.dstlld-bundler-tests.Echo"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appending(path: "Info.plist"))
        try FileManager.default.copyItem(at: URL(filePath: "/bin/echo"), to: root.appending(path: "Echo"))

        let result = try BundleAssembler.assemble(BundleSpec(
            productName: "Echo", executable: root.appending(path: "Echo"), appDirectory: app,
            output: root.appending(path: "Echo.app", directoryHint: .isDirectory)))
        #expect(result.warnings.isEmpty, "\(result.warnings)")
        let resources = result.app.appending(path: "Contents/Resources")
        #expect(FileManager.default.fileExists(atPath: resources.appending(path: "AppIcon.icns").path))
        #expect(FileManager.default.fileExists(atPath: resources.appending(path: "Assets.car").path))
        let bundled = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: result.app.appending(path: "Contents/Info.plist")), format: nil) as? [String: Any]
        #expect(bundled?["CFBundleIconName"] as? String == "AppIcon")
    }

    @Test func noIconIsNotAProblem() {
        #expect(IconCompiler.compile(
            icon: URL(filePath: "/nonexistent/AppIcon.icon"), into: URL(filePath: "/tmp"), minimumSystemVersion: "27.0")
            == .noIcon)
    }
}
