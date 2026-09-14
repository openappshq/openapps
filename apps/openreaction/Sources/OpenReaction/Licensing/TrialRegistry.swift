#if OPENAPPS_LICENSING
import Foundation
import IOKit
import OpenReactionCore

/// The trial registry over URLSession: `POST <base>/api/trial` with only
/// `{app, device, env}`. The device is a salted one-way hash; the raw
/// hardware UUID never leaves the Mac.
struct URLSessionTrialRegistryClient: TrialRegistryClient {
    let endpoint: URL
    let environment: String
    private let session: URLSession

    init(endpoint: URL, environment: String) {
        self.endpoint = endpoint
        self.environment = environment
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    func register(device: String) async -> TrialRegistrationResult {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = TrialRegistryResponse.requestBody(app: LicenseManager.trialAppID, device: device, environment: environment)
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unreachable }
            return TrialRegistryResponse.result(
                statusCode: http.statusCode, retryAfter: http.value(forHTTPHeaderField: "Retry-After"), body: data
            )
        } catch {
            return .unreachable
        }
    }
}

/// `IOPlatformUUID` from the platform expert; nil when it cannot be read.
struct PlatformDeviceIdentity: DeviceIdentity {
    func hardwareUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)
        guard let uuid = value?.takeRetainedValue() as? String,
              !uuid.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return uuid
    }
}
#endif
