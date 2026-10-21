//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import CryptoKit
import Foundation
import Security
import Testing

@testable import SignalServiceKit

struct HttpSecurityPolicyTest {

    /// A chain of certificates we have no quarrel with isn't flagged.
    @Test
    func knownGoodChainIsNotDenied() throws {
        // Signal's own pinned CA
        let signalCa = Certificates.load("signal-messenger", extension: "cer")
        #expect(!HttpSecurityPolicy.containsDeniedCertificate(in: [signalCa]))
    }

    /// One of the compromised eMudhra intermediates is flagged, whether it's the
    /// only certificate in the chain or hiding behind a valid leaf.
    @Test
    func chainContainingCompromisedIntermediateIsDenied() throws {
        let signalCa = Certificates.load("signal-messenger", extension: "cer")
        let deniedCertificate = try Self.makeCertificate(base64Der: Self.deniedCertificateBase64)
        #expect(HttpSecurityPolicy.containsDeniedCertificate(in: [deniedCertificate]))
        #expect(HttpSecurityPolicy.containsDeniedCertificate(in: [deniedCertificate, signalCa]))
        #expect(HttpSecurityPolicy.containsDeniedCertificate(in: [signalCa, deniedCertificate]))
        #expect(HttpSecurityPolicy.containsDeniedCertificate(in: [signalCa, deniedCertificate, signalCa]))
    }

    /// Basic validation the Data/SHA256 behavior is correct
    /// Manually build the hash from the certificate and validate against the
    /// "EM DV TLS CA - G3B -- emSign Root TLS  CA - G3", entry from HttpSecurityPolicy.deniedCertificateDigests
    @Test
    func deniedCertificateFixtureMatchesDenylistedDigest() throws {
        let deniedCertificate = try Self.makeCertificate(base64Der: Self.deniedCertificateBase64)
        let digest = Data(SHA256.hash(data: SecCertificateCopyData(deniedCertificate) as Data))

        #expect(digest.hexadecimalString.uppercased() == "42C4ACCD12C4F59597925E1A08A7A90102608543809308D50EC427E118BA1493")
    }

    // MARK: -

    private static func makeCertificate(base64Der: String) throws -> SecCertificate {
        let der = try #require(Data(base64Encoded: base64Der))
        return try #require(SecCertificateCreateWithData(nil, der as CFData))
    }

    /// "EM DV TLS CA - G3B", issued by "emSign Root TLS CA - G3".
    ///
    /// Sourced from https://emudhra.we-have-a-problem.com/impacted-intermediates.json;
    /// embedded rather than added as a test resource so that a compromised
    /// certificate never ends up in a shipping bundle.
    private static let deniedCertificateBase64 =
        "MIIDaDCCAu6gAwIBAgIQAKSu5njyM2K0wORgt3LyFDAKBggqhkjOPQQDAzBWMQswCQYDVQQG" +
        "EwJJTjElMCMGA1UECgwcZU11ZGhyYSBUZWNobm9sb2dpZXMgTGltaXRlZDEgMB4GA1UEAwwX" +
        "ZW1TaWduIFJvb3QgVExTIENBIC0gRzMwHhcNMjUwNDMwMTU1NDA4WhcNNDAwNDI4MTgzMDAw" +
        "WjA/MQswCQYDVQQGEwJOTDETMBEGA1UECgwKZU11ZGhyYSBCVjEbMBkGA1UEAwwSRU0gRFYg" +
        "VExTIENBIC0gRzNCMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAE557ZwEqXc8RzXlERHahawr1e" +
        "ZKs3S4DhLLwgOOweTw47gS/JhZ4eZ6+wTi+LyX90hbplqpEe6KTkW2LVzAPVa+Z4s8OMtNyT" +
        "fKJGDiOEU8iSk10p1E+R4VYGtjzO2rRoo4IBljCCAZIwHwYDVR0jBBgwFoAU4TqrIXzx401U" +
        "rtRyt/2LWUIgkFQwHQYDVR0OBBYEFOIeL+ccGTkOVUtiwSAkVzUkiiUUMB0GA1UdJQQWMBQG" +
        "CCsGAQUFBwMBBggrBgEFBQcDAjBdBgNVHSAEVjBUMDkGCysGAQQBg44hAQABMCowKAYIKwYB" +
        "BQUHAgEWHGh0dHA6Ly9yZXBvc2l0b3J5LmVtc2lnbi5jb20wDQYLKwYBBAGDjiEBAmQwCAYG" +
        "Z4EMAQIBMHUGCCsGAQUFBwEBBGkwZzAkBggrBgEFBQcwAYYYaHR0cDovL29jc3AtYi5lbXNp" +
        "Z24uY29tMD8GCCsGAQUFBzAChjNodHRwOi8vcmVwb3NpdG9yeS5lbXNpZ24uY29tL2NlcnRz" +
        "L0VNRFZUTFNDQUczQi5wN2MwNwYDVR0fBDAwLjAsoCqgKIYmaHR0cDovL2NybC5lbXNpZ24u" +
        "Y29tLz9yb290dGxzY2FnMy5jcmwwDgYDVR0PAQH/BAQDAgEGMBIGA1UdEwEB/wQIMAYBAf8C" +
        "AQAwCgYIKoZIzj0EAwMDaAAwZQIwLmsGXi6oFMJ2klkcEMXMug6gvxQWZWkewiDWVzQyl2L6" +
        "z6DuQfPOIbh1grvdULDCAjEAxZvLlxUavG69J6wnSjC8XBbqNIQsJ6CE2QdNOe84Ptxb6VG8" +
        "gt2TlfJbHii+KNvK"
}
