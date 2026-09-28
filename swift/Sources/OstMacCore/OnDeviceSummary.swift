// OnDeviceSummary.swift — d1-summaries lane: Apple Foundation Models
// thread summaries. Private by construction: no URLSession, no Process,
// zero bytes off-machine. The live path compiles only where the macOS 26
// SDK is present (canImport + @available); anything older, disabled, or
// still downloading fails with a named guidance error — never a cloud
// fallback, never a crash, never a hang.
import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Availability

/// On-device model readiness. `.available` is the only runnable state.
public enum OnDeviceAvailability: Sendable, Equatable {
    case available
    /// macOS < 26 (or an SDK without FoundationModels).
    case unsupportedOS
    /// Non-Apple-Silicon Mac, or a device ineligible for Apple Intelligence.
    case unsupportedDevice
    /// Apple Intelligence switched off in System Settings.
    case disabled
    /// Apple Intelligence on, model download still pending.
    case downloading
}

public enum OnDeviceSummary {
    public static let disabledGuidance =
        "Apple Intelligence is off. Turn it on in System Settings > Apple Intelligence & Siri, wait for the model download to finish, then retry."
    public static let downloadingGuidance =
        "The on-device model is still downloading. Wait for the download to finish in System Settings > Apple Intelligence & Siri, then retry."

    /// Pure status → error mapping (test seam). Nil means runnable.
    public static func error(for status: OnDeviceAvailability) -> CatchUpError? {
        switch status {
        case .available: nil
        case .unsupportedOS, .unsupportedDevice: .onDeviceUnsupported
        case .disabled: .onDeviceUnavailable(disabledGuidance)
        case .downloading: .onDeviceUnavailable(downloadingGuidance)
        }
    }

    /// Live readiness probe. Safe on any macOS: pre-26 returns
    /// `.unsupportedOS` without touching FoundationModels.
    public static func liveAvailability() -> OnDeviceAvailability {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return .available
            case .unavailable(.deviceNotEligible): return .unsupportedDevice
            case .unavailable(.appleIntelligenceNotEnabled): return .disabled
            case .unavailable(.modelNotReady): return .downloading
            @unknown default: return .unsupportedDevice
            }
        } else {
            return .unsupportedOS
        }
        #else
        return .unsupportedOS
        #endif
    }

    /// Live runner: FoundationModels where the SDK + OS allow it, else a
    /// stub that throws `.onDeviceUnsupported` (the transport's
    /// availability gate normally fails first with better guidance).
    public static func liveRunner() -> any OnDeviceRunner {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            return FoundationModelsOnDeviceRunner()
        }
        #endif
        return UnavailableOnDeviceRunner()
    }
}

// MARK: - Runner seam

/// One on-device completion. Live = FoundationModels session; tests and
/// the --show-catchup-ondevice shot hook inject `OnDeviceMockRunner`.
public protocol OnDeviceRunner: Sendable {
    func generate(prompt: String) async throws -> String
}

#if canImport(FoundationModels)
/// Live runner: one `LanguageModelSession` per summarize call ( macOS 26+).
@available(macOS 26, *)
final class FoundationModelsOnDeviceRunner: OnDeviceRunner, @unchecked Sendable {
    func generate(prompt: String) async throws -> String {
        do {
            let session = LanguageModelSession()
            let response = try await session.respond(to: prompt)
            let text = response.content
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CatchUpError.empty
            }
            return text
        } catch let e as CatchUpError {
            throw e
        } catch {
            throw CatchUpError.onDeviceFailed(String(describing: error))
        }
    }
}
#endif

/// Fallback runner for SDKs/OSs without FoundationModels.
struct UnavailableOnDeviceRunner: OnDeviceRunner {
    func generate(prompt _: String) async throws -> String {
        throw CatchUpError.onDeviceUnsupported
    }
}

/// Mock runner for tests and shot hooks. Records every prompt; returns
/// `stub` or throws `failure`.
public final class OnDeviceMockRunner: OnDeviceRunner, @unchecked Sendable {
    public private(set) var calls: [String] = []
    public var stub: String
    public var failure: Error?

    public init(stub: String = "", failure: Error? = nil) {
        self.stub = stub
        self.failure = failure
    }

    public func generate(prompt: String) async throws -> String {
        calls.append(prompt)
        if let failure { throw failure }
        return stub
    }
}

// MARK: - Transport

/// On-device transport: availability gate first (named guidance error,
/// never a fallback), then the injected runner. Sends zero bytes
/// off-machine: no URLSession, no Process anywhere on this path.
public struct OnDeviceCatchUpTransport: CatchUpTransport {
    public let runner: any OnDeviceRunner
    public let availability: @Sendable () -> OnDeviceAvailability

    public init(
        runner: (any OnDeviceRunner)? = nil,
        availability: (@Sendable () -> OnDeviceAvailability)? = nil
    ) {
        self.runner = runner ?? OnDeviceSummary.liveRunner()
        self.availability = availability ?? { OnDeviceSummary.liveAvailability() }
    }

    public func complete(baseURL _: String, apiKey _: String, model _: String, prompt: String) async throws -> String {
        if let err = OnDeviceSummary.error(for: availability()) {
            throw err
        }
        do {
            return try await runner.generate(prompt: prompt)
        } catch let e as CatchUpError {
            throw e
        } catch {
            throw CatchUpError.onDeviceFailed(String(describing: error))
        }
    }
}
