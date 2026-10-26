//
//  SideStoreAccount.swift
//  GetMoreRam
//
//  Created by Codex on 2026/7/7.
//

import Foundation
import CryptoKit
import CommonCrypto

enum SideStoreAnisetteIdentityFormat: Equatable {
    case legacyBase64
    case uuid
}

struct SideStoreAccount: Decodable {
    let version: String
    let email: String
    let password: String
    let adiPB: String
    let localUser: String
    let usesSideStore2Identity: Bool

    var hasApplePassword: Bool { !password.isEmpty }

    /// The identifier remains exactly as exported. Its format determines how the
    /// Anisette client must present it; a UUID is not a legacy base64 identifier.
    var identityFormat: SideStoreAnisetteIdentityFormat? {
        if UUID(uuidString: localUser) != nil { return .uuid }
        if Data(base64Encoded: localUser)?.count == 16 { return .legacyBase64 }
        return nil
    }
    
    enum CodingKeys: String, CodingKey {
        case version
        case email
        case password
        case anisetteAdiBlob
        case anisetteIdentifier
        case adiPB
        case adiPb
        case adipb
        case localUser = "local_user"
        case localuser
        case localUserCamel = "localUser"
    }
    
    init(email: String, password: String, adiPB: String, localUser: String, version: String = "1.0",
         usesSideStore2Identity: Bool? = nil) {
        self.version = version
        self.email = email
        self.password = password
        self.adiPB = adiPB
        self.localUser = localUser
        self.usesSideStore2Identity = usesSideStore2Identity ?? Self.isSideStore2Version(version)
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? "1.0"
        // SideStore 2 can export either a UUID or base64. The schema, not just
        // the raw identifier format, determines its Anisette identity semantics.
        usesSideStore2Identity = container.contains(.anisetteIdentifier) || Self.isSideStore2Version(version)
        email = try container.decodeIfPresent(String.self, forKey: .email) ?? ""
        password = try container.decodeIfPresent(String.self, forKey: .password) ?? ""
        adiPB = try container.decodeIfPresent(String.self, forKey: .anisetteAdiBlob)
            ?? container.decodeIfPresent(String.self, forKey: .adiPB)
            ?? container.decodeIfPresent(String.self, forKey: .adiPb)
            ?? container.decodeIfPresent(String.self, forKey: .adipb)
            ?? ""
        localUser = try container.decodeIfPresent(String.self, forKey: .anisetteIdentifier)
            ?? container.decodeIfPresent(String.self, forKey: .localUser)
            ?? container.decodeIfPresent(String.self, forKey: .localuser)
            ?? container.decodeIfPresent(String.self, forKey: .localUserCamel)
            ?? ""
    }

    private static func isSideStore2Version(_ version: String) -> Bool {
        version == "2" || version.hasPrefix("2.")
    }
}

enum SideStoreAccountImportError: LocalizedError {
    case missingRequiredField(String)
    case invalidFieldType(String)
    case invalidLocalUser
    case invalidAdiPB
    case invalidFileFormat
    case passwordRequired
    case decryptionFailed
    case keyDerivationFailed
    
    var errorDescription: String? {
        switch self {
        case .missingRequiredField(let field):
            return "The SideStore account file is missing \(field)."
        case .invalidFieldType(let field):
            return "The SideStore account field \(field) must be text."
        case .invalidLocalUser:
            return "The SideStore account file has an invalid Anisette identifier."
        case .invalidAdiPB:
            return "The SideStore account file has an invalid Anisette data blob."
        case .invalidFileFormat:
            return "This file does not contain a valid SideStore account export."
        case .passwordRequired:
            return "This SideStore account file is encrypted and needs its file password."
        case .decryptionFailed:
            return "The file password is incorrect, or the encrypted SideStore file is damaged."
        case .keyDerivationFailed:
            return "The file password could not be processed."
        }
    }
    
    var recoverySuggestion: String? {
        switch self {
        case .missingRequiredField, .invalidFieldType, .invalidAdiPB, .invalidFileFormat:
            return "Export your account from SideStore and choose the resulting .sideconf or legacy JSON file. Certificates are not needed here."
        case .invalidLocalUser:
            return "The identifier must be a UUID or a base64 encoded 16-byte value. Export the account again instead of editing its identity."
        case .passwordRequired, .decryptionFailed:
            return "Use the file password chosen when exporting from SideStore. It is separate from your Apple account password."
        case .keyDerivationFailed:
            return "Try importing the file again."
        }
    }
}

/// Official SideStore .sideconf layout: 16-byte salt followed by AES-GCM
/// combined data (12-byte nonce, ciphertext, 16-byte authentication tag).
/// The key is PBKDF2-HMAC-SHA256, 10,000 iterations, 32 bytes.
enum SideStoreConfigurationFile {
    private static let saltLength = 16
    private static let minimumLength = 16 + 12 + 16

    static func jsonDataIfPresent(_ data: Data) -> Data? {
        var jsonData = data
        if jsonData.starts(with: [0xEF, 0xBB, 0xBF]) {
            jsonData = Data(jsonData.dropFirst(3))
        }
        // A random salt can start with "{". Actually parse the JSON rather than
        // guessing from the filename or first byte of an encrypted container.
        guard (try? JSONSerialization.jsonObject(with: jsonData)) != nil else { return nil }
        return jsonData
    }

    static func requiresPassword(for data: Data) -> Bool {
        data.count >= minimumLength && jsonDataIfPresent(data) == nil
    }

    static func decodePayload(_ data: Data, filePassword: String?) throws -> Data {
        if let jsonData = jsonDataIfPresent(data) { return jsonData }
        guard data.count >= minimumLength else {
            throw SideStoreAccountImportError.invalidFileFormat
        }
        guard let filePassword else {
            throw SideStoreAccountImportError.passwordRequired
        }

        let salt = Data(data.prefix(saltLength))
        let passwordData = Data(filePassword.utf8)
        var derivedKey = Data(count: 32)
        let result = derivedKey.withUnsafeMutableBytes { keyBytes in
            salt.withUnsafeBytes { saltBytes in
                passwordData.withUnsafeBytes { passwordBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                        passwordData.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        10_000,
                        keyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        32
                    )
                }
            }
        }
        guard result == kCCSuccess else {
            throw SideStoreAccountImportError.keyDerivationFailed
        }

        do {
            let sealedBox = try AES.GCM.SealedBox(combined: Data(data.dropFirst(saltLength)))
            return try AES.GCM.open(sealedBox, using: SymmetricKey(data: derivedKey))
        } catch {
            throw SideStoreAccountImportError.decryptionFailed
        }
    }
}

enum SideStoreAccountImporter {
    static func requiresPassword(for data: Data) -> Bool {
        SideStoreConfigurationFile.requiresPassword(for: data)
    }

    /// Read-only preview. No Keychain or Anisette state is changed on success or failure.
    static func decodeAccount(from data: Data, filePassword: String? = nil) throws -> SideStoreAccount {
        let jsonData = try SideStoreConfigurationFile.decodePayload(data, filePassword: filePassword)
        let account: SideStoreAccount
        do {
            account = try JSONDecoder().decode(SideStoreAccount.self, from: jsonData)
        } catch DecodingError.typeMismatch(_, let context) {
            if let field = context.codingPath.last?.stringValue {
                throw SideStoreAccountImportError.invalidFieldType(field)
            }
            throw SideStoreAccountImportError.invalidFileFormat
        } catch {
            throw SideStoreAccountImportError.invalidFileFormat
        }
        return try validated(account)
    }

    private static func validated(_ account: SideStoreAccount) throws -> SideStoreAccount {
        let email = account.email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else { throw SideStoreAccountImportError.missingRequiredField("email") }
        guard !account.localUser.isEmpty else { throw SideStoreAccountImportError.missingRequiredField("anisetteIdentifier / local_user") }
        // The exported adi.pb is bound to the Anisette backend that provisioned it, which for
        // SideStore is its own on-device ADI. It can never be reused against another backend,
        // so it is optional here: the local Anisette provisions a matching adi.pb for the same
        // identifier on first sign-in. A present blob is still validated for shape.
        if !account.adiPB.isEmpty {
            guard let blob = Data(base64Encoded: account.adiPB), !blob.isEmpty else {
                throw SideStoreAccountImportError.invalidAdiPB
            }
        }
        guard account.identityFormat != nil else {
            throw SideStoreAccountImportError.invalidLocalUser
        }

        // Keep passwords and both identity fields byte-for-byte as exported.
        return SideStoreAccount(email: email, password: account.password, adiPB: account.adiPB,
                                localUser: account.localUser, version: account.version,
                                usesSideStore2Identity: account.usesSideStore2Identity)
    }

    /// Call only after the user accepts the preview. Validation finishes before any write.
    @discardableResult
    static func storeAccount(_ account: SideStoreAccount) throws -> SideStoreAccount {
        let account = try validated(account)
        Keychain.shared.appleIDEmailAddress = account.email
        Keychain.shared.appleIDPassword = account.password
        Keychain.shared.adiPb = account.adiPB
        Keychain.shared.identifier = account.localUser
        Keychain.shared.anisetteIdentitySource = "sidestoreImport"
        Keychain.shared.anisetteIdentityProfile = account.usesSideStore2Identity ? "sidestore2" : "legacy"
        AnisetteDataHelper.shared.resetClientInfo()
        return account
    }

    /// Compatibility API for callers that already have permission to import immediately.
    static func importAccount(from data: Data, filePassword: String? = nil) throws -> SideStoreAccount {
        try storeAccount(decodeAccount(from: data, filePassword: filePassword))
    }
}
