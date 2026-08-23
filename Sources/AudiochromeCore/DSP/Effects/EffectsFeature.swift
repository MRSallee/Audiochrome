import Foundation

/// Single switch for the experimental device-effects stack (crossfeed first).
///
/// To hide it while playing: set `isEnabled` to `false`.
/// To delete it: remove `DSP/Effects` and `Views/Effects`, then drop the
/// remaining `applyEffects` / `EffectsFeature` call sites (search those names).
/// Persisted `effects` keys in config JSON are ignored once the property is gone.
public enum EffectsFeature {
    public static let isEnabled = true
}
