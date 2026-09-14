#if OPENAPPS_LICENSING
import Foundation
import OpenReactionCore

/// Dodo Payments' public license endpoints over URLSession. Sends only the
/// license key, the activation name "Mac" and the activation id; never the
/// Mac's name, user, hardware ids or anything typed.
struct DodoLicenseClient: LicenseClient {
    let host: URL
    private let session: URLSession

    init(host: URL) {
        self.host = host
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    func activate(licenseKey: String, name: String) async -> ActivationResult {
        let response = await post("licenses/activate", body: ["license_key": licenseKey, "name": name])
        switch response {
        case .failure: return .unreachable
        case .success(let http, let data):
            switch http.statusCode {
            case 200, 201:
                guard let activation = Self.parseActivation(data, serverDate: Self.date(of: http)) else { return .malformed }
                return .activated(activation)
            case 404: return .keyNotFound
            case 403: return .keyDisabledOrExpired
            case 422: return .activationLimitReached
            case 429: return .rateLimited(retryAfter: Self.retryAfter(http))
            default: return .unreachable
            }
        }
    }

    func validate(licenseKey: String, instanceID: String) async -> ValidationResult {
        let response = await post("licenses/validate", body: ["license_key": licenseKey, "license_key_instance_id": instanceID])
        switch response {
        case .failure: return .unreachable
        case .success(let http, let data):
            switch http.statusCode {
            case 200:
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let valid = object["valid"] as? Bool else { return .unreachable }
                return valid ? .valid(serverDate: Self.date(of: http)) : .invalid
            case 429: return .rateLimited(retryAfter: Self.retryAfter(http))
            default: return .unreachable
            }
        }
    }

    func deactivate(licenseKey: String, instanceID: String) async -> DeactivationResult {
        let response = await post("licenses/deactivate", body: ["license_key": licenseKey, "license_key_instance_id": instanceID])
        switch response {
        case .failure: return .unreachable
        case .success(let http, _):
            switch http.statusCode {
            case 200...299: return .deactivated
            case 429: return .rateLimited(retryAfter: Self.retryAfter(http))
            default: return .unreachable
            }
        }
    }

    // MARK: - Transport

    private enum Response {
        case success(HTTPURLResponse, Data)
        case failure
    }

    private func post(_ path: String, body: [String: String]) async -> Response {
        var request = URLRequest(url: host.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return .failure }
        request.httpBody = payload
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure }
            return .success(http, data)
        } catch {
            return .failure
        }
    }

    private static func parseActivation(_ data: Data, serverDate: Date?) -> Activation? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? String,
              let product = object["product"] as? [String: Any],
              let productID = product["product_id"] as? String else { return nil }
        let name = product["name"] as? String ?? productID
        // The contract needs the activation time; an answer without it is not usable.
        guard let createdAt = (object["created_at"] as? String).flatMap(Self.parseISO8601) else { return nil }
        return Activation(instanceID: id, productID: productID, productName: name, createdAt: createdAt, serverDate: serverDate)
    }

    private static func parseISO8601(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }

    /// The response `Date` header (RFC 7231), if present.
    private static func date(of response: HTTPURLResponse) -> Date? {
        response.value(forHTTPHeaderField: "Date").flatMap(httpDate)
    }

    /// Retry-After as seconds or an HTTP date, bounded to 1 s … 1 day; 60 s
    /// when absent or unusable.
    private static func retryAfter(_ response: HTTPURLResponse) -> TimeInterval {
        guard let value = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces) else { return 60 }
        let seconds: TimeInterval
        if let number = TimeInterval(value), number.isFinite {
            seconds = number
        } else if let date = httpDate(value) {
            seconds = date.timeIntervalSinceNow
        } else {
            return 60
        }
        return min(max(1, seconds), 86_400)
    }

    private static func httpDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value)
    }
}
#endif
