import Foundation
import Security

private let algorithm = "ecdsa_p256_sha256"
private let tagPrefix = "com.hyungchulc.voice-relay.device-key."

private struct HelperFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

private func writeJSON(_ value: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0a]))
}

private func fail(_ error: Error) -> Never {
    let message = error is HelperFailure
        ? String(describing: error)
        : "Remote control device-key helper failed"
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

private func validatedKeyID(_ value: String) throws -> String {
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
    guard !value.isEmpty,
          value.rangeOfCharacter(from: allowed.inverted) == nil else {
        throw HelperFailure("Invalid device key id")
    }
    return value
}

private func applicationTag(for keyID: String) throws -> Data {
    let safeKeyID = try validatedKeyID(keyID)
    return Data((tagPrefix + safeKeyID).utf8)
}

private func securityError(_ prefix: String, _ status: OSStatus) -> HelperFailure {
    let detail = SecCopyErrorMessageString(status, nil) as String? ?? "unknown Security error"
    return HelperFailure("\(prefix) (\(status), \(detail))")
}

private func privateKeyQuery(keyID: String, returnReference: Bool = true) throws -> [CFString: Any] {
    var query: [CFString: Any] = [
        kSecClass: kSecClassKey,
        kSecAttrApplicationTag: try applicationTag(for: keyID),
        kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
        kSecAttrKeyClass: kSecAttrKeyClassPrivate,
        kSecMatchLimit: kSecMatchLimitOne,
    ]
    if returnReference {
        query[kSecReturnRef] = true
    }
    return query
}

private func loadPrivateKey(keyID: String) throws -> SecKey {
    var result: CFTypeRef?
    let status = SecItemCopyMatching(try privateKeyQuery(keyID: keyID) as CFDictionary, &result)
    guard status == errSecSuccess, let key = result as! SecKey? else {
        throw securityError("Device key is unavailable", status)
    }
    return key
}

private func protectionClass(for privateKey: SecKey) -> String {
    let attributes = SecKeyCopyAttributes(privateKey) as NSDictionary? ?? [:]
    let tokenID = attributes[kSecAttrTokenID] as? String
    return tokenID == (kSecAttrTokenIDSecureEnclave as String)
        ? "hardware_secure_enclave"
        : "os_protected_nonextractable"
}

private func spkiData(for privateKey: SecKey) throws -> Data {
    guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
        throw HelperFailure("Device public key is unavailable")
    }
    var copyError: Unmanaged<CFError>?
    guard let external = SecKeyCopyExternalRepresentation(publicKey, &copyError) as Data? else {
        throw HelperFailure("Device public key export failed")
    }
    guard external.count == 65, external.first == 0x04 else {
        throw HelperFailure("Device public key has an unsupported format")
    }
    let p256SPKIPrefix: [UInt8] = [
        0x30, 0x59,
        0x30, 0x13,
        0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
        0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07,
        0x03, 0x42, 0x00,
    ]
    return Data(p256SPKIPrefix) + external
}

private func publicRecord(keyID: String, privateKey: SecKey) throws -> [String: Any] {
    return [
        "keyId": keyID,
        "algorithm": algorithm,
        "protectionClass": protectionClass(for: privateKey),
        "publicKeySpkiDerBase64": try spkiData(for: privateKey).base64EncodedString(),
    ]
}

private func makePrivateKeyAttributes(keyID: String) throws -> [CFString: Any] {
    return [
        kSecAttrIsPermanent: true,
        kSecAttrApplicationTag: try applicationTag(for: keyID),
        kSecAttrLabel: "Voice Relay Remote Controller Device Key",
        kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
}

private func createKey(keyID: String, secureEnclave: Bool) throws -> SecKey {
    var attributes: [CFString: Any] = [
        kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
        kSecAttrKeySizeInBits: 256,
        kSecPrivateKeyAttrs: try makePrivateKeyAttributes(keyID: keyID),
    ]
    if secureEnclave {
        attributes[kSecAttrTokenID] = kSecAttrTokenIDSecureEnclave
    }
    var createError: Unmanaged<CFError>?
    guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &createError) else {
        let detail = createError?.takeRetainedValue().localizedDescription ?? "unknown Security error"
        throw HelperFailure("Device key creation failed (\(detail))")
    }
    return key
}

private func createKey() throws -> [String: Any] {
    let keyID = "voice_relay_" + UUID().uuidString.lowercased()
    do {
        return try publicRecord(keyID: keyID, privateKey: createKey(keyID: keyID, secureEnclave: true))
    } catch {
        return try publicRecord(keyID: keyID, privateKey: createKey(keyID: keyID, secureEnclave: false))
    }
}

private func sign(keyID: String, payloadBase64: String) throws -> [String: Any] {
    guard let payload = Data(base64Encoded: payloadBase64) else {
        throw HelperFailure("Invalid signing payload")
    }
    let privateKey = try loadPrivateKey(keyID: keyID)
    var signError: Unmanaged<CFError>?
    guard let signature = SecKeyCreateSignature(
        privateKey,
        .ecdsaSignatureMessageX962SHA256,
        payload as CFData,
        &signError
    ) as Data? else {
        throw HelperFailure("Device key signing failed")
    }
    return [
        "keyId": keyID,
        "algorithm": algorithm,
        "signatureDerBase64": signature.base64EncodedString(),
    ]
}

private func deleteKey(keyID: String) throws -> [String: Any] {
    let status = SecItemDelete(try privateKeyQuery(keyID: keyID, returnReference: false) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
        throw securityError("Device key deletion failed", status)
    }
    return ["deleted": status == errSecSuccess, "keyId": keyID]
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let command = arguments.first else {
        throw HelperFailure("Missing helper command")
    }
    switch command {
    case "create":
        try writeJSON(createKey())
    case "get":
        guard arguments.count == 2 else { throw HelperFailure("Missing device key id") }
        let keyID = try validatedKeyID(arguments[1])
        try writeJSON(publicRecord(keyID: keyID, privateKey: loadPrivateKey(keyID: keyID)))
    case "sign":
        guard arguments.count == 3 else { throw HelperFailure("Missing signing input") }
        try writeJSON(sign(keyID: try validatedKeyID(arguments[1]), payloadBase64: arguments[2]))
    case "delete":
        guard arguments.count == 2 else { throw HelperFailure("Missing device key id") }
        try writeJSON(deleteKey(keyID: try validatedKeyID(arguments[1])))
    default:
        throw HelperFailure("Unsupported helper command")
    }
} catch {
    fail(error)
}
