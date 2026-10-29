import CryptoKit
import Foundation
import Network

/// What a new phone and the Mac say on first contact, and nothing else: a connection opened with
/// the pairing identity decodes only this, so it can never carry a `PhoneToMac`.
///
/// Trust on first use. Nothing proves the phone's key belongs to the device named in the request,
/// or the Mac's to the Mac the user picked, so an active attacker on the network at the moment of
/// pairing could sit in the middle. What bounds it is the user's Allow click, possible only while
/// the Mac's setup window is open (constraint 7).
enum Handshake: Codable, Equatable {
    /// Phone to Mac, once.
    case request(phoneID: String, deviceName: String, publicKey: Data)
    /// Mac to phone after Allow. `proof` is an HMAC over the transcript keyed by the derived key, so
    /// the phone stores the key only when both sides hold the same one.
    case accept(macID: String, publicKey: Data, proof: Data)
    case refuse
}

enum Pairing {
    static let serviceType = "_phice._tcp"
    /// The TLS identity of a phone with no key yet. Its key is public on purpose: the secret comes
    /// from the key agreement inside the session, not from TLS.
    static let identity = "phice-pair-v1"
    static let publicKey = Data(SHA256.hash(data: Data(identity.utf8)))

    /// Every field length-prefixed, so no two different transcripts serialise alike.
    static func transcript(phoneID: String, deviceName: String, phoneKey: Data, macID: String,
                           macKey: Data) -> Data {
        let fields = [Data(identity.utf8), Data(phoneID.utf8), Data(deviceName.utf8), phoneKey,
                      Data(macID.utf8), macKey]
        return fields.reduce(into: Data()) { out, field in
            withUnsafeBytes(of: UInt32(field.count).bigEndian) { out.append(contentsOf: $0) }
            out.append(field)
        }
    }

    static func psk(_ secret: Curve25519.KeyAgreement.PrivateKey, peer: Data,
                    transcript: Data) throws -> Data {
        let shared = try secret.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: peer))
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(identity.utf8),
                                                 sharedInfo: transcript, outputByteCount: 32)
        return key.withUnsafeBytes { Data($0) }
    }

    static func proof(psk: Data, transcript: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data("accept".utf8) + transcript,
                                             using: SymmetricKey(data: psk)))
    }

    static func verify(_ proof: Data, psk: Data, transcript: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: Data("accept".utf8) + transcript,
                                               using: SymmetricKey(data: psk))
    }

    /// TLS-PSK as in Apple's "Building a custom peer-to-peer protocol" sample. On a listener,
    /// `admit` runs for each handshake with the identity the client offered; false fails it.
    static func parameters(keys: [(identity: String, key: Data)],
                           admit: (@MainActor (sec_protocol_metadata_t, String) -> Bool)? = nil)
        -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        for (identity, key) in keys {
            sec_protocol_options_add_pre_shared_key(options, key.dispatch, Data(identity.utf8).dispatch)
        }
        // TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256, for forward secrecy. Its AES-128-GCM sibling
        // (0xD001) is silently ignored and falls back to plain PSK (measured), so it is not used.
        sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: 0xCCAC)!)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        // A resumed session could skip `admit`, and the Mac would not know who connected.
        sec_protocol_options_set_tls_resumption_enabled(options, false)
        sec_protocol_options_set_tls_tickets_enabled(options, false)
        if let admit {
            // Documented as the client's hook, but the server calls it too, with the client's
            // identity in the hint; answering nil fails the handshake as "unknown PSK identity".
            sec_protocol_options_set_pre_shared_key_selection_block(options, { metadata, offer, done in
                // The block runs on .main.
                nonisolated(unsafe) let metadata = metadata
                let name = offer.map { String(decoding: Data($0 as DispatchData), as: UTF8.self) }
                let ok = name.map { name in MainActor.assumeIsolated { admit(metadata, name) } }
                done(ok == true ? offer : nil)
            }, .main)
        }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        // The phone's heartbeat always has data in flight, so a Mac that vanishes stops ACKing and
        // the phone drops the connection ~2 s into retransmitting.
        tcp.connectionDropTime = 2
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = true
        // The Mac relistens on the same port after each pairing.
        parameters.allowLocalEndpointReuse = true
        return parameters
    }
}

private extension Data {
    var dispatch: __DispatchData { withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData }
}
