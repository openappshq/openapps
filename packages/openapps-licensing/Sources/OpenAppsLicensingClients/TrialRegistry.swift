import Foundation
import IOKit
import OpenAppsLicensing

/// The trial registry over URLSession: `POST <base>/api/trial` with only
/// `{app, device, env}`. The device is a salted one-way hash; the raw
/// hardware UUID never leaves the Mac.
public struct URLSessionTrialRegistryClient: TrialRegistryClient {
    public let endpoint: URL
    /// The app id sent as `app` (`openreaction`).
    public let appID: String
    public let environment: String
    private let session: URLSession

    public init(endpoint: URL, appID: String, environment: String) {
        self.endpoint = endpoint
        self.appID = appID
        self.environment = environment
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    public func register(device: String) async -> TrialRegistrationResult {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = TrialRegistryResponse.requestBody(app: appID, device: device, environment: environment)
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
public struct PlatformDeviceIdentity: DeviceIdentity {
    public init() {}

    public func hardwareUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)
        guard let uuid = value?.takeRetainedValue() as? String,
              !uuid.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return uuid
    }
}
