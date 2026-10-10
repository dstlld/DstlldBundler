//
//  Command.swift
//  DstlldBundlerCore
//
//  Runs the system tools the bundler drives: codesign, actool, diskutil, notarytool, stapler.
//

import Foundation

enum Command {
    struct Result: Sendable {
        let status: Int32
        /// Standard output and standard error together, in the order they were written.
        let output: String

        var succeeded: Bool { status == 0 }

        func check(doing what: String) throws(BundlerError) {
            guard succeeded else {
                throw BundlerError("\(what) failed (\(status)): \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
    }

    static func run(_ executable: URL, _ arguments: [String]) -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return Result(status: -1, output: error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    /// `xcrun <tool> …`, so the tool comes from the selected developer directory.
    static func xcrun(_ tool: String, _ arguments: [String]) -> Result {
        run(URL(filePath: "/usr/bin/xcrun"), [tool] + arguments)
    }
}
