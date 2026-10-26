import Foundation

// Stubs make it possible to test the actual importer file without an app,
// credentials, network access, or the user's Keychain.
final class Keychain {
    static let shared = Keychain()
    var writes = 0
    var appleIDEmailAddress: String? = "existing@example.invalid" { didSet { writes += 1 } }
    var appleIDPassword: String? = "EXISTING_SYNTHETIC_VALUE" { didSet { writes += 1 } }
    var adiPb: String? = "EXISTING_SYNTHETIC_BLOB" { didSet { writes += 1 } }
    var identifier: String? = "EXISTING_SYNTHETIC_ID" { didSet { writes += 1 } }
    var anisetteIdentitySource: String? { didSet { writes += 1 } }
    var anisetteIdentityProfile: String? { didSet { writes += 1 } }
}
final class AnisetteDataHelper {
    static let shared = AnisetteDataHelper()
    var resets = 0
    func resetClientInfo() { resets += 1 }
}
struct TestFailure: Error { let message: String }
func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure(message: message) }
}

let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
func read(_ file: String) throws -> Data { try Data(contentsOf: folder.appendingPathComponent(file)) }

do {
    let legacy = try SideStoreAccountImporter.decodeAccount(from: read("legacy.json"))
    try expect(!legacy.usesSideStore2Identity && legacy.identityFormat == .legacyBase64, "Legacy profile")
    try expect(legacy.password == "  NOT_A_REAL_PASSWORD  ", "Apple password must not be trimmed")
    let bom = try SideStoreAccountImporter.decodeAccount(from: read("legacy_bom.json"))
    try expect(bom.localUser == legacy.localUser, "UTF-8 BOM")
    let uuid = try SideStoreAccountImporter.decodeAccount(from: read("modern_uuid.json"))
    try expect(uuid.usesSideStore2Identity && uuid.identityFormat == .uuid, "Modern UUID profile")
    try expect(uuid.password.isEmpty && !uuid.hasApplePassword, "Omitted Apple password")
    let modern = try SideStoreAccountImporter.decodeAccount(from: read("modern_base64.json"))
    try expect(modern.usesSideStore2Identity && modern.identityFormat == .legacyBase64, "Modern base64 profile")
    let versionOnly = try SideStoreAccountImporter.decodeAccount(from: read("legacy_keys_v2.json"))
    try expect(versionOnly.usesSideStore2Identity, "Version 2 with legacy aliases")
    let keyOnly = try SideStoreAccountImporter.decodeAccount(from: read("modern_no_version.json"))
    try expect(keyOnly.usesSideStore2Identity, "Modern key without version")

    let encrypted = try read("synthetic.sideconf")
    try expect(encrypted.first == 0x7B, "Fixture salt starts with opening brace")
    try expect(SideStoreAccountImporter.requiresPassword(for: encrypted), "Do not sniff first-byte JSON")
    do {
        _ = try SideStoreAccountImporter.decodeAccount(from: encrypted)
        throw TestFailure(message: "Missing password accepted")
    } catch SideStoreAccountImportError.passwordRequired { }
    do {
        _ = try SideStoreAccountImporter.decodeAccount(from: encrypted, filePassword: "WRONG_SYNTHETIC_PASSWORD")
        throw TestFailure(message: "Wrong password accepted")
    } catch SideStoreAccountImportError.decryptionFailed { }
    var tampered = encrypted
    tampered[tampered.index(before: tampered.endIndex)] ^= 1
    do {
        _ = try SideStoreAccountImporter.decodeAccount(from: tampered, filePassword: "NOT_A_REAL_FILE_PASSWORD_\u{1F510}")
        throw TestFailure(message: "Tampered authentication tag accepted")
    } catch SideStoreAccountImportError.decryptionFailed { }
    let decrypted = try SideStoreAccountImporter.decodeAccount(from: encrypted, filePassword: "NOT_A_REAL_FILE_PASSWORD_\u{1F510}")
    try expect(decrypted.localUser == modern.localUser && decrypted.adiPB == modern.adiPB, "Official container compatibility")
    try expect(Keychain.shared.writes == 0 && AnisetteDataHelper.shared.resets == 0, "Preview mutated storage")

    _ = try SideStoreAccountImporter.storeAccount(decrypted)
    try expect(Keychain.shared.identifier == modern.localUser && Keychain.shared.adiPb == modern.adiPB, "Import must preserve raw identity")
    try expect(Keychain.shared.anisetteIdentitySource == "sidestoreImport" && Keychain.shared.anisetteIdentityProfile == "sidestore2", "Profile metadata")
    try expect(Keychain.shared.appleIDPassword == "", "Omitted password must not retain another account password")
    let writes = Keychain.shared.writes
    do {
        _ = try SideStoreAccountImporter.storeAccount(SideStoreAccount(email: "fixture@example.invalid", password: "", adiPB: modern.adiPB, localUser: "INVALID_SYNTHETIC_ID"))
        throw TestFailure(message: "Invalid account accepted")
    } catch SideStoreAccountImportError.invalidLocalUser { }
    try expect(Keychain.shared.writes == writes, "Failed validation mutated storage")
    print("SideStore import checks passed: legacy/modern schemas, UUID/base64 profiles, official encryption, wrong password, tamper rejection, and storage isolation.")
} catch {
    fputs("SideStore import fixture check failed: \(error)\n", stderr)
    exit(1)
}
