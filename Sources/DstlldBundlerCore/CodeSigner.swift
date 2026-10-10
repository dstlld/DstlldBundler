//
//  CodeSigner.swift
//  DstlldBundlerCore
//
//  Ad-hoc signing pins the app's designated requirement to its bundle identifier rather than to the
//  hash of this particular build. Without it, every rebuild is a different app as far as the App
//  Sandbox container and privacy prompts are concerned.
//
//  Signing with a certificate turns on the hardened runtime and a secure timestamp, which the notary
//  service requires, and keeps the default designated requirement, which names the team.
//

import Foundation

public enum CodeSigner {
    public static let codesign = URL(filePath: "/usr/bin/codesign")

    public static func arguments(
        bundle: URL, entitlements: URL, identifier: String, identity: SigningIdentity = .adHoc
    ) -> [String] {
        switch identity {
        case .adHoc:
            [
                "--force",
                "--sign", "-",
                "--entitlements", entitlements.path,
                "--timestamp=none",
                "--generate-entitlement-der",
                "-r=designated => identifier \"\(identifier)\"",
                bundle.path,
            ]
        case .certificate(let certificate):
            [
                "--force",
                "--sign", certificate.hash,
                "--entitlements", entitlements.path,
                "--options", "runtime",
                "--timestamp",
                "--generate-entitlement-der",
                bundle.path,
            ]
        }
    }

    /// `codesign`'s arguments for a disk image, which has no entitlements or runtime.
    public static func diskImageArguments(_ image: URL, certificate: SigningIdentity.Certificate) -> [String] {
        ["--force", "--sign", certificate.hash, "--timestamp", image.path]
    }

    public static func sign(
        bundle: URL, entitlements: URL, identifier: String, identity: SigningIdentity = .adHoc
    ) throws(BundlerError) {
        let arguments = arguments(bundle: bundle, entitlements: entitlements, identifier: identifier, identity: identity)
        try Command.run(codesign, arguments).check(doing: "codesign")
    }

    public static func sign(diskImage: URL, certificate: SigningIdentity.Certificate) throws(BundlerError) {
        try Command.run(codesign, diskImageArguments(diskImage, certificate: certificate)).check(doing: "codesign")
    }

    /// Checks the signature the way Gatekeeper will: every nested item, strictly.
    public static func verify(_ bundle: URL) throws(BundlerError) {
        try Command.run(codesign, ["--verify", "--deep", "--strict", bundle.path]).check(doing: "verifying the signature")
    }
}
