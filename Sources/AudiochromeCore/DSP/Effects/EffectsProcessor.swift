import Foundation

/// Post-EQ insert chain. New toys go here, not in `EQProcessor`.
/// Order: saturation → subharmonic → crossfeed → 0 dBFS peak limiter.
/// Parameter updates never allocate on the audio thread.
public final class EffectsProcessor: @unchecked Sendable {
    private let saturation = SaturationProcessor()
    private let subharmonic = SubharmonicProcessor()
    private let crossfeed = CrossfeedProcessor()
    private let limiter = OutputLimiter()

    public init() {}

    public func update(effects: DeviceEffects, sampleRate: Double) {
        limiter.update(sampleRate: sampleRate)
        saturation.update(settings: effects.saturation, sampleRate: sampleRate)
        subharmonic.update(settings: effects.subharmonic, sampleRate: sampleRate)
        crossfeed.update(settings: effects.crossfeed, sampleRate: sampleRate)
    }

    public func clear() {
        saturation.clear()
        subharmonic.clear()
        crossfeed.clear()
        limiter.reset()
    }

    /// Audio-thread only. Call after EQ has already run.
    public func processPlanar(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        frames: Int
    ) {
        saturation.processPlanar(left: left, right: right, frames: frames)
        subharmonic.processPlanar(left: left, right: right, frames: frames)
        crossfeed.processPlanar(left: left, right: right, frames: frames)
        limiter.processPlanar(left: left, right: right, frames: frames)
    }

    /// Audio-thread only. Call after EQ has already run.
    public func processInterleaved(
        _ buffer: UnsafeMutablePointer<Float>,
        frames: Int,
        channels: Int
    ) {
        saturation.processInterleaved(buffer, frames: frames, channels: channels)
        subharmonic.processInterleaved(buffer, frames: frames, channels: channels)
        crossfeed.processInterleaved(buffer, frames: frames, channels: channels)
        limiter.processInterleaved(buffer, frames: frames, channels: channels)
    }

    /// Audio-thread only. Peak limit a single planar channel (no stereo pair).
    public func processMono(_ buffer: UnsafeMutablePointer<Float>, frames: Int) {
        limiter.processMono(buffer, frames: frames)
    }
}
