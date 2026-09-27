//
//  CodeSigner.swift
//  DstlldBundlerCore
//
//  Ad-hoc signing. The explicit designated requirement pins the app's identity to its bundle
//  identifier rather than to the hash of this particular build. Without it, every rebuild is a
//  different app as far as the App Sandbox container and privacy prompts are concerned.
//

import Foundation

public enum CodeSigner {
    public static let codesign = URL(filePath: "/usr/bin/codesign")

    public static func arguments(bundle: URL, entitlements: URL, identifier: String) -> [String] {
        [
            "--force",
            "--sign", "-",
            "--entitlements", entitlements.path,
            "--timestamp=none",
            "--generate-entitlement-der",
            "-r=designated => identifier \"\(identifier)\"",
            bundle.path,
        ]
    }

    public static func sign(bundle: URL, entitlements: URL, identifier: String) throws(BundlerError) {
        let (status, output) = run(codesign, arguments(bundle: bundle, entitlements: entitlements, identifier: identifier))
        guard status == 0 else {
            throw BundlerError("codesign failed (\(status)): \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    static func run(_ executable: URL, _ arguments: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
