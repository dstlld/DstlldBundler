//
//  Entitlements.swift
//  DstlldBundlerCore
//
//  An app with no entitlements file still gets the App Sandbox: starting sandboxed and opening
//  holes on purpose is safer than the reverse. A file that turns the sandbox off is respected.
//

import Foundation

public enum Entitlements {
    public static let appSandbox = "com.apple.security.app-sandbox"
    public static let getTaskAllow = "com.apple.security.get-task-allow"

    /// Reads `file` if it exists, then applies the configuration's rules.
    public static func load(_ file: URL, configuration: BuildConfiguration, getTaskAllow: Bool) throws(BundlerError) -> [String: Any] {
        var dictionary: [String: Any] = [appSandbox: true]
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                let data = try Data(contentsOf: file)
                guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                    throw BundlerError("entitlements must be a dictionary", file: file)
                }
                dictionary = plist
            } catch let error as BundlerError {
                throw error
            } catch {
                throw BundlerError("entitlements could not be read: \(error.localizedDescription)", file: file)
            }
        }
        return prepare(dictionary, configuration: configuration, getTaskAllow: getTaskAllow)
    }

    /// Debug builds get `get-task-allow` so a debugger can attach. Release builds never do,
    /// even if the file asks: notarization rejects it.
    public static func prepare(_ dictionary: [String: Any], configuration: BuildConfiguration, getTaskAllow: Bool) -> [String: Any] {
        var result = dictionary
        switch configuration {
        case .debug where getTaskAllow:
            result[Self.getTaskAllow] = true
        case .debug:
            break
        case .release:
            result[Self.getTaskAllow] = nil
        }
        return result
    }
}
