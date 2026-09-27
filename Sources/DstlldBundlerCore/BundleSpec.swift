//
//  BundleSpec.swift
//  DstlldBundlerCore
//
//  Everything needed to make one `.app`, gathered before anything is written.
//

import Foundation

public enum BuildConfiguration: String, Sendable, CaseIterable {
    case debug
    case release
}

public struct BundleSpec: Sendable, Equatable {
    /// The product's name, which is also the `.app`'s name and the default `CFBundleName`.
    public var productName: String
    /// The built executable to put in `Contents/MacOS`.
    public var executable: URL
    /// The project's `App/<Product>` folder: `Info.plist`, `<Product>.entitlements`, `Resources/`.
    public var appDirectory: URL
    /// Where the `.app` goes. Replaced if it exists.
    public var output: URL
    public var configuration: BuildConfiguration
    /// SwiftPM resource bundles (`<Package>_<Target>.bundle`) to copy into `Contents/Resources`.
    public var resourceBundles: [URL]
    /// Adds `com.apple.security.get-task-allow` in debug builds, so a debugger can attach.
    public var getTaskAllow: Bool

    public init(
        productName: String,
        executable: URL,
        appDirectory: URL,
        output: URL,
        configuration: BuildConfiguration = .debug,
        resourceBundles: [URL] = [],
        getTaskAllow: Bool = true
    ) {
        self.productName = productName
        self.executable = executable
        self.appDirectory = appDirectory
        self.output = output
        self.configuration = configuration
        self.resourceBundles = resourceBundles
        self.getTaskAllow = getTaskAllow
    }

    public var infoPlistFile: URL { appDirectory.appending(path: "Info.plist") }
    public var entitlementsFile: URL { appDirectory.appending(path: "\(productName).entitlements") }
    public var resourcesDirectory: URL { appDirectory.appending(path: "Resources", directoryHint: .isDirectory) }
}
