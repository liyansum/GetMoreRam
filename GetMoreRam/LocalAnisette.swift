//
//  LocalAnisette.swift
//  GetMoreRam
//
//  On-device Anisette, the same approach SideStore uses for its "local Anisette".
//

import Foundation
import AnisetteKit
import StosSign_API
import StosSign_Auth
import StosSign_Common

/// The device identity an Anisette client presents to Apple.
///
/// Apple validates that the client info is coherent with the rest of the request (locale,
/// time zone, and the machine that was provisioned). A mismatch is answered with `-80045`
/// ("This action cannot be completed at this time"), so the profile used for provisioning and
/// the profile used for signing in must be the same one.
struct AnisetteClientProfile: Equatable {
    let key: String
    let name: String
    let clientInfo: String
    let userAgent: String
    let usesDeviceLocale: Bool

    static let android = AnisetteClientProfile(
        key: "android",
        name: "Android (Pixel 7)",
        clientInfo: "<Pixel 7> <Android;14;UQ1A.240205.002> <com.apple.AuthKit/1 (com.apple.akd/1.0)>",
        userAgent: "AuthKit/1 (Macintosh; OS X 27.0) (com.apple.akd/1.0)",
        usesDeviceLocale: true
    )

    static let macOS = AnisetteClientProfile(
        key: "macos",
        name: "macOS (MacBookPro18,3)",
        clientInfo: "<MacBookPro18,3> <macOS;26.6;25F84> <com.apple.AuthKit/1 (com.apple.akd/1.0)>",
        userAgent: "AuthKit/1 (Macintosh; OS X 26.6) (com.apple.akd/1.0)",
        usesDeviceLocale: false
    )

    static let all: [AnisetteClientProfile] = [.android, .macOS]

    static func resolved(key: String) -> AnisetteClientProfile {
        all.first { $0.key == key } ?? .android
    }

    var locale: String {
        usesDeviceLocale ? Locale.current.identifier : "en_US"
    }

    var timeZone: String {
        usesDeviceLocale ? (TimeZone.current.abbreviation() ?? "UTC") : "UTC"
    }
}

/// Generates Anisette headers without talking to any Anisette server.
///
/// Apple's ADI libraries (`libCoreADI.so`, `libstoreservicescore.so`) are Linux AArch64 ELF
/// binaries. AnisetteKit runs them inside an in-process Unicorn TCI emulator, so this needs
/// no JIT entitlement, no debug server and no remote Anisette service.
///
/// Provisioning happens locally as well: the identifier and its `adi.pb` are always produced
/// by the same emulated ADI, which is why this path cannot hit the `-45061`
/// "not provisioned for this server" mismatch that an imported SideStore identity produces
/// against a public Anisette server.
final class LocalAnisette: @unchecked Sendable {
    static let shared = LocalAnisette()

    enum Failure: LocalizedError {
        case librariesMissing
        case identityUnavailable

        var errorDescription: String? {
            switch self {
            case .librariesMissing:
                return "The on-device Anisette libraries are missing (libCoreADI.so, libstoreservicescore.so)."
            case .identityUnavailable:
                return "The Anisette identifier could not be resolved."
            }
        }

        var recoverySuggestion: String? {
            switch self {
            case .librariesMissing:
                return "Run Scripts/fetch_adi_libraries.py and rebuild so the libraries are copied into the app bundle, or turn off On-device Anisette in Settings."
            case .identityUnavailable:
                return "Tap Clean Up Keychain, then sign in again."
            }
        }
    }

    private let rootDirectory: URL
    private var cachedClient: AnisetteClient?
    private var cachedProfileKey: String?
    private let lock = NSLock()

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        rootDirectory = base.appendingPathComponent("LocalAnisette", isDirectory: true)
    }

    /// Returns Anisette headers for `identifier`, provisioning locally on first use.
    func anisetteData(for identifier: UUID, profile: AnisetteClientProfile) async throws -> AnisetteData {
        let client = try makeClient(profile: profile)
        let (rawHeaders, _) = try await client.getAnisetteData(
            identifier: identifier,
            storage: .disk,
            headers: Self.requestHeaders(for: profile)
        )
        return try Self.makeAnisetteData(
            from: AnisetteRequestHeaders(rawHeaders: rawHeaders),
            identifier: identifier,
            profile: profile
        )
    }

    /// Drops the locally provisioned `adi.pb`; the next call provisions again.
    func resetProvisioning() {
        lock.lock()
        defer { lock.unlock() }
        cachedClient = nil
        cachedProfileKey = nil
        purgeProvisioningStorage()
    }

    // MARK: - Client

    private var profileRecordURL: URL {
        rootDirectory.appendingPathComponent("client-profile.txt")
    }

    private func purgeProvisioningStorage() {
        let fileManager = FileManager.default
        let items = (try? fileManager.contentsOfDirectory(at: rootDirectory, includingPropertiesForKeys: nil)) ?? []
        for item in items where item.lastPathComponent != "ADI" {
            try? fileManager.removeItem(at: item)
        }
    }

    /// A provisioned `adi.pb` only works with the client profile that created it, so a profile
    /// change has to invalidate the stored identity. This also covers the upgrade case where an
    /// `adi.pb` was provisioned by an earlier build with a different client info.
    private func prepareProvisioningStorage(for profile: AnisetteClientProfile) throws {
        let stored = (try? String(contentsOf: profileRecordURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard stored != profile.key else { return }

        purgeProvisioningStorage()
        try profile.key.write(to: profileRecordURL, atomically: true, encoding: .utf8)
    }

    private func makeClient(profile: AnisetteClientProfile) throws -> AnisetteClient {
        lock.lock()
        defer { lock.unlock() }

        if cachedProfileKey == profile.key, let cachedClient { return cachedClient }

        let libraries = try librariesDirectory()
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try prepareProvisioningStorage(for: profile)

        let client = try AnisetteClient(
            provisioningDir: rootDirectory,
            clientInfo: profile.clientInfo,
            userAgent: profile.userAgent,
            libraryDirectoryResolver: { libraries }
        )
        cachedClient = client
        cachedProfileKey = profile.key
        return client
    }

    private func librariesDirectory() throws -> URL {
        // Folder reference in the bundle: GetMoreRam.app/ADI/
        if let bundled = Bundle.main.url(forResource: "ADI", withExtension: nil),
           AnisetteClient.validateLibrariesExist(at: bundled) {
            return bundled
        }
        // Flattened into the bundle root.
        if let resources = Bundle.main.resourceURL,
           AnisetteClient.validateLibrariesExist(at: resources) {
            return resources
        }
        // Dropped in by hand: Application Support/LocalAnisette/ADI/
        let imported = rootDirectory.appendingPathComponent("ADI", isDirectory: true)
        if AnisetteClient.validateLibrariesExist(at: imported) {
            return imported
        }
        throw Failure.librariesMissing
    }

    // MARK: - Conversion

    private static func requestHeaders(for profile: AnisetteClientProfile) -> AnisetteRequestHeaders {
        var headers = AnisetteRequestHeaders.defaultHeaders
        headers.clientInfo = profile.clientInfo
        headers.userAgent = profile.userAgent
        headers.localUserID = AnisetteConstants.defaultLocalUserID
        headers.routingInfo = AnisetteConstants.defaultRoutingInfo
        headers.serialNumber = AnisetteConstants.defaultSerialNumber
        headers.locale = profile.locale
        headers.timeZone = profile.timeZone
        return headers
    }

    /// Converts AnisetteKit headers into the StosSign `AnisetteData` the signing code expects.
    private static func makeAnisetteData(
        from headers: AnisetteRequestHeaders,
        identifier: UUID,
        profile: AnisetteClientProfile
    ) throws -> AnisetteData {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: AnisetteConstants.posixLocaleIdentifier)
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = AnisetteConstants.iso8601DateFormat

        var json: [String: String] = [
            "deviceSerialNumber": headers.serialNumber ?? AnisetteConstants.defaultSerialNumber,
            "routingInfo": headers.routingInfo ?? AnisetteConstants.defaultRoutingInfo,
            "deviceDescription": profile.clientInfo,
            "localUserID": headers.localUserID ?? AnisetteConstants.defaultLocalUserID,
            "deviceUniqueIdentifier": headers.deviceID ?? identifier.uuidString.uppercased(),
            "date": headers.clientTime ?? formatter.string(from: headers.date ?? Date()),
            "locale": profile.locale,
            "timeZone": profile.timeZone
        ]
        if let machineID = headers.machineID { json["machineID"] = machineID }
        if let oneTimePassword = headers.oneTimePassword { json["oneTimePassword"] = oneTimePassword }

        let data = try JSONEncoder().encode(json)
        return try JSONDecoder().decode(AnisetteData.self, from: data)
    }
}
