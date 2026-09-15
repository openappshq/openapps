import Foundation
import Security

/// Code-signing checks a staged bundle must pass before it may replace the
/// installed one, done in-process with the Security framework — the same
/// evaluation `codesign --verify --deep --strict -R=<requirement>` performs.
/// The installed app's designated requirement is *evaluated* against the
/// staged bundle, never compared as text: a bundle re-signed with a copied
/// requirement string still fails, because the requirement names the
/// certificate (or, for an ad-hoc build, the code hash) the bundle must
/// actually carry.
public enum CodeSignature {
    public enum Failure: Error, Equatable, LocalizedError {
        case unreadable(String)
        case noDesignatedRequirement
        case invalid(String)
        case doesNotSatisfyRequirement(String)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let what): "The app's code signature could not be read: \(what)."
            case .noDesignatedRequirement: "The installed app has no designated requirement."
            case .invalid(let what): "The downloaded app's signature is not valid: \(what)."
            case .doesNotSatisfyRequirement(let what): "The downloaded app is not signed with the installed app's identity: \(what)."
            }
        }
    }

    /// The designated requirement of the bundle at `url`, as `codesign -d -r-` prints it.
    public static func designatedRequirement(of url: URL) throws -> String {
        try string(of: try requirementObject(of: url))
    }

    /// The designated requirement of the code this process is running — the
    /// identity to trust, taken from the loaded image rather than re-read
    /// from a path on disk that could change underneath the updater.
    public static func designatedRequirementOfRunningCode() throws -> String {
        var code: SecCode?
        var status = SecCodeCopySelf([], &code)
        guard status == errSecSuccess, let code else { throw Failure.unreadable(message(status)) }
        var staticCode: SecStaticCode?
        status = SecCodeCopyStaticCode(code, [], &staticCode)
        guard status == errSecSuccess, let staticCode else { throw Failure.unreadable(message(status)) }
        var requirement: SecRequirement?
        status = SecCodeCopyDesignatedRequirement(staticCode, [], &requirement)
        guard status == errSecSuccess, let requirement else {
            if status == errSecCSUnsigned { throw Failure.noDesignatedRequirement }
            throw Failure.unreadable(message(status))
        }
        return try string(of: requirement)
    }

    private static func string(of requirement: SecRequirement) throws -> String {
        var text: CFString?
        let status = SecRequirementCopyString(requirement, [], &text)
        guard status == errSecSuccess, let text else { throw Failure.unreadable(message(status)) }
        return text as String
    }

    /// Whether the bundle at `url` is validly signed (strict, all
    /// architectures, nested code) *and* satisfies `requirement`, the
    /// installed app's designated requirement.
    public static func verify(_ url: URL, satisfies requirement: String) throws {
        var requirementObject: SecRequirement?
        var status = SecRequirementCreateWithString(requirement as CFString, [], &requirementObject)
        guard status == errSecSuccess, let requirementObject else { throw Failure.unreadable("requirement: \(message(status))") }
        let code = try staticCode(at: url)
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        var error: Unmanaged<CFError>?
        status = SecStaticCodeCheckValidityWithErrors(code, flags, nil, &error)
        guard status == errSecSuccess else { throw Failure.invalid(describe(status, error)) }
        error = nil
        status = SecStaticCodeCheckValidityWithErrors(code, flags, requirementObject, &error)
        guard status == errSecSuccess else { throw Failure.doesNotSatisfyRequirement(describe(status, error)) }
    }

    private static func staticCode(at url: URL) throws -> SecStaticCode {
        var code: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
        guard status == errSecSuccess, let code else { throw Failure.unreadable(message(status)) }
        return code
    }

    private static func requirementObject(of url: URL) throws -> SecRequirement {
        let code = try staticCode(at: url)
        var requirement: SecRequirement?
        let status = SecCodeCopyDesignatedRequirement(code, [], &requirement)
        guard status == errSecSuccess, let requirement else {
            if status == errSecCSUnsigned { throw Failure.noDesignatedRequirement }
            throw Failure.unreadable(message(status))
        }
        return requirement
    }

    private static func describe(_ status: OSStatus, _ error: Unmanaged<CFError>?) -> String {
        if let error = error?.takeRetainedValue() {
            return (error as Error).localizedDescription
        }
        return message(status)
    }

    private static func message(_ status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
    }
}
