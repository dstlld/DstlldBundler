//
//  DistributionSettings.swift
//  DstlldBundlerCore
//
//  `App/<Product>/Distribution.plist`: how an export signs and notarizes. It holds names, never
//  secrets. The notary password lives in the keychain under a profile that
//  `xcrun notarytool store-credentials` made, and the plist names only the profile. Every key is
//  optional, and so is the file.
//

import Foundation

public struct DistributionSettings: Sendable, Equatable {
    public static let signingIdentityKey = "SigningIdentity"
    public static let notaryProfileKey = "NotaryProfile"
    public static let diskImageNameKey = "DiskImageName"

    /// A certificate's SHA-1, name or the start of its name, or `-` for ad hoc. Without one, the
    /// export picks the best certificate in the keychain.
    public var signingIdentity: String?
    /// The keychain profile `notarytool` reads. Without one, the export is not notarized.
    public var notaryProfile: String?
    /// The disk image's file and volume name. Without one, it is `<CFBundleName> <version>`.
    public var diskImageName: String?

    public init(signingIdentity: String? = nil, notaryProfile: String? = nil, diskImageName: String? = nil) {
        self.signingIdentity = signingIdentity
        self.notaryProfile = notaryProfile
        self.diskImageName = diskImageName
    }

    /// Reads `file`; a missing file is the default settings.
    public static func load(_ file: URL) throws(BundlerError) -> DistributionSettings {
        guard FileManager.default.fileExists(atPath: file.path) else { return DistributionSettings() }
        let plist: [String: Any]
        do {
            let data = try Data(contentsOf: file)
            guard let dictionary = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else {
                throw BundlerError("Distribution.plist must be a dictionary", file: file)
            }
            plist = dictionary
        } catch let error as BundlerError {
            throw error
        } catch {
            throw BundlerError("Distribution.plist could not be read: \(error.localizedDescription)", file: file)
        }
        return try DistributionSettings(plist, file: file)
    }

    /// Reads the settings from a plist's dictionary.
    public init(_ plist: [String: Any], file: URL? = nil) throws(BundlerError) {
        func string(_ key: String) throws(BundlerError) -> String? {
            guard let value = plist[key] else { return nil }
            guard let text = value as? String else { throw BundlerError("\(key) must be a string", file: file) }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        self.init(
            signingIdentity: try string(Self.signingIdentityKey),
            notaryProfile: try string(Self.notaryProfileKey),
            diskImageName: try string(Self.diskImageNameKey))
        if let diskImageName, diskImageName.contains("/") || diskImageName.contains(":") {
            throw BundlerError("DiskImageName may not contain '/' or ':'", file: file)
        }
    }

    /// The dictionary to write, with only the keys that are set.
    public var plist: [String: String] {
        var result: [String: String] = [:]
        result[Self.signingIdentityKey] = signingIdentity
        result[Self.notaryProfileKey] = notaryProfile
        result[Self.diskImageNameKey] = diskImageName
        return result
    }
}
