//
//  FetchAnisetteDataOperation.swift
//  AltStore
//
//  Created by Riley Testut on 1/7/20.
//  Copyright © 2020 Riley Testut. All rights reserved.
//

import Foundation
import CryptoKit
import StosSign_API
import StosSign_Auth
import StosSign_Common

final class AnisetteDataHelper
{
    var socket: URLSessionWebSocketTask?
    var url: URL?
    var startProvisioningURL: URL?
    var endProvisioningURL: URL?
    var clientInfo: String?
    var userAgent: String?
    var mdLu: String?
    var deviceId: String?
    var menuAnisetteURL: String?

    static var shared: AnisetteDataHelper = AnisetteDataHelper()
    var loggingFunc: ((String) -> Void)?

    private struct Identity {
        let requestIdentifier: String
        let deviceIdentifier: String
        let localUserID: String
        let usesSideStore2Profile: Bool
    }
    private var identity: Identity?

    func resetClientInfo() {
        clientInfo = nil
        userAgent = nil
        mdLu = nil
        deviceId = nil
        identity = nil
    }

    /// On-device Anisette is the default: it needs no server, so an account imported from
    /// SideStore signs in directly instead of failing with -45061 on a public server.
    static var useLocalAnisette: Bool {
        UserDefaults.standard.object(forKey: "UseLocalAnisette") as? Bool ?? true
    }

    func getAnisetteData(refresh: Bool = false) async throws -> AnisetteData {
        if Self.useLocalAnisette {
            let identifier = try localIdentifierUUID()
            printOut("Anisette: on-device ADI emulation, provisioning locally (no server involved).")
            return try await LocalAnisette.shared.anisetteData(for: identifier)
        }

        guard let url else { throw "No Anisette Server Found!" }
        printOut("Anisette server host: \(url.host ?? "(unavailable)")")
        if let identifier = Keychain.shared.identifier,
           let adiPb = Keychain.shared.adiPb, !adiPb.isEmpty {
            return try await fetchAnisetteV3(identifier, adiPb)
        }
        if Keychain.shared.anisetteIdentitySource == "sidestoreImport" {
            throw "The imported SideStore identity is incomplete. Its stored identity has been preserved. Export the account again from SideStore and re-import it."
        }
        return try await provision()
    }

    /// Resolves the stored identifier (UUID or base64 encoded 16 bytes) to a UUID.
    /// A SideStore export is reused as-is so the device identity stays stable; if there is
    /// none, a fresh one is generated. Either way the `adi.pb` is provisioned locally.
    private func localIdentifierUUID() throws -> UUID {
        if let stored = Keychain.shared.identifier, let uuid = Self.uuid(from: stored) {
            return uuid
        }
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = bytes.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let baseAddress = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, baseAddress)
        }
        guard status == errSecSuccess else { throw "Could not generate a local Anisette identity." }

        let encoded = Data(bytes).base64EncodedString()
        Keychain.shared.identifier = encoded
        Keychain.shared.anisetteIdentitySource = "generated"
        Keychain.shared.anisetteIdentityProfile = "sidestore2"
        guard let uuid = Self.uuid(from: encoded) else {
            throw "The local Anisette identity is unavailable."
        }
        printOut("Anisette: generated a new local identity.")
        return uuid
    }

    static func uuid(from identifier: String) -> UUID? {
        if let uuid = UUID(uuidString: identifier) { return uuid }
        guard let data = Data(base64Encoded: identifier), data.count == 16 else { return nil }
        return UUID(uuid: (data[0], data[1], data[2], data[3], data[4], data[5], data[6], data[7],
                           data[8], data[9], data[10], data[11], data[12], data[13], data[14], data[15]))
    }

    // MARK: - COMMON

    func extractAnisetteData(_ data: Data, _ response: HTTPURLResponse?, v3: Bool) async throws -> AnisetteData {
        _ = try validateHTTPResponse(response, stage: "Anisette headers")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            throw "Anisette headers: the server returned invalid JSON."
        }
        if v3, json["result"] == "GetHeadersError" {
            let message = json["message"] ?? "Unknown Anisette server error"
            if message.contains("-45061") {
                if Keychain.shared.anisetteIdentitySource == "sidestoreImport" {
                    printOut("Anisette headers: imported SideStore identity rejected (-45061); stored identity preserved, no automatic provisioning.")
                    throw "The Anisette server rejected the imported SideStore identity (-45061). The identifier and adi.pb have been preserved. Check that the selected server is compatible with the exported SideStore identity, or export and import the account again."
                }
                printOut("Anisette headers: legacy identity is not provisioned (-45061); using the existing legacy provisioning recovery.")
                Keychain.shared.adiPb = nil
                return try await provision()
            }
            throw "Anisette headers: \(redactedDiagnostic(message))"
        }

        var formattedJSON: [String: String] = ["deviceSerialNumber": "0"]
        if let value = json["X-Apple-I-MD-M"] { formattedJSON["machineID"] = value }
        if let value = json["X-Apple-I-MD"] { formattedJSON["oneTimePassword"] = value }
        if let value = json["X-Apple-I-MD-RINFO"] { formattedJSON["routingInfo"] = value }

        if v3 {
            guard let identity, let clientInfo, let mdLu, let deviceId else {
                throw "Anisette headers: the local identity has not been initialized."
            }
            formattedJSON["deviceDescription"] = clientInfo
            formattedJSON["localUserID"] = mdLu
            formattedJSON["deviceUniqueIdentifier"] = deviceId
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = identity.usesSideStore2Profile ? TimeZone(secondsFromGMT: 0) : TimeZone.current
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
            formattedJSON["date"] = formatter.string(from: Date())
            formattedJSON["locale"] = identity.usesSideStore2Profile ? "en_US" : Locale.current.identifier
            formattedJSON["timeZone"] = identity.usesSideStore2Profile ? "UTC" : TimeZone.current.abbreviation()
            if identity.usesSideStore2Profile, formattedJSON["routingInfo"] == nil {
                formattedJSON["routingInfo"] = "17106176"
            }
        } else {
            formattedJSON["deviceDescription"] = json["X-MMe-Client-Info"]
            formattedJSON["localUserID"] = json["X-Apple-I-MD-LU"]
            formattedJSON["deviceUniqueIdentifier"] = json["X-Mme-Device-Id"]
            formattedJSON["date"] = json["X-Apple-I-Client-Time"]
            formattedJSON["locale"] = json["X-Apple-Locale"]
            formattedJSON["timeZone"] = json["X-Apple-I-TimeZone"]
        }
        do {
            let jsonData = try JSONEncoder().encode(formattedJSON)
            let anisette = try JSONDecoder().decode(AnisetteData.self, from: jsonData)
            printOut("Anisette headers: required fields validated.")
            return anisette
        } catch {
            throw "Invalid anisette: the returned data may not contain all required fields."
        }
    }

    private func validateHTTPResponse(_ response: URLResponse?, stage: String) throws -> HTTPURLResponse {
        guard let response = response as? HTTPURLResponse else {
            printOut("\(stage): no HTTP response.")
            throw "\(stage): the server did not return an HTTP response."
        }
        let contentType = redactedDiagnostic(response.value(forHTTPHeaderField: "Content-Type") ?? "(missing)")
        printOut("\(stage): HTTP \(response.statusCode), Content-Type: \(contentType)")
        guard (200..<300).contains(response.statusCode) else {
            throw "\(stage): HTTP \(response.statusCode), Content-Type: \(contentType)."
        }
        return response
    }

    private func appleStatus(in plist: [String: Any]) -> [String: Any]? {
        if let status = plist["Status"] as? [String: Any] { return status }
        return (plist["Response"] as? [String: Any])?["Status"] as? [String: Any]
    }

    private func appleStatusDescription(_ status: [String: Any]?) -> String {
        guard let status else { return "Apple Status: ec=(absent), em=(absent), ed=(absent)" }
        return "Apple Status: ec=\(redactedDiagnostic(status["ec"])), em=\(redactedDiagnostic(status["em"])), ed=\(redactedDiagnostic(status["ed"]))"
    }

    private func parseAppleResponse(_ data: Data, response: URLResponse?, stage: String) throws -> [String: Any] {
        do {
            _ = try validateHTTPResponse(response, stage: stage)
        } catch {
            // Check the HTTP status first, then inspect only Apple's error status.
            // The complete payload may contain provisioning secrets and is never logged.
            let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
            let description = appleStatusDescription(plist.flatMap { appleStatus(in: $0) })
            printOut("\(stage): \(description)")
            throw "\(error.localizedDescription) \(description)"
        }
        guard let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
            printOut("\(stage): Apple Status unavailable; response is not a valid property list.")
            throw "\(stage): response is not a valid Apple property list."
        }
        let status = appleStatus(in: plist)
        let description = appleStatusDescription(status)
        printOut("\(stage): \(description)")
        if let code = status?["ec"], String(describing: code) != "0" {
            throw "\(stage): \(description)"
        }
        return plist
    }

    private func redactedDiagnostic(_ value: Any?) -> String {
        guard let value else { return "(absent)" }
        let raw: String
        if let string = value as? String { raw = string }
        else if let number = value as? NSNumber { raw = number.stringValue }
        else { return "(non-scalar)" }

        var result = raw
        let secrets = [Keychain.shared.identifier, Keychain.shared.adiPb,
                       identity?.requestIdentifier, mdLu, deviceId]
        for case let secret? in secrets where secret.count >= 8 {
            result = result.replacingOccurrences(of: secret, with: "[redacted]", options: .caseInsensitive)
        }
        for pattern in [
            "(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}",
            "[A-Za-z0-9+/=]{32,}"
        ] {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "[redacted]")
            }
        }
        result = result.components(separatedBy: .controlCharacters).joined(separator: " ")
        return String(result.prefix(400))
    }

    // MARK: - V3: PROVISIONING

    func provision() async throws -> AnisetteData {
        if Keychain.shared.anisetteIdentitySource == "sidestoreImport" {
            throw "Automatic provisioning is disabled for an imported SideStore identity. The imported identity has been preserved."
        }
        try await fetchClientInfo()
        guard let lookupURL = URL(string: "https://gsa.apple.com/grandslam/GsService2/lookup") else {
            throw "Provisioning lookup URL is invalid."
        }
        var request = try buildAppleRequest(url: lookupURL)
        request.httpMethod = "GET"
        printOut("Provisioning lookup: requesting Apple endpoint.")
        let (data, response) = try await URLSession.shared.data(for: request)
        let plist = try parseAppleResponse(data, response: response, stage: "Provisioning lookup")
        guard let urls = plist["urls"] as? [String: Any],
              let startString = urls["midStartProvisioning"] as? String,
              let startURL = URL(string: startString),
              let endString = urls["midFinishProvisioning"] as? String,
              let endURL = URL(string: endString) else {
            throw "Provisioning lookup: Apple did not return valid provisioning URLs."
        }
        startProvisioningURL = startURL
        endProvisioningURL = endURL
        printOut("Provisioning lookup: starting the Anisette provisioning session.")
        return try await startProvisioningSession()
    }

    func startProvisioningSession() async throws -> AnisetteData {
        guard let url else { throw "No Anisette Server Found!" }
        let provisioningSessionURL = webSocketURL(from: url.appendingPathComponent("v3").appendingPathComponent("provisioning_session"))
        var wsRequest = URLRequest(url: provisioningSessionURL)
        wsRequest.timeoutInterval = 5
        let socket = URLSession.shared.webSocketTask(with: wsRequest)
        self.socket = socket
        socket.resume()
        try await receiveProvisioningMessages(from: socket)
        guard let identifier = Keychain.shared.identifier,
              let adiPb = Keychain.shared.adiPb else {
            throw "Provisioning completed without the required local identity data."
        }
        return try await fetchAnisetteV3(identifier, adiPb)
    }

    private func receiveProvisioningMessages(from socket: URLSessionWebSocketTask) async throws {
        printOut("Provisioning session: connected.")
        defer {
            socket.cancel(with: .normalClosure, reason: nil)
            if self.socket === socket { self.socket = nil }
        }
        while true {
            let message = try await socket.receive()
            switch message {
            case .string(let string):
                if try await handleProvisioningMessage(string, socket: socket) { return }
            case .data:
                throw "The Anisette server sent binary data instead of text."
            @unknown default:
                throw "The Anisette server sent an unknown WebSocket message."
            }
        }
    }

    private func handleProvisioningMessage(_ string: String, socket: URLSessionWebSocketTask) async throws -> Bool {
        guard let data = string.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? String else {
            throw "The Anisette provisioning server did not return a valid JSON result."
        }
        switch result {
        case "GiveIdentifier":
            guard let identity else { throw "The local Anisette identity is not initialized." }
            printOut("Provisioning session: providing the local identity (value omitted).")
            try await socket.sendJSON(["identifier": identity.requestIdentifier])
        case "GiveStartProvisioningData":
            let spim = try await fetchStartProvisioningData()
            try await socket.sendJSON(["spim": spim])
        case "GiveEndProvisioningData":
            guard let cpim = json["cpim"] as? String else {
                throw "The Anisette provisioning server did not return cpim."
            }
            let endProvisioningData = try await fetchEndProvisioningData(cpim: cpim)
            try await socket.sendJSON(endProvisioningData)
        case "ProvisioningSuccess":
            guard let adiPb = json["adi_pb"] as? String, !adiPb.isEmpty else {
                throw "The Anisette provisioning server did not return adi.pb."
            }
            Keychain.shared.adiPb = adiPb
            printOut("Provisioning session: succeeded.")
            return true
        default:
            if result.contains("Error") || result.contains("Invalid") || ["ClosingPerRequest", "Timeout", "TextOnly"].contains(result) {
                throw "Anisette provisioning: \(redactedDiagnostic(result)). \(redactedDiagnostic(json["message"]))"
            }
        }
        return false
    }

    private func fetchStartProvisioningData() async throws -> String {
        guard let startProvisioningURL else { throw "Provisioning start: no Apple endpoint available." }
        let body = ["Header": [String: Any](), "Request": [String: Any]()]
        var request = try buildAppleRequest(url: startProvisioningURL)
        request.httpMethod = "POST"
        request.httpBody = try PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0)
        printOut("Provisioning start: requesting Apple endpoint.")
        let (data, response) = try await URLSession.shared.data(for: request)
        let plist = try parseAppleResponse(data, response: response, stage: "Provisioning start")
        guard let responseBody = plist["Response"] as? [String: Any],
              let spim = responseBody["spim"] as? String else {
            throw "Provisioning start: Apple did not return spim."
        }
        return spim
    }

    private func fetchEndProvisioningData(cpim: String) async throws -> [String: String] {
        guard let endProvisioningURL else { throw "Provisioning finish: no Apple endpoint available." }
        let body: [String: Any] = ["Header": [String: Any](), "Request": ["cpim": cpim]]
        var request = try buildAppleRequest(url: endProvisioningURL)
        request.httpMethod = "POST"
        request.httpBody = try PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0)
        printOut("Provisioning finish: requesting Apple endpoint.")
        let (data, response) = try await URLSession.shared.data(for: request)
        let plist = try parseAppleResponse(data, response: response, stage: "Provisioning finish")
        guard let responseBody = plist["Response"] as? [String: Any],
              let ptm = responseBody["ptm"] as? String,
              let tk = responseBody["tk"] as? String else {
            throw "Provisioning finish: Apple did not return ptm and tk."
        }
        return ["ptm": ptm, "tk": tk]
    }

    private func webSocketURL(from url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        switch components.scheme {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        default: break
        }
        return components.url ?? url
    }

    func buildAppleRequest(url: URL) throws -> URLRequest {
        guard let identity, let clientInfo, let userAgent, let mdLu, let deviceId else {
            throw "The local Anisette identity is not initialized."
        }
        var request = URLRequest(url: url)
        request.setValue(clientInfo, forHTTPHeaderField: "X-Mme-Client-Info")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/x-xml-plist", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(mdLu, forHTTPHeaderField: "X-Apple-I-MD-LU")
        request.setValue(deviceId, forHTTPHeaderField: "X-Mme-Device-Id")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        request.setValue(formatter.string(from: Date()), forHTTPHeaderField: "X-Apple-I-Client-Time")
        request.setValue(identity.usesSideStore2Profile ? "en_US" : Locale.current.identifier, forHTTPHeaderField: "X-Apple-Locale")
        request.setValue(identity.usesSideStore2Profile ? "UTC" : TimeZone.current.abbreviation(), forHTTPHeaderField: "X-Apple-I-TimeZone")
        return request
    }

    // MARK: - V3: FETCHING

    // SideSign's RemoteAnisetteDataProvider sends UUID bytes as lowercase hex.
    // Legacy GetMoreRam identities retain their original base64/SHA-256 profile.
    private func resolveIdentity(_ identifier: String) throws -> Identity {
        let rawUUID = UUID(uuidString: identifier)
        let bytes: [UInt8]
        if let rawUUID {
            var value = rawUUID.uuid
            bytes = withUnsafeBytes(of: &value) { Array($0) }
        } else {
            guard let decoded = Data(base64Encoded: identifier), decoded.count == 16 else {
                throw "Invalid Anisette identifier: expected a UUID or a base64 encoded 16-byte value. The stored identity has been preserved."
            }
            bytes = Array(decoded)
        }
        let uuid = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        let modern = rawUUID != nil || Keychain.shared.anisetteIdentityProfile == "sidestore2"
        return Identity(
            requestIdentifier: modern ? bytes.map { String(format: "%02x", $0) }.joined() : identifier,
            deviceIdentifier: uuid.uuidString.uppercased(),
            localUserID: modern ? String(repeating: "0", count: 63) + "1" : Data(bytes).sha256().hexEncodedString(),
            usesSideStore2Profile: modern
        )
    }

    func fetchClientInfo() async throws {
        if Keychain.shared.identifier == nil {
            guard Keychain.shared.anisetteIdentitySource != "sidestoreImport" else {
                throw "The imported SideStore identifier is missing. No replacement identity has been generated."
            }
            var bytes = [UInt8](repeating: 0, count: 16)
            let status = bytes.withUnsafeMutableBytes { buffer in
                guard let baseAddress = buffer.baseAddress else { return errSecParam }
                return SecRandomCopyBytes(kSecRandomDefault, buffer.count, baseAddress)
            }
            guard status == errSecSuccess else { throw "Could not generate a local Anisette identity." }
            Keychain.shared.identifier = Data(bytes).base64EncodedString()
        }
        guard let identifier = Keychain.shared.identifier else {
            throw "The local Anisette identifier is unavailable."
        }
        let identity = try resolveIdentity(identifier)
        self.identity = identity
        mdLu = identity.localUserID
        deviceId = identity.deviceIdentifier
        if identity.usesSideStore2Profile {
            // AnisetteKit's default macOS identity, paired with its fixed LU,
            // en_US / UTC and fallback routing information in this profile.
            clientInfo = "<MacBookPro18,3> <macOS;26.6;25F84> <com.apple.AuthKit/1 (com.apple.akd/1.0)>"
            userAgent = "AuthKit/1 (Macintosh; OS X 26.6) (com.apple.akd/1.0)"
            printOut("Anisette identity mode: SideStore 2 / UUID, lowercase hexadecimal V3 identity and AnisetteKit macOS defaults; identity values omitted.")
        } else {
            clientInfo = "<Pixel 7> <Android;14;UQ1A.240205.002> <com.apple.AuthKit/1 (com.apple.akd/1.0)>"
            userAgent = "AuthKit/1 (Macintosh; OS X 27.0) (com.apple.akd/1.0)"
            printOut("Anisette identity mode: legacy base64, existing Pixel 7 client info; identity values omitted.")
        }
    }

    func fetchAnisetteV3(_ identifier: String, _ adiPb: String) async throws -> AnisetteData {
        try await fetchClientInfo()
        guard let url else { throw "No Anisette Server Found!" }
        let requestIdentity = try resolveIdentity(identifier)
        var request = URLRequest(url: url.appendingPathComponent("v3").appendingPathComponent("get_headers"))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "identifier": requestIdentity.requestIdentifier,
            "adi_pb": adiPb
        ])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        return try await extractAnisetteData(data, response as? HTTPURLResponse, v3: true)
    }

    private func printOut(_ text: String?) {
        if let loggingFunc { loggingFunc(text ?? "\n") }
        else { print(text ?? "") }
    }
}

extension URLSessionWebSocketTask {
    func sendJSON(_ dictionary: [String: String]) async throws {
        let data = try JSONSerialization.data(withJSONObject: dictionary)
        guard let string = String(data: data, encoding: .utf8) else {
            throw "Could not encode an Anisette provisioning message."
        }
        try await send(.string(string))
    }
}

extension Data {
    func sha256() -> Data { Data(SHA256.hash(data: self)) }

    func hexEncodedString() -> String {
        map { String(format: "%02hhX", $0) }.joined()
    }
}
