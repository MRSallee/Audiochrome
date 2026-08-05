import Foundation

public enum AudioEngineStopReason: String, Equatable, Sendable {
    case appQuit
    case disabled
    case noDefaultDevice
    case invalidProfile
    case engineError
    case outputChanged
}

public enum AudioEngineStatus: Equatable, Sendable {
    case idle
    case engaged(deviceName: String, profileName: String)
    /// System Audio Recording denied or missing — EQ cannot run until granted.
    case needsAudioPermission
    case unavailable(String)
}

public enum AudioEngineError: Error, LocalizedError, Equatable {
    case notImplemented
    case permissionDenied
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notImplemented:
            return "Audio engine is stubbed for milestone 1."
        case .permissionDenied:
            return "System audio access is required."
        case .failed(let message):
            return message
        }
    }
}

/// System-wide EQ backend.
public protocol AudioEngine: AnyObject {
    var status: AudioEngineStatus { get }
    /// Smoothed output magnitude 0…1 for UI (menu-bar animation). Audio-thread safe to read.
    var outputLevel: Float { get }
    func apply(profile: EQProfile, to device: AudioOutputDevice, colorHex: String) throws
    func stop(reason: AudioEngineStopReason)
}

/// Placeholder engine that tracks desired state without touching the audio path.
public final class StubAudioEngine: AudioEngine, @unchecked Sendable {
    public private(set) var status: AudioEngineStatus = .idle
    public private(set) var lastProfileName: String?
    public private(set) var lastDeviceUID: String?
    public var outputLevel: Float { 0 }

    public init() {}

    public func apply(profile: EQProfile, to device: AudioOutputDevice, colorHex: String) throws {
        lastProfileName = profile.name
        lastDeviceUID = device.uid
        status = .engaged(deviceName: device.name, profileName: profile.name)
        _ = colorHex
    }

    public func stop(reason: AudioEngineStopReason) {
        lastProfileName = nil
        lastDeviceUID = nil
        switch reason {
        case .appQuit, .disabled, .outputChanged, .noDefaultDevice:
            status = .idle
        case .invalidProfile:
            status = .unavailable("Selected profile is missing or invalid.")
        case .engineError:
            status = .unavailable("Audio engine error.")
        }
    }
}
