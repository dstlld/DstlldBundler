//
//  ExportPipeline.swift
//  DstlldBundlerCore
//
//  An export makes something another Mac will open:
//
//    1. bundle a release build, signed with the best certificate in the keychain and the hardened
//       runtime, and check the signature
//    2. draw the window's background, or take the project's own
//    3. make the disk image, and sign it
//    4. notarize and staple it, when the certificate is a Developer ID one and a notary profile is set
//
//  Whatever can't be done is said plainly, so the person knows whether other Macs will open it.
//

import Foundation

public struct ExportSpec: Sendable, Equatable {
    public var productName: String
    /// A release build of the product's executable.
    public var executable: URL
    /// The project's `App/<Product>` folder.
    public var appDirectory: URL
    /// Where the `.dmg` goes.
    public var outputDirectory: URL
    /// A folder for the `.app` and the intermediate image. Emptied first.
    public var workDirectory: URL
    public var resourceBundles: [URL]
    /// Overrides `Distribution.plist`'s `SigningIdentity`.
    public var signingIdentity: String?
    /// Overrides `Distribution.plist`'s `NotaryProfile`.
    public var notaryProfile: String?
    /// Off to skip the notary service, for a quick look at the disk image.
    public var notarize: Bool

    public init(
        productName: String, executable: URL, appDirectory: URL, outputDirectory: URL, workDirectory: URL,
        resourceBundles: [URL] = [], signingIdentity: String? = nil, notaryProfile: String? = nil,
        notarize: Bool = true
    ) {
        self.productName = productName
        self.executable = executable
        self.appDirectory = appDirectory
        self.outputDirectory = outputDirectory
        self.workDirectory = workDirectory
        self.resourceBundles = resourceBundles
        self.signingIdentity = signingIdentity
        self.notaryProfile = notaryProfile
        self.notarize = notarize
    }

    public var distributionFile: URL { appDirectory.appending(path: "Distribution.plist") }
    public var diskImageDirectory: URL { appDirectory.appending(path: "DiskImage", directoryHint: .isDirectory) }
}

public struct ExportResult: Sendable, Equatable {
    public let diskImage: URL
    public let identity: SigningIdentity
    /// Whether the image was notarized and stapled: whether any Mac will open it.
    public let isNotarized: Bool
    public let warnings: [String]
}

public enum ExportPipeline {
    /// Runs the export. `note` hears each step as it starts.
    public static func run(
        _ spec: ExportSpec, certificates: [SigningIdentity.Certificate] = SigningIdentity.available(),
        note: (String) -> Void = { _ in }
    ) throws(BundlerError) -> ExportResult {
        let settings = try DistributionSettings.load(spec.distributionFile)
        let identity = try SigningIdentity.choose(spec.signingIdentity ?? settings.signingIdentity, from: certificates)
        var warnings: [String] = []
        if let warning = trustWarning(identity) { warnings.append(warning) }

        note("bundling \(spec.productName) and signing it \(identity == .adHoc ? "ad hoc" : "as \(identity.displayName)")")
        let app = spec.workDirectory.appending(path: "\(spec.productName).app", directoryHint: .isDirectory)
        try prepare(spec.workDirectory)
        let bundle = try BundleAssembler.assemble(BundleSpec(
            productName: spec.productName, executable: spec.executable, appDirectory: spec.appDirectory,
            output: app, configuration: .release, resourceBundles: spec.resourceBundles, getTaskAllow: false,
            signing: identity))
        warnings += bundle.warnings
        try CodeSigner.verify(app)

        let info = try readInfoPlist(of: app)
        let name = info["CFBundleName"] as? String ?? spec.productName
        let version = info["CFBundleShortVersionString"] as? String ?? "1.0"
        let volumeName = settings.diskImageName ?? "\(name) \(version)"
        let icon = info["CFBundleIconFile"].flatMap { $0 as? String }.map { file in
            app.appending(path: "Contents/Resources/\(file.hasSuffix(".icns") ? file : "\(file).icns")")
        }.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }

        note("drawing the disk image's window")
        let background = spec.workDirectory.appending(path: "background.tiff")
        try drawBackground(name: name, icon: icon, override: spec.diskImageDirectory, to: background)

        note("making the disk image")
        let diskImage = spec.outputDirectory.appending(path: "\(volumeName).dmg")
        try prepareOutput(spec.outputDirectory)
        try DiskImageBuilder.build(DiskImageSpec(
            app: app, volumeName: volumeName, output: diskImage, background: background, volumeIcon: icon,
            workDirectory: spec.workDirectory.appending(path: "image", directoryHint: .isDirectory)))
        if case .certificate(let certificate) = identity {
            try CodeSigner.sign(diskImage: diskImage, certificate: certificate)
        }

        let profile = spec.notaryProfile ?? settings.notaryProfile
        var isNotarized = false
        switch (spec.notarize, identity.canNotarize, profile) {
        case (false, _, _):
            warnings.append(Diagnostic.warning("not notarized: notarization was turned off"))
        case (true, false, _):
            break  // trustWarning already said why
        case (true, true, nil):
            warnings.append(Diagnostic.warning(
                "not notarized, so other Macs will block the app: set NotaryProfile in Distribution.plist to a "
                    + "keychain profile, made once with `\(Notarizer.storeCredentialsCommand(profile: "<name>"))`",
                file: spec.distributionFile))
        case (true, true, let profile?):
            note("waiting for Apple's notary service, which usually takes a few minutes")
            switch try Notarizer.notarize(diskImage, profile: profile) {
            case .accepted:
                note("stapling the notary ticket")
                try Notarizer.staple(diskImage)
                isNotarized = true
            case .rejected(let id, let status, let problems):
                throw BundlerError(
                    (["the notary service did not accept the app (\(status), submission \(id))"] + problems)
                        .joined(separator: "\n  "))
            }
        }
        return ExportResult(diskImage: diskImage, identity: identity, isNotarized: isNotarized, warnings: warnings)
    }

    /// What other Macs will make of an app signed by `identity`, when it is less than all of them.
    static func trustWarning(_ identity: SigningIdentity) -> String? {
        switch identity {
        case .adHoc:
            Diagnostic.warning(
                "signed ad hoc, so only this Mac will open the app: other Macs need a Developer ID Application "
                    + "certificate (Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates)")
        case .certificate(let certificate) where certificate.kind != .developerID:
            Diagnostic.warning(
                "signed with \(certificate.name), which only Macs registered to your team trust, and which cannot "
                    + "be notarized: other Macs will block the app until you sign with a Developer ID Application "
                    + "certificate (Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates)")
        case .certificate:
            nil
        }
    }

    static func drawBackground(name: String, icon: URL?, override: URL, to file: URL) throws(BundlerError) {
        if let own = BackgroundRenderer.loadOverride(in: override) {
            try BackgroundRenderer.writeTIFF(oneX: own.oneX, twoX: own.twoX, to: file)
            return
        }
        let palette = icon.flatMap(BackgroundRenderer.largestImage(in:)).map(BackgroundRenderer.Palette.from(icon:))
            ?? .neutral
        guard let oneX = BackgroundRenderer.render(name: name, palette: palette, scale: 1),
            let twoX = BackgroundRenderer.render(name: name, palette: palette, scale: 2)
        else { throw BundlerError("could not draw the disk image's background") }
        try BackgroundRenderer.writeTIFF(oneX: oneX, twoX: twoX, to: file)
    }

    private static func readInfoPlist(of app: URL) throws(BundlerError) -> [String: Any] {
        do {
            let data = try Data(contentsOf: app.appending(path: "Contents/Info.plist"))
            return try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] ?? [:]
        } catch {
            throw BundlerError("could not read the bundled Info.plist: \(error.localizedDescription)")
        }
    }

    private static func prepare(_ workDirectory: URL) throws(BundlerError) {
        do {
            if FileManager.default.fileExists(atPath: workDirectory.path) {
                try FileManager.default.removeItem(at: workDirectory)
            }
            try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        } catch {
            throw BundlerError("could not prepare the export's work folder: \(error.localizedDescription)")
        }
    }

    private static func prepareOutput(_ directory: URL) throws(BundlerError) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw BundlerError("could not make \(directory.path): \(error.localizedDescription)")
        }
    }
}
