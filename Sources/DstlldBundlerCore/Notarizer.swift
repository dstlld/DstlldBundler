//
//  Notarizer.swift
//  DstlldBundlerCore
//
//  Sends the disk image to Apple's notary service, waits for the verdict, and staples the ticket
//  to the image so Gatekeeper can check it offline. Notarizing the image covers the app inside it.
//  The app itself is not stapled: it sits inside the signed image, and a second round trip to
//  Apple, often minutes, would be needed to staple it before the image is made. A Mac that copies
//  the app out and opens it offline asks Apple once it is next online.
//
//  Credentials stay in the keychain: `notarytool` reads the profile that `store-credentials` made.
//

import Foundation

public enum Notarizer {
    /// The command that makes a profile, for messages.
    public static func storeCredentialsCommand(profile: String) -> String {
        "xcrun notarytool store-credentials \(profile) --apple-id <your Apple Account> --team-id <team id>"
    }

    public static func submitArguments(_ file: URL, profile: String) -> [String] {
        ["submit", file.path, "--keychain-profile", profile, "--wait", "--output-format", "json"]
    }

    /// `notarytool submit --output-format json`'s reply.
    struct SubmissionDTO: Decodable {
        let id: String?
        let status: String?
        let message: String?
    }

    /// `notarytool log`'s reply, the parts worth showing.
    struct LogDTO: Decodable {
        struct Issue: Decodable {
            let severity: String?
            let path: String?
            let message: String?
        }
        let issues: [Issue]?
    }

    public enum Verdict: Sendable, Equatable {
        case accepted(id: String)
        /// Apple refused the submission; `problems` are the log's issues.
        case rejected(id: String, status: String, problems: [String])
    }

    /// Reads `submit`'s output. notarytool can print progress before the JSON, so the last line
    /// that is a JSON object is the reply.
    public static func verdict(fromSubmitOutput output: String) throws(BundlerError) -> (id: String, status: String) {
        let reply = output.split(whereSeparator: \.isNewline).last { $0.hasPrefix("{") }
        guard let reply else {
            throw BundlerError("the notary service gave no answer: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let submission: SubmissionDTO
        do {
            submission = try JSONDecoder().decode(SubmissionDTO.self, from: Data(reply.utf8))
        } catch {
            throw BundlerError("the notary service's answer could not be read: \(error.localizedDescription)")
        }
        guard let id = submission.id, let status = submission.status else {
            throw BundlerError("the notary service refused the upload: \(submission.message ?? String(reply))")
        }
        return (id, status)
    }

    /// The issues in `notarytool log`'s JSON, one line each.
    public static func problems(fromLog json: String) -> [String] {
        let log: LogDTO
        do {
            log = try JSONDecoder().decode(LogDTO.self, from: Data(json.utf8))
        } catch {
            return ["the notary log could not be read: \(error.localizedDescription)"]
        }
        return (log.issues ?? []).map { issue in
            [issue.path, issue.message].compactMap { $0 }.joined(separator: ": ")
        }
    }

    /// Submits `file` and waits; this usually takes a few minutes.
    public static func notarize(_ file: URL, profile: String) throws(BundlerError) -> Verdict {
        let submitted = Command.xcrun("notarytool", submitArguments(file, profile: profile))
        if !submitted.succeeded, submitted.output.contains("No Keychain password item found") {
            throw BundlerError(
                "there is no notary profile named '\(profile)' in the keychain; make it once with "
                    + "`\(storeCredentialsCommand(profile: profile))`")
        }
        let (id, status) = try verdict(fromSubmitOutput: submitted.output)
        guard status == "Accepted" else {
            let log = Command.xcrun("notarytool", ["log", id, "--keychain-profile", profile])
            return .rejected(id: id, status: status, problems: log.succeeded ? problems(fromLog: log.output) : [])
        }
        return .accepted(id: id)
    }

    /// Attaches the ticket to `file`, then checks that Gatekeeper accepts it.
    public static func staple(_ file: URL) throws(BundlerError) {
        try Command.xcrun("stapler", ["staple", file.path]).check(doing: "stapling the notary ticket")
        try Command.run(
            URL(filePath: "/usr/sbin/spctl"),
            ["--assess", "--type", "open", "--context", "context:primary-signature", "--verbose", file.path]
        ).check(doing: "Gatekeeper's check of the disk image")
    }
}
