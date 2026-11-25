import Darwin
import Foundation
import MonitorCore

/// What the controller re-reads about a target immediately before delivery.
public struct ProcessTarget: Sendable, Equatable {
    public var start: ProcessStartTime
    public var uid: UInt32
    public var path: String?

    public init(start: ProcessStartTime, uid: UInt32, path: String?) {
        self.start = start
        self.uid = uid
        self.path = path
    }
}

public protocol ProcessTargetReading: Sendable {
    func read(pid: Int32) -> Result<ProcessTarget, ControlError>
}

public protocol SignalDelivering: Sendable {
    /// nil on success, else the errno captured at the call.
    func deliver(pid: Int32, signal: Int32) -> Int32?
}

public struct LiveProcessTargetReader: ProcessTargetReading {
    public init() {}

    public func read(pid: Int32) -> Result<ProcessTarget, ControlError> {
        do {
            let bsd = try NativeProbe.bsdInfo(pid: pid)
            let path = try? NativeProbe.path(pid: pid)
            return .success(ProcessTarget(
                start: ProcessStartTime(seconds: bsd.startSeconds, microseconds: bsd.startMicroseconds),
                uid: bsd.uid, path: path))
        } catch let error as NativeError where error.kind == .errno {
            switch error.code {
            case ESRCH: return .failure(.processExited)
            default: return .failure(.identityUnavailable) // EPERM etc.: cannot verify
            }
        } catch {
            return .failure(.identityUnavailable)
        }
    }
}

public struct LiveSignalDelivery: SignalDelivering {
    public init() {}
    public func deliver(pid: Int32, signal: Int32) -> Int32? { NativeProbe.sendSignal(pid: pid, signal: signal) }
}

/// Sends one allow-listed signal to one verified process.
///
/// Order of checks: PID validity and protection (no OS access) → start time
/// known → live start time equals the confirmed one → target did not become
/// protected → `kill`. Nothing asynchronous sits between the identity read and
/// the call. The residual race (the process exits and its PID is reused in that
/// microsecond gap) cannot be closed with PID-based `kill`; see
/// `Documentation/Permissions.md`.
public struct ProcessController: ProcessControlling {
    private let ownPID: Int32
    private let reader: any ProcessTargetReading
    private let delivery: any SignalDelivering

    public init(
        ownPID: Int32 = getpid(), reader: any ProcessTargetReading = LiveProcessTargetReader(),
        delivery: any SignalDelivering = LiveSignalDelivery()
    ) {
        self.ownPID = ownPID
        self.reader = reader
        self.delivery = delivery
    }

    public func send(_ request: SignalRequest) -> Result<SignalSent, ControlError> {
        let pid = request.identity.pid
        if let refusal = ProcessControlPolicy.validate(pid: pid, ownPID: ownPID) { return .failure(refusal) }
        guard let confirmed = request.identity.start else { return .failure(.identityUnavailable) }

        let target: ProcessTarget
        switch reader.read(pid: pid) {
        case .failure(let error): return .failure(error)
        case .success(let value): target = value
        }
        guard target.start == confirmed else { return .failure(.identityChanged) }
        if !request.isProtected, CautionPolicy.isCaution(uid: target.uid, path: target.path) {
            return .failure(.cautionChanged) // back to confirmation, as protected
        }

        if let code = delivery.deliver(pid: pid, signal: request.signal.number) {
            switch code {
            case EPERM: return .failure(.permissionDenied)
            case ESRCH: return .failure(.processExited)
            default: return .failure(.osFailure(errno: code))
            }
        }
        return .success(SignalSent(pid: pid, signal: request.signal))
    }
}
