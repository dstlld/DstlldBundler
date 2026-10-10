//
//  SigningIdentity.swift
//  DstlldBundlerCore
//
//  Who signs the app. Runs and debug builds are signed ad hoc, which only the building Mac trusts.
//  An export picks a certificate from the keychain: a Developer ID Application certificate is the
//  only kind other Macs accept, and the only kind the notary service takes. An Apple Development
//  certificate is the fallback, which still gives the app a team and the hardened runtime.
//

import Foundation

public enum SigningIdentity: Sendable, Equatable {
    case adHoc
    case certificate(Certificate)

    /// A code-signing certificate with its private key, as `security find-identity` lists it.
    public struct Certificate: Sendable, Equatable {
        /// The SHA-1 of the certificate, which `codesign --sign` takes without ambiguity.
        public let hash: String
        /// The common name, such as `Developer ID Application: Jane Doe (ABCDE12345)`.
        public let name: String

        public init(hash: String, name: String) {
            self.hash = hash
            self.name = name
        }

        public var kind: Kind {
            if name.hasPrefix("Developer ID Application:") { return .developerID }
            if name.hasPrefix("Apple Development:") || name.hasPrefix("Mac Developer:") { return .development }
            return .other
        }
    }

    public enum Kind: Sendable, Equatable {
        /// Accepted by Gatekeeper on any Mac once notarized.
        case developerID
        /// Trusted only on Macs registered to the team.
        case development
        /// Distribution certificates for the App Store, which cannot sign an app run outside it.
        case other
    }

    /// Whether Apple's notary service will take an app signed this way.
    public var canNotarize: Bool {
        if case .certificate(let certificate) = self { return certificate.kind == .developerID }
        return false
    }

    /// How a person would name it: the certificate's name, or "ad hoc".
    public var displayName: String {
        switch self {
        case .adHoc: "ad hoc"
        case .certificate(let certificate): certificate.name
        }
    }

    /// The certificates `security find-identity -v -p codesigning` printed.
    public static func parse(findIdentityOutput output: String) -> [Certificate] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            // `  1) 764B19F1…C9CA3 "Apple Development: Jane Doe (ABCDE12345)"`
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 2)
            guard parts.count == 3, parts[0].hasSuffix(")"), parts[1].count == 40,
                parts[1].allSatisfy(\.isHexDigit), parts[2].hasPrefix("\""), parts[2].hasSuffix("\""),
                parts[2].count >= 2
            else { return nil }
            return Certificate(hash: String(parts[1]), name: String(parts[2].dropFirst().dropLast()))
        }
    }

    /// The valid code-signing certificates in the user's keychains.
    public static func available() -> [Certificate] {
        let result = Command.run(URL(filePath: "/usr/bin/security"), ["find-identity", "-v", "-p", "codesigning"])
        return result.succeeded ? parse(findIdentityOutput: result.output) : []
    }

    /// The identity an export signs with.
    ///
    /// `preference` is what `Distribution.plist` or `--identity` names: `-` for ad hoc, or a
    /// certificate's SHA-1, its full name or the start of it (`Developer ID Application`). Without
    /// one, the first Developer ID certificate wins, then the first development one, then ad hoc.
    public static func choose(_ preference: String?, from certificates: [Certificate]) throws(BundlerError)
        -> SigningIdentity
    {
        if let preference {
            if preference == "-" { return .adHoc }
            let match = certificates.first { $0.hash.caseInsensitiveCompare(preference) == .orderedSame }
                ?? certificates.first { $0.name == preference }
                ?? certificates.first { $0.name.hasPrefix(preference) }
            guard let match else {
                throw BundlerError(
                    "no code-signing certificate in the keychain matches '\(preference)'; "
                        + "`security find-identity -v -p codesigning` lists them")
            }
            return .certificate(match)
        }
        let best = certificates.first { $0.kind == .developerID } ?? certificates.first { $0.kind == .development }
        return best.map(SigningIdentity.certificate) ?? .adHoc
    }
}
