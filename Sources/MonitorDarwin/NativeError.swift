import DarwinSupport

/// A failure reported by the C boundary. Errno values and Mach status codes
/// live in different code spaces, so the kind is preserved.
public struct NativeError: Error, Sendable, Equatable, CustomStringConvertible {
    public enum Kind: Sendable, Equatable {
        case errno, mach, shortResult, noMemory, retryExhausted
    }

    public let kind: Kind
    public let code: Int32
    public let operation: String

    init(kind: Kind, code: Int32, operation: String) {
        self.kind = kind
        self.code = code
        self.operation = operation
    }

    init?(_ status: ds_status, operation: String) {
        switch status.kind {
        case DS_OK: return nil
        case DS_ERRNO: kind = .errno
        case DS_MACH: kind = .mach
        case DS_SHORT_RESULT: kind = .shortResult
        case DS_NO_MEMORY: kind = .noMemory
        default: kind = .retryExhausted
        }
        self.code = status.code
        self.operation = operation
    }

    public var description: String {
        "\(operation) failed (\(kind), code \(code))"
    }
}
