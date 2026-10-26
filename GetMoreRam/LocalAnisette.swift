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
    private let lock = NSLock()

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        rootDirectory = base.appendingPathComponent("LocalAnisette", isDirectory: true)
    }

    /// Returns Anisette headers for `identifier`, provisioning locally on first use.
    func anisetteData(for identifier: UUID) async throws -> AnisetteData {
        let client = try makeClient()
        let (rawHeaders, _) = try await client.getAnisetteData(
            identifier: identifier,
            storage: .disk,
            headers: Self.requestHeaders()
        )
        return try Self.makeAnisetteData(
            from: AnisetteRequestHeaders(rawHeaders: rawHeaders),
            identifier: identifier
        )
    }

    /// Drops the locally provisioned `adi.pb`; the next call provisions again.
    func resetProvisioning() {
        lock.lock()
        defer { lock.unlock() }
        cachedClient = nil
        let fileManager = FileManager.default
        let items = (try? fileManager.contentsOfDirectory(at: rootDirectory, includingPropertiesForKeys: nil)) ?? []
        for item in items where item.lastPathComponent != "ADI" {
            try? fileManager.removeItem(at: item)
        }
    }

    // MARK: - Client

    private func makeClient() throws -> AnisetteClient {
        lock.lock()
        defer { lock.unlock() }
        if let cachedClient { return cachedClient }

        let libraries = try librariesDirectory()
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)

        let client = try AnisetteClient(
            provisioningDir: rootDirectory,
            clientInfo: AnisetteConstants.defaultClientInfo,
            userAgent: AnisetteConstants.defaultUserAgent,
            libraryDirectoryResolver: { libraries }
        )
        cachedClient = client
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

    private static func requestHeaders() -> AnisetteRequestHeaders {
        var headers = AnisetteRequestHeaders.defaultHeaders
        headers.localUserID = AnisetteConstants.defaultLocalUserID
        headers.routingInfo = AnisetteConstants.defaultRoutingInfo
        headers.serialNumber = AnisetteConstants.defaultSerialNumber
        headers.locale = AnisetteConstants.defaultLocale
        headers.timeZone = AnisetteConstants.defaultTimeZone
        return headers
    }

    /// Converts AnisetteKit headers into the StosSign `AnisetteData` the signing code expects.
    private static func makeAnisetteData(
        from headers: AnisetteRequestHeaders,
        identifier: UUID
    ) throws -> AnisetteData {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: AnisetteConstants.posixLocaleIdentifier)
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = AnisetteConstants.iso8601DateFormat

        var json: [String: String] = [
            "deviceSerialNumber": headers.serialNumber ?? AnisetteConstants.defaultSerialNumber,
            "routingInfo": headers.routingInfo ?? AnisetteConstants.defaultRoutingInfo,
            "deviceDescription": headers.clientInfo ?? AnisetteConstants.defaultClientInfo,
            "localUserID": headers.localUserID ?? AnisetteConstants.defaultLocalUserID,
            "deviceUniqueIdentifier": headers.deviceID ?? identifier.uuidString.uppercased(),
            "date": headers.clientTime ?? formatter.string(from: headers.date ?? Date()),
            "locale": headers.locale ?? AnisetteConstants.defaultLocale,
            "timeZone": headers.timeZone ?? AnisetteConstants.defaultTimeZone
        ]
        if let machineID = headers.machineID { json["machineID"] = machineID }
        if let oneTimePassword = headers.oneTimePassword { json["oneTimePassword"] = oneTimePassword }

        let data = try JSONEncoder().encode(json)
        return try JSONDecoder().decode(AnisetteData.self, from: data)
    }
}
