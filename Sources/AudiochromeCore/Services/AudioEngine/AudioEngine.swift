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
    /// 12-band FFT envelope (20 Hz … 20 kHz), 0…1. Audio-thread safe to read.
    var spectrumLevels: [Float] { get }
    /// Accuracy A/B knobs; applied on the next start/restart.
    var debugOptions: AudioEngineDebugOptions { get set }
    /// Live sample-rate / knob snapshot (idle when not running).
    var diagnostics: AudioEngineDiagnostics { get }
    func apply(profile: EQProfile, to device: AudioOutputDevice, colorHex: String) throws
    func stop(reason: AudioEngineStopReason)
    /// Fade EQ to passthrough while keeping the capture path alive (avoids reconnect pops).
    /// Implementations may fully release later once audio has been silent.
    func bypass()
}

/// Placeholder engine that tracks desired state without touching the audio path.
public final class StubAudioEngine: AudioEngine, @unchecked Sendable {
    public private(set) var status: AudioEngineStatus = .idle
    public private(set) var lastProfileName: String?
    public private(set) var lastDeviceUID: String?
    public var outputLevel: Float { 0 }
    public var spectrumLevels: [Float] { Array(repeating: 0, count: MenuBarSpectrum.bandCount) }
    public var debugOptions = AudioEngineDebugOptions()
    public var diagnostics: AudioEngineDiagnostics { .idle }

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

    public func bypass() {
        lastProfileName = nil
        status = .idle
    }
}
