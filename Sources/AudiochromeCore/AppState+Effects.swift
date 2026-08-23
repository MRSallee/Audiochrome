import Foundation

extension AppState {
    public func effects(forIdentity identityKey: String) -> DeviceEffects {
        config.mapping(forIdentity: mappingIdentityKey(for: identityKey)).effects
    }

    public func setEffectEnabled(
        _ enabled: Bool,
        kind: EffectKind,
        forIdentity identityKey: String
    ) {
        updateEffects(forIdentity: identityKey) { $0.setEnabled(enabled, for: kind) }
    }

    public func updateCrossfeed(
        forIdentity identityKey: String,
        _ mutate: (inout CrossfeedSettings) -> Void
    ) {
        updateEffects(forIdentity: identityKey) { effects in
            mutate(&effects.crossfeed)
            effects.crossfeed.sanitize()
        }
    }

    public func updateSubharmonic(
        forIdentity identityKey: String,
        _ mutate: (inout SubharmonicSettings) -> Void
    ) {
        updateEffects(forIdentity: identityKey) { effects in
            mutate(&effects.subharmonic)
            effects.subharmonic.sanitize()
        }
    }

    public func beginEditEffect(_ kind: EffectKind, forIdentity identityKey: String) {
        let key = mappingIdentityKey(for: identityKey)
        effectsEditorIdentityKey = key
        effectsEditorKind = kind
        effectsEditorBaseline = config.mapping(forIdentity: key).effects
        clearEffectComparing()
        objectWillChange.send()
    }

    public func saveEffectsEditor() {
        dismissEffectsEditor()
    }

    public func cancelEffectsEditor() {
        if let key = effectsEditorIdentityKey, let baseline = effectsEditorBaseline {
            updateEffects(forIdentity: key) { $0 = baseline }
        }
        dismissEffectsEditor()
    }

    public func dismissEffectsEditor() {
        guard effectsEditorIdentityKey != nil || effectsEditorKind != nil else { return }
        effectsEditorIdentityKey = nil
        effectsEditorKind = nil
        effectsEditorBaseline = nil
        if isCrossfeedComparing || isSubharmonicComparing {
            clearEffectComparing()
        } else {
            objectWillChange.send()
        }
    }

    private func updateEffects(
        forIdentity identityKey: String,
        _ mutate: (inout DeviceEffects) -> Void
    ) {
        guard EffectsFeature.isEnabled else { return }
        let key = mappingIdentityKey(for: identityKey)
        var mapping = config.mapping(forIdentity: key)
        mutate(&mapping.effects)
        config.setMapping(mapping, forIdentity: key)
        configStore.save(config)
        objectWillChange.send()
        if key == activeMappingIdentityKey {
            syncEngine()
        }
    }
}
