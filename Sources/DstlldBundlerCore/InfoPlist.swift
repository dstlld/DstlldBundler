//
//  InfoPlist.swift
//  DstlldBundlerCore
//
//  The project's Info.plist is the source of truth. The bundler only fills in the keys every app
//  needs and the project should not have to repeat, and it owns `CFBundleExecutable`, because
//  only the bundler knows what the binary is called.
//

import Foundation

public enum InfoPlist {
    public static let bundleIdentifierKey = "CFBundleIdentifier"

    /// Reads `file` and returns the dictionary to write into the bundle.
    public static func load(_ file: URL, executableName: String, productName: String) throws(BundlerError) -> [String: Any] {
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw BundlerError("no Info.plist for \(productName); create App/\(productName)/Info.plist", file: file)
        }
        let dictionary: [String: Any]
        do {
            let data = try Data(contentsOf: file)
            guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                throw BundlerError("Info.plist must be a dictionary", file: file)
            }
            dictionary = plist
        } catch let error as BundlerError {
            throw error
        } catch {
            throw BundlerError("Info.plist could not be read: \(error.localizedDescription)", file: file)
        }
        return try prepare(dictionary, executableName: executableName, productName: productName, file: file)
    }

    /// Validates `dictionary` and fills in the defaults.
    public static func prepare(
        _ dictionary: [String: Any],
        executableName: String,
        productName: String,
        file: URL? = nil
    ) throws(BundlerError) -> [String: Any] {
        guard let identifier = dictionary[bundleIdentifierKey] as? String, !identifier.isEmpty else {
            throw BundlerError("Info.plist has no CFBundleIdentifier", file: file)
        }
        guard isValidBundleIdentifier(identifier) else {
            throw BundlerError(
                "CFBundleIdentifier '\(identifier)' may only contain letters, digits, '-' and '.'",
                file: file
            )
        }
        var result = dictionary
        result["CFBundleExecutable"] = executableName
        result["CFBundlePackageType"] = "APPL"
        let defaults: [String: String] = [
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": productName,
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "CFBundleDevelopmentRegion": "en",
            "NSPrincipalClass": "NSApplication",
        ]
        for (key, value) in defaults where result[key] == nil {
            result[key] = value
        }
        if result["CFBundleSupportedPlatforms"] == nil {
            result["CFBundleSupportedPlatforms"] = ["MacOSX"]
        }
        return result
    }

    public static func isValidBundleIdentifier(_ identifier: String) -> Bool {
        !identifier.isEmpty
            && !identifier.hasPrefix(".") && !identifier.hasSuffix(".")
            && identifier.unicodeScalars.allSatisfy { scalar in
                scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == ".")
            }
    }
}
