import Foundation

/// Post-EQ insert chain. New toys go here, not in `EQProcessor`.
/// Order: subharmonic (adds mono octave-down) → crossfeed (spatial).
/// Parameter updates never allocate on the audio thread.
public final class EffectsProcessor: @unchecked Sendable {
    private let subharmonic = SubharmonicProcessor()
    private let crossfeed = CrossfeedProcessor()

    public init() {}

    public func update(effects: DeviceEffects, sampleRate: Double) {
        if EffectsFeature.isEnabled {
            subharmonic.update(settings: effects.subharmonic, sampleRate: sampleRate)
            crossfeed.update(settings: effects.crossfeed, sampleRate: sampleRate)
        } else {
            subharmonic.clear()
            crossfeed.clear()
        }
    }

    public func clear() {
        subharmonic.clear()
        crossfeed.clear()
    }

    /// Audio-thread only. Call after EQ has already run.
    public func processPlanar(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        frames: Int
    ) {
        guard EffectsFeature.isEnabled else { return }
        subharmonic.processPlanar(left: left, right: right, frames: frames)
        crossfeed.processPlanar(left: left, right: right, frames: frames)
    }

    /// Audio-thread only. Call after EQ has already run.
    public func processInterleaved(
        _ buffer: UnsafeMutablePointer<Float>,
        frames: Int,
        channels: Int
    ) {
        guard EffectsFeature.isEnabled else { return }
        subharmonic.processInterleaved(buffer, frames: frames, channels: channels)
        crossfeed.processInterleaved(buffer, frames: frames, channels: channels)
    }
}
