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

    public let profileStore: ProfileStore
    public let configStore: ConfigStore
    public let deviceService: AudioDeviceService
    public let audioEngine: AudioEngine

    private var refreshTimer: Timer?
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

        profileStore.ensureProfilesDirectoryExists()
        refreshAll()
        startObservingDevices()
        startPolling()
    }

    /// Call once the app has finished launching (and preferably after `NSApp.activate`).
    public func startEngineAfterLaunch() {
        engineSyncEnabled = true
        EQStatusNotifier.shared.requestAuthorizationIfNeeded()
        // After activation: resolve the real default output and touch every profile
        // folder now so Files & Folders prompts happen at launch, not on first menu click.
        refreshAll()
        warmProfileFolderAccess()
        restoreEngineIfNeeded()
        notifyActiveEQStatus(reason: .launch)
        eqStatusNotificationsReady = true

        // Core Audio process taps are often not ready on the first try.
        let delays: [TimeInterval] = [0.25, 0.8, 1.8, 3.5]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.restoreEngineIfNeeded()
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
        if let key = defaultIdentityKey,
           let filename = config.mapping(forIdentity: key).profileFilename {
            let fileURL = profilesDirectoryURL(forIdentity: key).appendingPathComponent(filename)
            _ = try? Data(contentsOf: fileURL, options: [.mappedIfSafe])
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
            engineStatus = .needsAudioPermission
            objectWillChange.send()
            return
        }
        if SystemAudioPermission.check() == .undetermined {
            engineStatus = .needsAudioPermission
            objectWillChange.send()
            promptForAudioPermissionIfNeeded()
            return
        }
        forceEngineResync()
    }

    public var activeMapping: OutputMapping? {
        guard let defaultIdentityKey else { return nil }
        return config.mapping(forIdentity: defaultIdentityKey)
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

    public var activeProfileColor: Color {
        guard isEQEngaged, let mapping = activeMapping else {
            return Color(nsColor: .labelColor)
        }
        let hex = mapping.profileFilename.map { colorHex(forProfile: $0) } ?? mapping.colorHex
        return Color(hex: hex) ?? .accentColor
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
        guard let key = defaultIdentityKey else { return }
        let mapping = config.mapping(forIdentity: key)
        // Remind only when EQ is on — profile selected and enabled.
        guard mapping.enabled, let filename = mapping.profileFilename else {
            lastEQStatusNotifiedIdentityKey = key
            return
        }
        if reason == .outputChanged, key == lastEQStatusNotifiedIdentityKey {
            return
        }
        lastEQStatusNotifiedIdentityKey = key

        let outputName = devices.first(where: { $0.identityKey == key })?.name
            ?? config.knownOutputs[key]?.displayName
            ?? "Output"
        let profileName = profiles.first(where: { $0.filename == filename })?.displayName
            ?? (filename as NSString).deletingPathExtension
        let folderName = profilesDirectoryURL(forIdentity: key).lastPathComponent

        let colorHex = config.colorHex(forProfile: filename)
        switch reason {
        case .launch:
            // Give notification auth a beat so the first banner isn’t dropped.
            EQStatusNotifier.shared.notifyActiveEQAfterLaunch(
                outputName: outputName,
                profileDisplayName: profileName,
                folderName: folderName,
                colorHex: colorHex
            )
        case .outputChanged:
            EQStatusNotifier.shared.notifyActiveEQ(
                outputName: outputName,
                profileDisplayName: profileName,
                folderName: folderName,
                colorHex: colorHex
            )
        }
    }

    /// Folder of `.txt` profiles for a given output (`nil` path → default App Support folder).
    public func profilesDirectoryURL(forIdentity identityKey: String) -> URL {
        let path = config.mapping(forIdentity: identityKey).profilesDirectoryPath?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return profileStore.profilesDirectory
    }

    public func profilesForActiveOutput() -> [ProfileFile] {
        guard let defaultIdentityKey else {
            return profileStore.listProfiles()
        }
        return profiles(forIdentity: defaultIdentityKey)
    }

    public func profiles(forIdentity identityKey: String) -> [ProfileFile] {
        profileStore.listProfiles(in: profilesDirectoryURL(forIdentity: identityKey))
    }

    public func setProfilesDirectory(forIdentity identityKey: String, url: URL) {
        var mapping = config.mapping(forIdentity: identityKey)
        mapping.profilesDirectoryPath = url.path

        // Drop the selection only when that profile file isn’t in the new folder.
        if let current = mapping.profileFilename {
            let fileURL = url.appendingPathComponent(current)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                mapping.profileFilename = nil
                mapping.enabled = false
            }
        }

        config.setMapping(mapping, forIdentity: identityKey)
        configStore.save(config)
        refreshAll()
        forceEngineResync()
    }

    /// Inactive outputs stay listed when they have a profile or a custom profiles folder
    /// (so Change Folder doesn’t yank the row if the selection is cleared).
    public func shouldListInactiveOutput(_ identityKey: String) -> Bool {
        let mapping = config.mapping(forIdentity: identityKey)
        if mapping.profileFilename != nil { return true }
        let path = mapping.profilesDirectoryPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !path.isEmpty
    }

    /// Lets the user pick which folder supplies EQ profiles for this output.
    public func chooseProfilesFolder(forIdentity identityKey: String) {
        // Status menu is `.popUpMenu` — dismiss it and raise the open panel above that level.
        onWillPresentModal?()

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = profilesDirectoryURL(forIdentity: identityKey)
        panel.message = "Choose a folder of EQ profiles for this output"
        panel.prompt = "Choose"
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setProfilesDirectory(forIdentity: identityKey, url: url)
    }

    public func openProfilesFolder() {
        let url: URL
        if let defaultIdentityKey {
            url = profilesDirectoryURL(forIdentity: defaultIdentityKey)
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
        if let expandedDeviceUID,
           devices.contains(where: { $0.identityKey == expandedDeviceUID }) {
            return
        }
        expandedDeviceUID = defaultIdentityKey ?? devices.first?.identityKey
    }

    public func setEnabled(forIdentity identityKey: String, enabled: Bool) {
        var mapping = config.mapping(forIdentity: identityKey)
        if enabled, mapping.profileFilename == nil {
            return
        }
        mapping.enabled = enabled
        config.setMapping(mapping, forIdentity: identityKey)
        configStore.save(config)
        objectWillChange.send()
        syncEngine()
    }

    /// Toggle EQ for the current default output (used by status-item right-click).
    public func toggleActiveEQ() {
        guard let identityKey = defaultIdentityKey else { return }
        let mapping = config.mapping(forIdentity: identityKey)
        if !mapping.enabled, mapping.profileFilename == nil {
            return
        }
        setEnabled(forIdentity: identityKey, enabled: !mapping.enabled)
    }

    public func setProfile(forIdentity identityKey: String, filename: String?) {
        var mapping = config.mapping(forIdentity: identityKey)
        mapping.profileFilename = filename
        if let filename {
            mapping.enabled = true
            // Color follows the profile.
            mapping.colorHex = config.colorHex(forProfile: filename)
        } else {
            mapping.enabled = false
        }
        config.setMapping(mapping, forIdentity: identityKey)
        configStore.save(config)
        objectWillChange.send()
        syncEngine()
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
        let mapping = config.mapping(forIdentity: identityKey)
        if let filename = mapping.profileFilename {
            setProfileColor(filename: filename, hex: hex)
        } else {
            var next = mapping
            next.colorHex = hex
            config.setMapping(next, forIdentity: identityKey)
            configStore.save(config)
            objectWillChange.send()
        }
    }

    public func colorHex(forProfile filename: String) -> String {
        config.colorHex(forProfile: filename)
    }

    /// Log-spaced EQ magnitude curve (dB) for the active output’s selected profile.
    public func activeEQFrequencyResponse(pointCount: Int = 96) -> [Double]? {
        guard let key = defaultIdentityKey else { return nil }
        return eqFrequencyResponse(forIdentity: key, pointCount: pointCount)
    }

    /// Log-spaced EQ magnitude curve (dB) for any output’s selected profile.
    public func eqFrequencyResponse(forIdentity identityKey: String, pointCount: Int = 96) -> [Double]? {
        let mapping = config.mapping(forIdentity: identityKey)
        guard let filename = mapping.profileFilename else { return nil }
        let url = profilesDirectoryURL(forIdentity: identityKey).appendingPathComponent(filename)
        guard let profile = try? ProfileParser.parseFile(at: url) else { return nil }
        return EQProcessor.frequencyResponseCurve(for: profile, pointCount: pointCount)
    }

    public func setDisplayName(forIdentity identityKey: String, name: String) {
        config.setDisplayName(name, forIdentity: identityKey)
        configStore.save(config)
        refreshAll()
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
        switch SystemAudioPermission.check() {
        case .authorized:
            forceEngineResync()
        case .undetermined, .denied:
            promptForAudioPermissionIfNeeded(force: true)
        }
    }

    public func openAudioPermissionSettings() {
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
                if granted {
                    self.forceEngineResync()
                } else {
                    self.engineStatus = .needsAudioPermission
                    self.objectWillChange.send()
                }
            }
        }
    }

    private func forceEngineResync() {
        lastSyncedDefaultUID = nil
        lastSyncedEnabled = nil
        lastSyncedProfile = nil
        syncEngine()
        objectWillChange.send()
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

    private func syncEngine() {
        guard let defaultIdentityKey,
              let device = devices.first(where: { $0.identityKey == defaultIdentityKey })
                ?? deviceService.defaultOutputDevice()
        else {
            if lastSyncedDefaultUID != nil || lastSyncedEnabled != false {
                audioEngine.stop(reason: .noDefaultDevice)
                lastSyncedDefaultUID = nil
                lastSyncedEnabled = false
                lastSyncedProfile = nil
                engineStatus = audioEngine.status
            }
            return
        }

        let mapping = config.mapping(forIdentity: defaultIdentityKey)
        guard mapping.enabled, let filename = mapping.profileFilename else {
            if lastSyncedEnabled != false || lastSyncedDefaultUID != device.uid {
                audioEngine.stop(reason: .disabled)
                lastSyncedDefaultUID = device.uid
                lastSyncedEnabled = false
                lastSyncedProfile = nil
                engineStatus = audioEngine.status
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
            engineStatus = .needsAudioPermission
            return
        case .undetermined:
            if case .engaged = audioEngine.status {
                audioEngine.stop(reason: .disabled)
            }
            lastSyncedDefaultUID = device.uid
            lastSyncedEnabled = true
            lastSyncedProfile = filename
            engineStatus = .needsAudioPermission
            promptForAudioPermissionIfNeeded()
            return
        case .authorized:
            break
        }

        // Skip re-apply when nothing meaningful changed (prevents periodic filter resets/pops).
        if lastSyncedEnabled == true,
           lastSyncedDefaultUID == device.uid,
           lastSyncedProfile == filename {
            if case .engaged = audioEngine.status {
                return
            }
            // Stuck "needs permission" is only sticky while capture is actually not granted.
            // Authorized-but-failed launches must fall through and retry.
            if case .needsAudioPermission = audioEngine.status,
               SystemAudioPermission.check() != .authorized {
                engineStatus = .needsAudioPermission
                return
            }
            lastSyncedEnabled = nil
            lastSyncedProfile = nil
        }

        let url = profilesDirectoryURL(forIdentity: defaultIdentityKey)
            .appendingPathComponent(filename)
        guard let profile = try? ProfileParser.parseFile(at: url) else {
            audioEngine.stop(reason: .invalidProfile)
            engineStatus = audioEngine.status
            return
        }

        do {
            try audioEngine.apply(
                profile: profile,
                to: device,
                colorHex: mapping.colorHex
            )
            lastSyncedDefaultUID = device.uid
            lastSyncedEnabled = true
            lastSyncedProfile = filename
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
        engineStatus = audioEngine.status
    }
}
