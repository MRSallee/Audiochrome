import CoreGraphics
import Darwin
import Foundation

/// System Audio Recording (`kTCCServiceAudioCapture`) — distinct from Screen Recording.
/// Uses TCC SPI when available (same approach as Apple's AudioCap sample). There is no
/// public preflight API for process-tap audio capture.
public enum SystemAudioPermission: Equatable, Sendable {
    case authorized
    case denied
    case undetermined

    /// Non-prompting check.
    public static func check() -> SystemAudioPermission {
        if let preflight = TCC.preflight {
            switch preflight(TCC.audioCaptureService, nil) {
            case 0: return .authorized
            case 1: return .denied
            default: return .undetermined
            }
        }
        // Weak proxy only — shared Settings pane, different TCC service.
        return CGPreflightScreenCaptureAccess() ? .authorized : .denied
    }

    /// May show the system permission prompt. Safe to call from the main thread.
    public static func request(completion: @escaping @Sendable (Bool) -> Void) {
        if let request = TCC.request {
            request(TCC.audioCaptureService, nil) { granted in
                completion(granted)
            }
            return
        }
        // Triggers Screen Recording prompt as a last-resort proxy on older/locked-down builds.
        DispatchQueue.main.async {
            completion(CGRequestScreenCaptureAccess())
        }
    }
}

// MARK: - TCC SPI

private enum TCC {
    static let audioCaptureService = "kTCCServiceAudioCapture" as CFString

    typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int
    typealias RequestFn = @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void

    private static let handle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
    }()

    static let preflight: PreflightFn? = {
        guard let handle, let sym = dlsym(handle, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(sym, to: PreflightFn.self)
    }()

    static let request: RequestFn? = {
        guard let handle, let sym = dlsym(handle, "TCCAccessRequest") else { return nil }
        return unsafeBitCast(sym, to: RequestFn.self)
    }()
}
