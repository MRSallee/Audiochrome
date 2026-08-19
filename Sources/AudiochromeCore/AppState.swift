import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
public final class AppState: ObservableObject {
    @Published public private(set) var devices: [AudioOutputDevice] = []
    @Published public private(set) var profiles: [ProfileFile] = []
    @Published public var config: AppConfig
    @Published public var expandedDeviceUID: String?
    @Published public private(set) var defaultDeviceUID: String?
    @Published public private(set) var defaultIdentityKey: String?
    @Published public private(set) var engineStatus: AudioEngineStatus = .idle
    @Published public private(set) var engineDiagnostics: AudioEngineDiagnostics = .idle
    @Published public private(set) var profileEditor: ProfileEditorDraft?

    public let profileStore: ProfileStore
    public let configStore: ConfigStore
    public let deviceService: AudioDeviceService
    public let audioEngine: AudioEngine

    private var refreshTimer: Timer?
    private var audioPermissionPollTimer: Timer?
    private var lastObservedAudioPermission: SystemAudioPermission?
    /// Gate engine apply until after launch activation — cold-start taps often fail beforehand.
    private var engineSyncEnabled = false
    /// TCC dialog in flight — don't stack prompts or start a mute tap underneath it.
    private var audioPermissionPromptInFlight = false
    private var didPromptUndeterminedAudioPermission = false
    /// Suppress output-change EQ banners until the launch notification has been considered.
    private var eqStatusNotificationsReady = false
    private var lastEQStatusNotifiedIdentityKey: String?

    /// Invoked before system sheets/panels (e.g. Change Folder) so the menu can dismiss.
    public var onWillPresentModal: (() -> Void)?

    public init(
        profileStore: ProfileStore = ProfileStore(),
        configStore: ConfigStore = ConfigStore(),
        deviceService: AudioDeviceService = AudioDeviceService(),
        audioEngine: AudioEngine = {
            if #available(macOS 14.2, *) {
                return ProcessTapAudioEngine()
            }
            return StubAudioEngine()
        }()
    ) {
        self.profileStore = profileStore
        self.configStore = configStore
        self.deviceService = deviceService
        self.audioEngine = audioEngine
        self.config = configStore.load()
        // While the debug UI is hidden, force shipping audio knobs (drift off, no SR override).
        if !AppConfig.showEQAccuracyDebugSettings {
            let shipping = AudioEngineDebugOptions()
            if self.config.debugAudio != shipping {
                self.config.debugAudio = shipping
                configStore.save(self.config)
            }
        }
        self.audioEngine.debugOptions = self.config.debugAudio
        // System login-item state is authoritative if the user changed it in Settings.
        self.config.openAtLogin = LoginItem.isEnabled

        profileStore.ensureProfilesDirectoryExists()
        refreshAll()
        startObservingDevices()
        startPolling()
        startObservingAppActivation()
    }

    /// Menu-bar accessories often miss a clean didBecomeActive when returning from Settings.
    private func startObservingAppActivation() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            guard app.bundleIdentifier == Bundle.main.bundleIdentifier else { return }
            Task { @MainActor in
                self.handleApplicationDidBecomeActive()
            }
        }
    }

    public func syncOpenAtLoginFromSystem() {
        let enabled = LoginItem.isEnabled
        guard config.openAtLogin != enabled else { return }
        var next = config
        next.openAtLogin = enabled
        config = next
        configStore.save(config)
    }

    public func setOpenAtLogin(_ enabled: Bool) {
        guard LoginItem.setEnabled(enabled) else {
            syncOpenAtLoginFromSystem()
            return
        }
        var next = config
        next.openAtLogin = enabled
        config = next
        configStore.save(config)
    }

    public func setActiveEQReminders(_ enabled: Bool) {
        var next = config
        next.activeEQReminders = enabled
        config = next
        configStore.save(config)
    }

    public func setCustomEQPerDevice(_ enabled: Bool) {
        var next = config
        next.customEQPerDevice = enabled
        if !enabled {
            next = ensureAllAudioKnownOutput(in: next)
            next = seedAllAudioMappingIfNeeded(in: next)
        }
        config = next
        configStore.save(config)
        objectWillChange.send()
        forceEngineResync()
    }

    public func setAnimatedMenuBarIcon(_ enabled: Bool) {
        var next = config
        next.animatedMenuBarIcon = enabled
        config = next
        configStore.save(config)
    }

    /// Restore a previously snapshotted config (Settings Cancel). Re-applies login item and engine as needed.
    public func restoreConfig(_ snapshot: AppConfig) {
        guard snapshot != config else { return }
        let loginChanged = snapshot.openAtLogin != config.openAtLogin
        let pathChanged =
            snapshot.customEQPerDevice != config.customEQPerDevice
            || snapshot.debugAudio != config.debugAudio
        config = snapshot
        configStore.save(config)
        if loginChanged {
            _ = LoginItem.setEnabled(snapshot.openAtLogin)
        }
        audioEngine.debugOptions = snapshot.debugAudio
        if pathChanged {
            forceEngineResync()
        }
        objectWillChange.send()
    }

    /// Persists EQ accuracy debug knobs. Path-affecting changes restart the engine.
    public func setDebugAudio(_ options: AudioEngineDebugOptions) {
        let previous = config.debugAudio
        var next = config
        next.debugAudio = options
        config = next
        configStore.save(config)
        audioEngine.debugOptions = options

        let pathChanged =
            previous.tapDriftCompensation != options.tapDriftCompensation
            || previous.eqSampleRateOverrideHz != options.eqSampleRateOverrideHz
            || previous.holdTapWhenBypassed != options.holdTapWhenBypassed
        if pathChanged {
            audioEngine.stop(reason: .outputChanged)
            forceEngineResync()
        } else {
            publishEngineDiagnostics()
            objectWillChange.send()
        }
    }

    public func refreshEngineDiagnostics() {
        publishEngineDiagnostics()
    }

    /// Identity used for EQ mapping / UI panel for a physical (or virtual) device key.
    public func mappingIdentityKey(for deviceKey: String) -> String {
        config.customEQPerDevice ? deviceKey : AppConfig.allAudioIdentityKey
    }

    public var activeMappingIdentityKey: String? {
        guard let defaultIdentityKey else {
            return config.customEQPerDevice ? nil : AppConfig.allAudioIdentityKey
        }
        return mappingIdentityKey(for: defaultIdentityKey)
    }

    public var allAudioDisplayName: String {
        let trimmed = config.knownOutputs[AppConfig.allAudioIdentityKey]?.displayName?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? AppConfig.allAudioDefaultName : trimmed
    }

    /// Menu row when Custom EQ per device is off.
    public var allAudioDevice: AudioOutputDevice {
        .allAudio(displayName: allAudioDisplayName)
    }

    private func ensureAllAudioKnownOutput(in config: AppConfig) -> AppConfig {
        var next = config
        if next.knownOutputs[AppConfig.allAudioIdentityKey] == nil {
            next.knownOutputs[AppConfig.allAudioIdentityKey] = KnownOutput(
                identityKey: AppConfig.allAudioIdentityKey,
                uid: AppConfig.allAudioIdentityKey,
                name: AppConfig.allAudioDefaultName,
                displayName: nil
            )
        }
        return next
    }

    /// Copy the current default device’s mapping into the shared slot when empty.
    private func seedAllAudioMappingIfNeeded(in config: AppConfig) -> AppConfig {
        var next = config
        let shared = next.mapping(forIdentity: AppConfig.allAudioIdentityKey)
        let sharedEmpty = shared.profileFilename == nil
            && (shared.profilesDirectoryPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
        guard sharedEmpty, let defaultIdentityKey else { return next }
        let source = next.mapping(forIdentity: defaultIdentityKey)
        guard source.profileFilename != nil
            || !(source.profilesDirectoryPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
        else { return next }
        next.setMapping(source, forIdentity: AppConfig.allAudioIdentityKey)
        return next
    }

    /// Call once the app has finished launching (and preferably after `NSApp.activate`).
    public func startEngineAfterLaunch() {
        engineSyncEnabled = true
        EQStatusNotifier.shared.requestAuthorizationIfNeeded()
        // After activation: resolve the real default output and touch every profile
        // folder now so Files & Folders prompts happen at launch, not on first menu click.
        refreshAll()
        warmProfileFolderAccess()

        // Ask for System Audio Recording at launch — don’t wait for the first menu open.
        // (`restoreEngineIfNeeded` only prompts when EQ is already armed.)
        switch SystemAudioPermission.check() {
        case .undetermined:
            promptForAudioPermissionIfNeeded(force: true)
        case .denied:
            noteNeedsAudioPermission()
        case .authorized:
            break
        }

        restoreEngineIfNeeded()
        // Often still idle here — process taps need a beat. Retries below re-notify
        // once `isEQEngaged` is true (deduped so a fast first engage isn’t double-posted).
        notifyActiveEQStatus(reason: .launch)
        eqStatusNotificationsReady = true
        startAudioPermissionPolling()

        // Core Audio process taps are often not ready on the first try.
        let delays: [TimeInterval] = [0.25, 0.8, 1.8, 3.5]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.restoreEngineIfNeeded()
                if self.isEQEngaged {
                    self.notifyActiveEQStatus(reason: .launch)
                }
            }
        }
    }

    /// Force-access default + per-output profile directories (and the active profile file).
    /// macOS Files & Folders TCC often won’t sheet until the app is activated; doing this
    /// here keeps the prompt at launch instead of the first menu-bar click.
    public func warmProfileFolderAccess() {
        profileStore.ensureProfilesDirectoryExists()
        _ = profileStore.listProfiles()

        var folders: Set<String> = [profileStore.profilesDirectory.path]
        for key in config.outputs.keys {
            folders.insert(profilesDirectoryURL(forIdentity: key).path)
        }
        if let defaultIdentityKey {
            folders.insert(profilesDirectoryURL(forIdentity: defaultIdentityKey).path)
        }

        for path in folders {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            _ = profileStore.listProfiles(in: url)
        }

        // Reading the active profile file also triggers access for that directory.
        if let key = activeMappingIdentityKey,
           let filename = config.mapping(forIdentity: key).profileFilename {
            let fileURL = profilesDirectoryURL(forIdentity: key).appendingPathComponent(filename)
            _ = try? Data(contentsOf: fileURL, options: [.mappedIfSafe])
        }
        if !config.customEQPerDevice {
            _ = profilesDirectoryURL(forIdentity: AppConfig.allAudioIdentityKey)
        }
    }

    /// Engage EQ for the current output if config says it should be on but the engine isn't.
    public func restoreEngineIfNeeded() {
        guard engineSyncEnabled else { return }
        refreshAll()
        guard let mapping = activeMapping,
              mapping.enabled,
              mapping.profileFilename != nil
        else { return }
        if case .engaged = engineStatus { return }

        // Don't install a mute tap until authorized. Denied → banner only.
        // Undetermined → TCC Allow dialog (no tap underneath, so audio keeps playing).
        if SystemAudioPermission.check() == .denied {
            noteNeedsAudioPermission()
            return
        }
        if SystemAudioPermission.check() == .undetermined {
            noteNeedsAudioPermission()
            promptForAudioPermissionIfNeeded()
            return
        }
        forceEngineResync()
    }

    public var activeMapping: OutputMapping? {
        guard let key = activeMappingIdentityKey else { return nil }
        return config.mapping(forIdentity: key)
    }

    public var isEQEngaged: Bool {
        // Icon / animation reflect *actual* processing, not just an armed toggle.
        guard case .engaged = engineStatus else { return false }
        guard let mapping = activeMapping else { return false }
        return mapping.enabled && mapping.profileFilename != nil
    }

    public var needsAudioPermission: Bool {
        if case .needsAudioPermission = engineStatus { return true }
        return false
    }

    private func noteNeedsAudioPermission() {
        engineStatus = .needsAudioPermission
        objectWillChange.send()
    }

    public var activeProfileColorHex: String? {
        guard isEQEngaged, let mapping = activeMapping else { return nil }
        return mapping.profileFilename.map { colorHex(forProfile: $0, forIdentity: activeMappingIdentityKey) }
            ?? mapping.colorHex
    }

    public var activeProfileColor: Color {
        guard let hex = activeProfileColorHex else {
            return Color(nsColor: .labelColor)
        }
        return hex.asHexColor
    }

    public func refreshAll() {
        let previousDefaultKey = defaultIdentityKey
        let live = deviceService.outputDevices()
        profileStore.ensureProfilesDirectoryExists()

        if config.outputs.isEmpty && config.knownOutputs.isEmpty {
            config = configStore.load()
        }

        var next = config
        next.purgeInternalDevices()
        next.ensureAirPlayDisplayNames()
        for device in live {
            next.remember(device)
        }
        if let active = deviceService.defaultOutputDevice() {
            next.remember(active)
            defaultDeviceUID = active.uid
            defaultIdentityKey = active.identityKey
        } else {
            defaultDeviceUID = nil
            defaultIdentityKey = nil
        }
        if next != config {
            config = next
            configStore.save(config)
        }

        devices = mergeDevices(live: live, known: config.knownOutputs, defaultUID: defaultDeviceUID)
        profiles = profilesForActiveOutput()

        ensureExpandedDevice()
        if engineSyncEnabled {
            syncEngine()
        }

        if eqStatusNotificationsReady, previousDefaultKey != defaultIdentityKey {
            // Drop the previous output’s banner first; post again only if this one has a profile.
            EQStatusNotifier.shared.clearActiveEQ()
            notifyActiveEQStatus(reason: .outputChanged)
        }
    }

    private enum EQStatusNotifyReason {
        case launch
        case outputChanged
    }

    /// Banner when EQ is actively engaged on the system default output (launch / output switch).
    private func notifyActiveEQStatus(reason: EQStatusNotifyReason) {
        guard config.activeEQReminders else { return }
        // Armed config isn’t enough — only remind when EQ is actually processing.
        guard isEQEngaged else { return }
        guard let hardwareKey = defaultIdentityKey else { return }
        let mappingKey = mappingIdentityKey(for: hardwareKey)
        let mapping = config.mapping(forIdentity: mappingKey)
        guard mapping.enabled, let filename = mapping.profileFilename else {
            lastEQStatusNotifiedIdentityKey = hardwareKey
            return
        }
        // Dedupe on hardware identity (launch retries + output switches in shared mode).
        if hardwareKey == lastEQStatusNotifiedIdentityKey {
            return
        }
        lastEQStatusNotifiedIdentityKey = hardwareKey

        let outputName: String
        if config.customEQPerDevice {
            outputName = devices.first(where: { $0.identityKey == hardwareKey })?.name
                ?? config.knownOutputs[hardwareKey]?.resolvedName
                ?? "Output"
        } else {
            outputName = allAudioDisplayName
        }
        let profileName = profiles(forIdentity: mappingKey).first(where: { $0.filename == filename })?.displayName
            ?? (filename as NSString).deletingPathExtension
        let folderName = profilesDirectoryURL(forIdentity: mappingKey).lastPathComponent

        let profileColorHex = colorHex(forProfile: filename, forIdentity: mappingKey)
        switch reason {
        case .launch:
            // Give notification auth a beat so the first banner isn’t dropped.
            EQStatusNotifier.shared.notifyActiveEQAfterLaunch(
                outputName: outputName,
                profileDisplayName: profileName,
                folderName: folderName,
                colorHex: profileColorHex
            )
        case .outputChanged:
            EQStatusNotifier.shared.notifyActiveEQ(
                outputName: outputName,
                profileDisplayName: profileName,
                folderName: folderName,
                colorHex: profileColorHex
            )
        }
    }

    /// Folder of `.txt` profiles for a given output (`nil` path → Documents/Audiochrome/EQ profiles).
    public func profilesDirectoryURL(forIdentity identityKey: String) -> URL {
        let key = mappingIdentityKey(for: identityKey)
        let path = config.mapping(forIdentity: key).profilesDirectoryPath?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return profileStore.profilesDirectory
    }

    public func profilesForActiveOutput() -> [ProfileFile] {
        guard let key = activeMappingIdentityKey else {
            return profileStore.listProfiles()
        }
        return profiles(forIdentity: key)
    }

    public func profiles(forIdentity identityKey: String) -> [ProfileFile] {
        profileStore.listProfiles(in: profilesDirectoryURL(forIdentity: identityKey))
    }

    public func setProfilesDirectory(forIdentity identityKey: String, url: URL) {
        let key = mappingIdentityKey(for: identityKey)
        var mapping = config.mapping(forIdentity: key)
        mapping.profilesDirectoryPath = url.path

        // Drop the selection only when that profile file isn’t in the new folder.
        if let current = mapping.profileFilename {
            let fileURL = url.appendingPathComponent(current)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                mapping.profileFilename = nil
                mapping.enabled = false
            }
        }

        config.setMapping(mapping, forIdentity: key)
        configStore.save(config)
        refreshAll()
        forceEngineResync()
    }

    /// Inactive outputs stay listed when they have a profile or a custom profiles folder
    /// (so Change Folder doesn’t yank the row if the selection is cleared).
    public func shouldListInactiveOutput(_ identityKey: String) -> Bool {
        guard config.customEQPerDevice else { return false }
        guard identityKey != AppConfig.allAudioIdentityKey else { return false }
        let mapping = config.mapping(forIdentity: identityKey)
        if mapping.profileFilename != nil { return true }
        let path = mapping.profilesDirectoryPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !path.isEmpty
    }

    /// Lets the user pick which folder supplies EQ profiles for this output.
    public func chooseProfilesFolder(forIdentity identityKey: String) {
        let key = mappingIdentityKey(for: identityKey)
        // Status menu is `.popUpMenu` — dismiss it and raise the open panel above that level.
        onWillPresentModal?()

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = openPanelStartURL(for: profilesDirectoryURL(forIdentity: key))
        panel.message = "Choose a folder of EQ profiles for this output"
        panel.prompt = "Choose"
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setProfilesDirectory(forIdentity: key, url: url)
    }

    /// Nested paths under Documents aren't valid picker roots (macOS falls back to home).
    /// Start at Documents itself so the panel lands in a useful place.
    private func openPanelStartURL(for url: URL) -> URL {
        let start = url.resolvingSymlinksInPath().standardizedFileURL
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return start
        }
        let documentsURL = documents.resolvingSymlinksInPath().standardizedFileURL
        if start.path.hasPrefix(documentsURL.path + "/") {
            return documentsURL
        }
        return start
    }

    public func openProfilesFolder() {
        let url: URL
        if let key = activeMappingIdentityKey {
            url = profilesDirectoryURL(forIdentity: key)
        } else {
            profileStore.ensureProfilesDirectoryExists()
            url = profileStore.profilesDirectory
        }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    /// Always keep exactly one device section expanded (accordion).
    public func expandDevice(_ identityKey: String) {
        guard expandedDeviceUID != identityKey else { return }
        withAnimation(.easeInOut(duration: 0.22)) {
            expandedDeviceUID = identityKey
        }
    }

    private func ensureExpandedDevice() {
        if !config.customEQPerDevice {
            expandedDeviceUID = AppConfig.allAudioIdentityKey
            return
        }
        if let expandedDeviceUID,
           devices.contains(where: { $0.identityKey == expandedDeviceUID }) {
            return
        }
        expandedDeviceUID = defaultIdentityKey ?? devices.first?.identityKey
    }

    public func setEnabled(forIdentity identityKey: String, enabled: Bool) {
        let key = mappingIdentityKey(for: identityKey)
        var mapping = config.mapping(forIdentity: key)
        if enabled, mapping.profileFilename == nil {
            return
        }
        mapping.enabled = enabled
        config.setMapping(mapping, forIdentity: key)
        configStore.save(config)
        objectWillChange.send()
        syncEngine()
    }

    /// Toggle EQ for the current default output (used by status-item right-click).
    public func toggleActiveEQ() {
        guard let key = activeMappingIdentityKey else { return }
        let mapping = config.mapping(forIdentity: key)
        if !mapping.enabled, mapping.profileFilename == nil {
            return
        }
        setEnabled(forIdentity: key, enabled: !mapping.enabled)
    }

    public func beginCreateProfile(forIdentity identityKey: String) {
        let key = mappingIdentityKey(for: identityKey)
        let color = colorHex(forProfile: "New Profile.txt", forIdentity: key)
        var draft = ProfileEditorDraft.create(identityKey: key, colorHex: color)
        draft.preampDB = autoPregainDB(for: draft)
        profileEditor = draft
        objectWillChange.send()
        syncEngine()
    }

    public func beginEditProfile(forIdentity identityKey: String, filename: String) {
        let key = mappingIdentityKey(for: identityKey)
        let url = profilesDirectoryURL(forIdentity: key).appendingPathComponent(filename)
        guard let profile = try? ProfileParser.parseFile(at: url) else { return }
        var draft = ProfileEditorDraft.edit(
            identityKey: key,
            filename: filename,
            profile: profile,
            colorHex: colorHex(forProfile: filename, forIdentity: key)
        )
        draft.preampDB = autoPregainDB(for: draft)
        profileEditor = draft
        objectWillChange.send()
        syncEngine()
    }

    public func updateProfileEditor(_ mutate: (inout ProfileEditorDraft) -> Void) {
        guard var draft = profileEditor else { return }
        let previous = draft
        mutate(&draft)
        let bandsChanged = previous.bands != draft.bands || previous.hiddenFilters != draft.hiddenFilters
        if previous.preampDB != draft.preampDB, previous.isAutoPregain {
            draft.isAutoPregain = false
        }
        if draft.isAutoPregain, bandsChanged || !previous.isAutoPregain {
            draft.preampDB = autoPregainDB(for: draft)
        }
        let affectsLiveEQ =
            previous.preampDB != draft.preampDB
            || previous.bands != draft.bands
            || previous.hiddenFilters != draft.hiddenFilters
            || previous.colorHex != draft.colorHex
        if affectsLiveEQ {
            draft.revision += 1
        }
        profileEditor = draft
        objectWillChange.send()
        if affectsLiveEQ {
            syncEngine()
        }
    }

    private func autoPregainDB(for draft: ProfileEditorDraft) -> Double {
        var preview = draft.eqProfile
        preview.linked = ChannelEQ(preampDB: 0, filters: preview.effectiveLeft.filters)
        let curve = EQProcessor.frequencyResponseCurve(
            for: preview,
            sampleRate: predictedCurveSampleRate()
        )
        let raw = -max(0, curve.max() ?? 0)
        return min(12, max(-30, (raw * 10).rounded() / 10))
    }

    public func cancelProfileEditor() {
        guard profileEditor != nil else { return }
        profileEditor = nil
        lastSyncedProfile = nil
        objectWillChange.send()
        syncEngine()
    }

    @discardableResult
    public func saveProfileEditor() -> Bool {
        guard let draft = profileEditor else { return false }
        let key = mappingIdentityKey(for: draft.identityKey)
        let directory = profilesDirectoryURL(forIdentity: key)
        let original = draft.originalFilename.map {
            ProfileFile(filename: $0, url: directory.appendingPathComponent($0))
        }
        do {
            let saved = try profileStore.write(draft.eqProfile, replacing: original, in: directory)
            if let old = draft.originalFilename, old != saved.filename {
                config.profileColors.removeValue(forKey: old)
            }
            setProfileColor(filename: saved.filename, hex: draft.colorHex)
            profileEditor = nil
            lastSyncedProfile = nil
            setProfile(forIdentity: key, filename: saved.filename)
            return true
        } catch {
            return false
        }
    }

    public func setProfile(forIdentity identityKey: String, filename: String?) {
        let key = mappingIdentityKey(for: identityKey)
        var mapping = config.mapping(forIdentity: key)
        mapping.profileFilename = filename
        if let filename {
            mapping.enabled = true
            // Color follows the profile.
            mapping.colorHex = colorHex(forProfile: filename, forIdentity: key)
        } else {
            mapping.enabled = false
        }
        config.setMapping(mapping, forIdentity: key)
        configStore.save(config)
        objectWillChange.send()
        syncEngine()
    }

    /// Copy dropped `.txt` EQ profiles into this output’s folder and activate the first one.
    @discardableResult
    public func importAndActivateProfiles(from urls: [URL], forIdentity identityKey: String) -> Bool {
        let key = mappingIdentityKey(for: identityKey)
        let directory = profilesDirectoryURL(forIdentity: key)
        var importedFilenames: [String] = []

        for url in urls {
            guard ProfileStore.isEQProfileFile(url) else { continue }
            do {
                let profile = try profileStore.importProfile(from: url, into: directory)
                importedFilenames.append(profile.filename)
            } catch {
                continue
            }
        }

        guard let filename = importedFilenames.first else { return false }
        setProfile(forIdentity: key, filename: filename)
        return true
    }

    /// Deletes a profile `.txt` from this output’s folder and clears selections that used it there.
    public func deleteProfile(_ profile: ProfileFile, forIdentity identityKey: String) {
        let key = mappingIdentityKey(for: identityKey)
        let directory = profilesDirectoryURL(forIdentity: key)
        let directoryURL = directory.resolvingSymlinksInPath().standardizedFileURL

        do {
            try profileStore.deleteProfileFile(at: profile.url, under: directory)
        } catch {
            return
        }

        config.profileColors.removeValue(forKey: profile.filename)

        var clearedActiveMapping = false
        for (outputKey, var mapping) in config.outputs {
            guard mapping.profileFilename == profile.filename else { continue }
            let outputDir = profilesDirectoryURL(forIdentity: outputKey)
                .resolvingSymlinksInPath()
                .standardizedFileURL
            guard outputDir == directoryURL else { continue }
            mapping.profileFilename = nil
            mapping.enabled = false
            config.setMapping(mapping, forIdentity: outputKey)
            if outputKey == activeMappingIdentityKey {
                clearedActiveMapping = true
            }
        }

        configStore.save(config)
        objectWillChange.send()
        if clearedActiveMapping {
            syncEngine()
        }
    }

    /// Sets the color mapped to a profile; updates every output currently using it.
    public func setProfileColor(filename: String, hex: String) {
        config.setColorHex(hex, forProfile: filename)
        for (key, var mapping) in config.outputs {
            if mapping.profileFilename == filename {
                mapping.colorHex = hex
                config.setMapping(mapping, forIdentity: key)
            }
        }
        configStore.save(config)
        objectWillChange.send()
    }

    public func setColor(forIdentity identityKey: String, hex: String) {
        let key = mappingIdentityKey(for: identityKey)
        let mapping = config.mapping(forIdentity: key)
        if let filename = mapping.profileFilename {
            setProfileColor(filename: filename, hex: hex)
        } else {
            var next = mapping
            next.colorHex = hex
            config.setMapping(next, forIdentity: key)
            configStore.save(config)
            objectWillChange.send()
        }
    }

    /// Profile color: saved picker value, else palette index by A→Z order in that output’s folder.
    public func colorHex(forProfile filename: String, forIdentity identityKey: String? = nil) -> String {
        let key = identityKey.map { mappingIdentityKey(for: $0) } ?? activeMappingIdentityKey
        let peers = key.map { profiles(forIdentity: $0).map(\.filename) } ?? [filename]
        return config.colorHex(forProfile: filename, among: peers)
    }

    /// Log-spaced EQ magnitude curve (dB) for the active output’s selected profile.
    public func activeEQFrequencyResponse(pointCount: Int = 96) -> EQFrequencyResponsePreview? {
        guard let key = activeMappingIdentityKey else { return nil }
        return eqFrequencyResponse(forIdentity: key, pointCount: pointCount)
    }

    /// Saved/active profile curve for an output. Ignores an open editor draft so the home plot stays put.
    public func eqFrequencyResponse(forIdentity identityKey: String, pointCount: Int = 96) -> EQFrequencyResponsePreview? {
        let key = mappingIdentityKey(for: identityKey)
        let mapping = config.mapping(forIdentity: key)
        guard let filename = mapping.profileFilename else { return nil }
        let url = profilesDirectoryURL(forIdentity: key).appendingPathComponent(filename)
        guard let profile = try? ProfileParser.parseFile(at: url) else { return nil }
        return frequencyResponsePreview(for: profile, pointCount: pointCount)
    }

    /// Editor curve for the in-progress draft (create or edit).
    public func eqFrequencyResponse(for draft: ProfileEditorDraft, pointCount: Int = 96) -> EQFrequencyResponsePreview {
        frequencyResponsePreview(for: draft.eqProfile, pointCount: pointCount)
    }

    private func frequencyResponsePreview(for profile: EQProfile, pointCount: Int) -> EQFrequencyResponsePreview {
        EQFrequencyResponsePreview(
            magnitudesDB: EQProcessor.frequencyResponseCurve(
                for: profile,
                sampleRate: predictedCurveSampleRate(),
                pointCount: pointCount
            ),
            halfRangeDB: profile.waveformHalfRangeDB
        )
    }

    /// Menu curve uses the same design rate as the live EQ when known.
    private func predictedCurveSampleRate() -> Double {
        if let live = audioEngine.diagnostics.eqDesignSampleRateHz, live > 0 {
            return live
        }
        if let override = config.debugAudio.eqSampleRateOverrideHz, override > 0 {
            return override
        }
        return 48_000
    }

    public func setDisplayName(forIdentity identityKey: String, name: String) {
        let key = mappingIdentityKey(for: identityKey)
        if key == AppConfig.allAudioIdentityKey {
            var next = ensureAllAudioKnownOutput(in: config)
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            next.setDisplayName(trimmed.isEmpty ? nil : trimmed, forIdentity: key)
            config = next
            configStore.save(config)
            objectWillChange.send()
            return
        }
        config.setDisplayName(name, forIdentity: key)
        configStore.save(config)
        refreshAll()
    }

    /// Clears custom name, custom profiles folder, and any selected profile for an output.
    public func resetOutput(forIdentity identityKey: String) {
        let key = mappingIdentityKey(for: identityKey)
        var mapping = config.mapping(forIdentity: key)
        mapping.profileFilename = nil
        mapping.enabled = false
        mapping.profilesDirectoryPath = nil
        config.setMapping(mapping, forIdentity: key)
        if key == AppConfig.allAudioIdentityKey {
            var next = ensureAllAudioKnownOutput(in: config)
            next.setDisplayName(nil, forIdentity: key)
            config = next
        } else {
            config.setDisplayName(nil, forIdentity: key)
        }
        configStore.save(config)
        refreshAll()
        syncEngine()
    }

    public func removeDevice(identityKey: String) {
        config.removeOutput(identityKey: identityKey)
        configStore.save(config)
        if expandedDeviceUID == identityKey {
            expandedDeviceUID = nil
        }
        refreshAll()
        syncEngine()
    }

    public func quit() {
        deviceService.stopObserving()
        audioEngine.stop(reason: .appQuit)
        NSApplication.shared.terminate(nil)
    }

    /// macOS often requires a full relaunch after granting Screen & System Audio Recording.
    public func quitAndRelaunch() {
        audioEngine.stop(reason: .appQuit)
        deviceService.stopObserving()

        let bundleURL = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true

        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async {
                NSApplication.shared.terminate(nil)
            }
        }

        // Fallback if openApplication never calls back (should be rare).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            NSApplication.shared.terminate(nil)
        }
    }

    /// Re-attempt EQ after the user may have granted System Audio Recording.
    public func retryAudioEngine() {
        evaluateAudioPermissionChange()
        if case .undetermined = SystemAudioPermission.check() {
            promptForAudioPermissionIfNeeded(force: true)
        }
    }

    /// Call when the app becomes key again (e.g. returning from System Settings).
    public func handleApplicationDidBecomeActive() {
        restoreEngineIfNeeded()
        evaluateAudioPermissionChange()
    }

    public func openAudioPermissionSettings() {
        onWillPresentModal?()
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ListenEvent"
        ]
        for raw in candidates {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    /// Shows the system Allow dialog *without* installing a muted process tap first.
    private func promptForAudioPermissionIfNeeded(force: Bool = false) {
        if audioPermissionPromptInFlight { return }
        if !force, didPromptUndeterminedAudioPermission { return }
        audioPermissionPromptInFlight = true
        didPromptUndeterminedAudioPermission = true
        SystemAudioPermission.request { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                self.audioPermissionPromptInFlight = false
                self.lastObservedAudioPermission = SystemAudioPermission.check()
                if granted {
                    self.forceEngineResync()
                } else {
                    self.noteNeedsAudioPermission()
                }
            }
        }
    }

    /// Watch TCC while running (e.g. system Allow dialog grants).
    private func startAudioPermissionPolling() {
        guard audioPermissionPollTimer == nil else { return }
        lastObservedAudioPermission = SystemAudioPermission.check()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.evaluateAudioPermissionChange()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        audioPermissionPollTimer = timer
    }

    private func evaluateAudioPermissionChange() {
        let current = SystemAudioPermission.check()
        let previous = lastObservedAudioPermission
        lastObservedAudioPermission = current
        guard previous != current else { return }
        applyAudioPermission(current)
    }

    private func applyAudioPermission(_ permission: SystemAudioPermission) {
        switch permission {
        case .authorized:
            forceEngineResync()
        case .denied, .undetermined:
            if case .engaged = audioEngine.status {
                audioEngine.stop(reason: .disabled)
            }
            let armed = activeMapping.map { $0.enabled && $0.profileFilename != nil } ?? false
            if armed {
                noteNeedsAudioPermission()
            } else {
                engineStatus = audioEngine.status
                objectWillChange.send()
            }
        }
    }

    private func forceEngineResync() {
        lastSyncedDefaultUID = nil
        lastSyncedEnabled = nil
        lastSyncedProfile = nil
        syncEngine()
        publishEngineDiagnostics()
        objectWillChange.send()
        // Permission grants / late engages often land here after the launch notify raced.
        if eqStatusNotificationsReady, isEQEngaged {
            notifyActiveEQStatus(reason: .outputChanged)
        }
    }

    private var lastSyncedDefaultUID: String?
    private var lastSyncedEnabled: Bool?
    private var lastSyncedProfile: String?

    private func startPolling() {
        // Profiles folder only — do NOT re-apply the engine on a timer (that caused pops).
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.profiles = self.profilesForActiveOutput()
            }
        }
    }

    private func startObservingDevices() {
        deviceService.startObserving { [weak self] in
            Task { @MainActor in
                self?.refreshAll()
            }
        }
    }

    private func mergeDevices(
        live: [AudioOutputDevice],
        known: [String: KnownOutput],
        defaultUID: String?
    ) -> [AudioOutputDevice] {
        var byKey: [String: AudioOutputDevice] = [:]

        for device in live {
            let record = known[device.identityKey]
            byKey[device.identityKey] = AudioOutputDevice(
                uid: device.uid,
                name: device.name,
                isDefault: device.uid == defaultUID,
                isAvailable: true,
                transport: device.transport,
                displayName: record?.displayName,
                needsFriendlyName: record?.needsFriendlyName ?? (device.name.caseInsensitiveCompare("AirPlay") == .orderedSame)
            )
        }

        for (key, record) in known {
            if byKey[key] != nil { continue }
            if DeviceIdentity.isInternalAudiochromeDevice(uid: record.uid, name: record.name) {
                continue
            }
            byKey[key] = AudioOutputDevice(
                uid: record.uid,
                name: record.name,
                isDefault: record.uid == defaultUID,
                isAvailable: false,
                transport: record.transport,
                displayName: record.displayName,
                needsFriendlyName: record.needsFriendlyName
            )
        }

        return byKey.values.sorted { a, b in
            // Active output first; everything else alphabetical by display name.
            if a.isDefault != b.isDefault { return a.isDefault && !b.isDefault }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    private func publishEngineDiagnostics() {
        engineStatus = audioEngine.status
        engineDiagnostics = audioEngine.diagnostics
    }

    private func syncEngine() {
        audioEngine.debugOptions = config.debugAudio
        guard let defaultIdentityKey,
              let device = devices.first(where: { $0.identityKey == defaultIdentityKey })
                ?? deviceService.defaultOutputDevice()
        else {
            if lastSyncedDefaultUID != nil || lastSyncedEnabled != false {
                audioEngine.stop(reason: .noDefaultDevice)
                lastSyncedDefaultUID = nil
                lastSyncedEnabled = false
                lastSyncedProfile = nil
                publishEngineDiagnostics()
            }
            return
        }

        let mappingKey = mappingIdentityKey(for: defaultIdentityKey)
        let mapping = config.mapping(forIdentity: mappingKey)
        let liveDraft = profileEditor.flatMap { draft -> ProfileEditorDraft? in
            mappingIdentityKey(for: draft.identityKey) == mappingKey ? draft : nil
        }
        guard mapping.enabled || liveDraft != nil, let filename = mapping.profileFilename ?? liveDraft.map({ _ in "editor" }) else {
            let deviceChanged = lastSyncedDefaultUID != nil && lastSyncedDefaultUID != device.uid
            if deviceChanged {
                // Output moved while EQ was off — tear down the old tap.
                audioEngine.stop(reason: .outputChanged)
            } else if lastSyncedEnabled != false {
                // Soft off: fade to passthrough; tap stays warm until audio goes silent.
                audioEngine.bypass()
            }
            if deviceChanged || lastSyncedEnabled != false {
                lastSyncedDefaultUID = device.uid
                lastSyncedEnabled = false
                lastSyncedProfile = nil
                publishEngineDiagnostics()
            }
            return
        }

        // Don't start a muted tap until capture is authorized — creating the tap while
        // TCC is undetermined silences the Mac for the whole Allow/Don't Allow dialog.
        let permission = SystemAudioPermission.check()
        switch permission {
        case .denied:
            if case .engaged = audioEngine.status {
                audioEngine.stop(reason: .disabled)
            }
            lastSyncedDefaultUID = device.uid
            lastSyncedEnabled = true
            lastSyncedProfile = filename
            noteNeedsAudioPermission()
            publishEngineDiagnostics()
            return
        case .undetermined:
            if case .engaged = audioEngine.status {
                audioEngine.stop(reason: .disabled)
            }
            lastSyncedDefaultUID = device.uid
            lastSyncedEnabled = true
            lastSyncedProfile = filename
            noteNeedsAudioPermission()
            promptForAudioPermissionIfNeeded()
            publishEngineDiagnostics()
            return
        case .authorized:
            break
        }

        let syncToken = liveDraft.map { "editor:\($0.revision)" } ?? filename

        // Skip re-apply when nothing meaningful changed (prevents periodic filter resets/pops).
        if lastSyncedEnabled == true,
           lastSyncedDefaultUID == device.uid,
           lastSyncedProfile == syncToken {
            if case .engaged = audioEngine.status {
                // Still verify permission — a Settings revoke can leave us "engaged".
                if SystemAudioPermission.check() != .authorized {
                    audioEngine.stop(reason: .disabled)
                    noteNeedsAudioPermission()
                }
                return
            }
            // Stuck "needs permission" is only sticky while capture is actually not granted.
            // Authorized-but-failed launches must fall through and retry.
            if case .needsAudioPermission = audioEngine.status,
               SystemAudioPermission.check() != .authorized {
                noteNeedsAudioPermission()
                return
            }
            lastSyncedEnabled = nil
            lastSyncedProfile = nil
        }

        let profile: EQProfile
        if let liveDraft {
            profile = liveDraft.eqProfile
        } else {
            let url = profilesDirectoryURL(forIdentity: mappingKey)
                .appendingPathComponent(filename)
            guard let parsed = try? ProfileParser.parseFile(at: url) else {
                audioEngine.stop(reason: .invalidProfile)
                publishEngineDiagnostics()
                return
            }
            profile = parsed
        }

        do {
            try audioEngine.apply(
                profile: profile,
                to: device,
                colorHex: liveDraft?.colorHex ?? mapping.colorHex
            )
            lastSyncedDefaultUID = device.uid
            lastSyncedEnabled = true
            lastSyncedProfile = syncToken
        } catch {
            // apply() already tore down and set status (including needsAudioPermission).
            if case .needsAudioPermission = audioEngine.status {
                // Don't mark sync "complete" — allow launch retries / later refresh to re-apply.
                lastSyncedDefaultUID = device.uid
                lastSyncedEnabled = nil
                lastSyncedProfile = nil
            } else {
                lastSyncedEnabled = nil
                lastSyncedProfile = nil
            }
        }
        publishEngineDiagnostics()
        if case .needsAudioPermission = engineStatus {
            objectWillChange.send()
        }
    }
}
