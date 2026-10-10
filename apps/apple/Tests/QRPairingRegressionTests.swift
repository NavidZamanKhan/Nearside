import Foundation
import CryptoKit

@main
struct QRPairingRegressionTests {
    static func main() throws {
        var assertions = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message); assertions += 1
        }
        let host = DeviceIdentity()
        let client = DeviceIdentity()
        let payload = QRPairingPayload(hostIdentity: host.publicIdentity, hostName: "Mac + Phone / Café", ip: "192.168.1.20", expirySeconds: 120)
        let parsed = QRPairingPayload.fromURI(payload.toURI())!
        check(parsed.createdAt == payload.createdAt, "Scan must preserve original creation time")
        check(parsed.expirySeconds == 120, "Scan must preserve original TTL")
        check(parsed.hostName == payload.hostName, "URI values must round trip")
        check(parsed.sharedSecretBase64 == payload.sharedSecretBase64, "Base64 must round trip")
        let uri = payload.toURI()
        try parsed.validateSelectedHost(host.publicIdentity, localIdentity: client.publicIdentity)
        assertions += 1
        do {
            try parsed.validateSelectedHost(client.publicIdentity)
            preconditionFailure("Selected peer identity mismatch accepted")
        } catch let error as NearsideError {
            check(error.code == .pairingVerificationFailed && error.correlationId == payload.sessionId,
                "Selected identity mismatch is rejected with a correlated pairing diagnostic")
        }
        do { try parsed.validateSelectedHost(nil, localIdentity: host.publicIdentity); preconditionFailure("Local device QR accepted") }
        catch let error as NearsideError { check(error.code == .pairingVerificationFailed, "Own QR rejected") }
        for malformed in [uri.replacingOccurrences(of: "v=1", with: "v=2"), uri + "&sid=duplicate",
            uri.replacingOccurrences(of: "nearside://pair", with: "https://pair"), uri + "#fragment",
            uri.replacingOccurrences(of: "ttl=120.0", with: "ttl=Infinity")] {
            check(QRPairingPayload.fromURI(malformed) == nil, "Malformed URI must be rejected")
        }
        QRPairingSessions.shared.register(payload)
        let active = try QRPairingSessions.shared.requireActive(payload.sessionId)
        check(active.hostIdentity == host.publicIdentity, "Host session active")
        check(QRPairingSessions.shared.consume(payload.sessionId), "Session consumed once")
        check(!QRPairingSessions.shared.consume(payload.sessionId), "Replay must be denied")
        do { _ = try QRPairingSessions.shared.requireActive(payload.sessionId); preconditionFailure("Consumed session accepted") }
        catch PairingError.sessionExpired { assertions += 1 }
        QRPairingSessions.shared.register(payload); QRPairingSessions.shared.unregister(payload.sessionId)
        do { _ = try QRPairingSessions.shared.requireActive(payload.sessionId); preconditionFailure("Dismissed session accepted") }
        catch PairingError.sessionExpired { assertions += 1 }
        QRPairingSessions.shared.register(payload, expectedClientIdentity: client.publicIdentity)
        do {
            _ = try QRPairingSessions.shared.requireActive(payload.sessionId, clientIdentity: host.publicIdentity)
            preconditionFailure("Wrong selected client accepted")
        } catch let error as NearsideError { check(error.code == .pairingVerificationFailed, "Hosted QR rejects a different selected client") }
        let selectedActive = try QRPairingSessions.shared.requireActive(payload.sessionId, clientIdentity: client.publicIdentity)
        check(selectedActive.sessionId == payload.sessionId, "Wrong client cannot consume the selected client's session")
        QRPairingSessions.shared.unregister(payload.sessionId)
        let hostSession = QRPairingSession(role: .host, localIdentity: host, payload: payload)
        let clientSession = QRPairingSession(role: .client, localIdentity: client, payload: parsed)
        let ht = hostSession.buildTranscript(remoteNonce: clientSession.localNonce, clientIdentity: client.publicIdentity, serverIdentity: host.publicIdentity)
        let ct = clientSession.buildTranscript(remoteNonce: hostSession.localNonce, clientIdentity: client.publicIdentity, serverIdentity: host.publicIdentity)
        check(ht == ct, "Host and client transcript must agree")
        let hk = try hostSession.deriveConfirmationKeys(transcript: ht)
        let ck = try clientSession.deriveConfirmationKeys(transcript: ct)
        let hostProof = hostSession.generateConfirmation(keys: hk, transcript: ht)
        check(clientSession.verifyPeerConfirmation(peerMac: hostProof, expectedKey: ck.serverKey, transcript: ct), "Host proof verified")
        var tampered = hostProof; tampered[0] ^= 0xff
        check(!clientSession.verifyPeerConfirmation(peerMac: tampered, expectedKey: ck.serverKey, transcript: ct), "Tampered proof rejected")
        let wrongTranscript = clientSession.buildTranscript(remoteNonce: hostSession.localNonce, clientIdentity: host.publicIdentity, serverIdentity: client.publicIdentity)
        check(!clientSession.verifyPeerConfirmation(peerMac: hostProof, expectedKey: ck.serverKey, transcript: wrongTranscript), "Identity substitution rejected")
        let vectorHost = "ns1_" + String(repeating: "2", count: 64)
        let vectorClient = "ns1_" + String(repeating: "1", count: 64)
        let vectorURI = "nearside://pair?v=1&sid=11111111-1111-4111-8111-111111111111&id=\(vectorHost)&name=Test&sec=QEFCQ0RFRkdISUpLTE1OT1BRUlNUVVZXWFlaW1xdXl8%3D&created=\(Date().timeIntervalSince1970)&ttl=180"
        let vectorPayload = QRPairingPayload.fromURI(vectorURI)!
        let vectorSession = QRPairingSession(role: .host, localIdentity: host, payload: vectorPayload)
        var vectorTranscript = Data(("nearside-qr-v1" + vectorPayload.sessionId + vectorClient + vectorHost).utf8)
        vectorTranscript.append(contentsOf: (0..<64).map(UInt8.init))
        let vectorKeys = try vectorSession.deriveConfirmationKeys(transcript: vectorTranscript)
        check(vectorSession.generateConfirmation(keys: vectorKeys, transcript: vectorTranscript).base64EncodedString() == "8AiTClp/ehVR8JWEkRNu1Ix2uBSZ3bjNOKQTjnrFNGg=", "Android and Swift host proof vector agrees")
        check(vectorSession.generateConfirmation(keys: vectorKeys, transcript: vectorTranscript + Data("nearside-qr-accepted".utf8)).base64EncodedString() == "VrlzH+wqEKnqMAcEmfyF4UEg+B29XBI/qV7/PKZKkMs=", "Android and Swift final acceptance vector agrees")
        print("QR pairing regression tests passed (\(assertions) assertions)")
    }
}
