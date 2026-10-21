//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import CryptoKit
import Security

/// A simplified version of AFNetworking's AFSecurityPolicy.
public struct HttpSecurityPolicy {

    /// SHA-256 digests of the eight eMudhra intermediate certificates and eight
    /// Sectigo cross-certificates found to be compromised.
    /// (see https://emudhra.we-have-a-problem.com for more detail)
    /// (values sourced from https://emudhra.we-have-a-problem.com/impacted-intermediates.json)
    private static let deniedCertificateDigests: Set<Data> = Set([
        // EM DV TLS CA - G3B -- emSign Root TLS CA - G3
        "42C4ACCD12C4F59597925E1A08A7A90102608543809308D50EC427E118BA1493",
        // EM DV TLS CA - G3B -- AAA Certificate Services (Sectigo)
        "45A883F349AEDFD5F3A649B5498FFB121712BA8B448F3F2A91DBC5A766FCDDBE",

        // EM OV TLS CA - G3B -- emSign Root TLS CA - G3
        "98B896625C0C230ADEEC3EB2CF6AAD5001ECF9156A68644E82374CE5833BC25B",
        // EM OV TLS CA - G3B -- AAA Certificate Services (Sectigo)
        "5F1DED4DD590AF74631290CF073B122A2AAC6A1FA479778A0BD43579BD832699",

        // EM EV TLS CA - G3B -- emSign Root TLS CA - G3
        "E7568FE6E12331F4FD7DE61DA4C7559D0F8EB192A218D4741A3BA75184333838",
        // EM EV TLS CA - G3B -- AAA Certificate Services (Sectigo)
        "579480AEA166290BD3C643589E795FC0D0E54E86505D180F1DFF99EFD3199512",

        // EM DV TLS CA - G3C -- emSign Root TLS CA - G3
        "0164D7CEAE5BB909C272AF151FF44B1177AE9B47D9424B94F1D9558C30934D19",
        // EM DV TLS CA - G3C -- AAA Certificate Services (Sectigo)
        "62B7F9868263F72F6911FC78CEAF72C1979158B7368BF648683BB2AA39B02E72",

        // EM OV TLS CA - G3C -- emSign Root TLS CA - G3
        "CB6E15165AC802E9B3F993F16C25D41F4E81C21EBDE71AE1B012AC00BF9C7C3F",
        // EM OV TLS CA - G3C -- AAA Certificate Services (Sectigo)
        "7485B51C0ED192878FA1D2F948FB529AE1842CC5086C4B67F7BE5B2039DE9489",

        // EM EV TLS CA - G3C -- emSign Root TLS CA - G3
        "432EC25F0D28DE9006D97BF752F17BBB2CD41F669933FCB072D9A1148D0261F3",
        // EM EV TLS CA - G3C -- AAA Certificate Services (Sectigo)
        "FD9D5C2DBBD4995AB69B8D50C439D9527B00529199C2FD01B2174EB58F07021F",

        // The following were used for code siging, but listed for completeness

        // EM OV CS CA - G3B -- emSign Root CS CA - G3
        "9E39DE2881273ACC225A149C72BA3E0F51424963669AB633EE1DC7DF5DB067B4",
        // EM OV CS CA - G3B -- AAA Certificate Services (Sectigo)
        "A496E23AC0CAB8155FC9B117B97EAE368EFCBB9041AEC8804D5A308D2D01C2D8",

        // EM OV CS CA - G3C -- emSign Root CS CA - G3
        "4B2460A466F95FD40113BCDCCA2CEB29B3B093921DE45474DA7DF48874C630B1",
        // EM OV CS CA - G3C -- AAA Certificate Services (Sectigo)
        "84112972B8E59D14560AE7E7119654474AAD119990CF3722BFC1E3B91615E1FD",
    ].compactMap { Data(hex: $0) })

    public static let signalCaPinned: HttpSecurityPolicy = .init(pinnedCertificates: [Certificates.load("signal-messenger", extension: "cer")])
    public static let systemDefault: HttpSecurityPolicy = .init()

    private let pinnedCertificates: [SecCertificate]?

    public init(pinnedCertificates: [SecCertificate]? = nil) {
        self.pinnedCertificates = pinnedCertificates
    }

    public func evaluate(serverTrust: SecTrust, domain: String?) -> Bool {
        let policies = [SecPolicyCreateSSL(true, domain as CFString?)]

        guard SecTrustSetPolicies(serverTrust, policies as CFArray) == errSecSuccess else {
            Logger.error("the trust policy could not be set")
            return false
        }

        // use the default anchors if none were prvided in pinnedCertificates
        if let pinnedCertificates, !pinnedCertificates.isEmpty {
            guard SecTrustSetAnchorCertificates(serverTrust, pinnedCertificates as CFArray) == errSecSuccess else {
                Logger.error("the anchor certificates could not be set")
                return false
            }
        }

        guard Self.isValid(serverTrust: serverTrust) else {
            return false
        }

        guard !Self.containsDeniedCertificate(serverTrust: serverTrust) else {
            return false
        }

        return true
    }

    private static func isValid(serverTrust: SecTrust) -> Bool {
        guard SecTrustEvaluateWithError(serverTrust, nil) else {
            return false
        }
        var result: SecTrustResultType = .otherError // initialize to a value that would fail if SecTrustGetTrustResult doesn't overwrite it
        guard SecTrustGetTrustResult(serverTrust, &result) == errSecSuccess else {
            return false
        }
        return result == .unspecified || result == .proceed
    }

    private static func containsDeniedCertificate(serverTrust: SecTrust) -> Bool {
        guard let chain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate] else {
            // Fail closed if we can't get a certificate chain from the server trust
            return true
        }
        return containsDeniedCertificate(in: chain)
    }

    /// Iterates over a certificate chain checking for any explicitly denied certificates.
    static func containsDeniedCertificate(in chain: [SecCertificate]) -> Bool {
        chain.contains { cert in
            let hashedCert = Data(SHA256.hash(data: SecCertificateCopyData(cert) as Data))
            return Self.deniedCertificateDigests.contains(hashedCert)
        }
    }
}
