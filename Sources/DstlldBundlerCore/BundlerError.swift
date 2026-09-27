//
//  BundlerError.swift
//  DstlldBundlerCore
//
//  Every failure names the file to fix. The tool prints them as compiler-style diagnostics
//  (`<path>:1:1: error: …`), which IDEs already know how to show next to the file.
//

import Foundation

public struct BundlerError: Error, Equatable, CustomStringConvertible, Sendable {
    /// The file the user should open to fix this, if there is one.
    public let file: URL?
    public let message: String

    public init(_ message: String, file: URL? = nil) {
        self.message = message
        self.file = file
    }

    public var description: String { Diagnostic.error(message, file: file) }
}

/// Formats messages the way `swiftc` does, so build logs and IDEs treat them alike.
public enum Diagnostic {
    public static func error(_ message: String, file: URL? = nil) -> String {
        format("error", message, file: file)
    }

    public static func warning(_ message: String, file: URL? = nil) -> String {
        format("warning", message, file: file)
    }

    static func format(_ severity: String, _ message: String, file: URL?) -> String {
        guard let file else { return "\(severity): \(message)" }
        return "\(file.standardizedFileURL.path):1:1: \(severity): \(message)"
    }
}
