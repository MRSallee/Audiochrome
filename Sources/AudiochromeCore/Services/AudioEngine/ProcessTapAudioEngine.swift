import CoreAudio
import Foundation
import Darwin

/// System-wide EQ via Core Audio process tap (macOS 14.2+).
/// Tap (muted when read) → EQ → replay through a private aggregate with the current output.
@available(macOS 14.2, *)
public final class ProcessTapAudioEngine: AudioEngine, @unchecked Sendable {
    public private(set) var status: AudioEngineStatus = .idle
    public var debugOptions = AudioEngineDebugOptions()

    private let processor = EQProcessor()
    private let stateLock = NSLock()
    private let meterLock = NSLock()
    private var meterLevel: Float = 0

    private var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID: AudioDeviceID = AudioDeviceID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var currentDeviceUID: String?
    private var currentProfileName: String?
    private var sampleRate: Double = 48_000
    private var appliedDebugOptions: AudioEngineDebugOptions?
    private var lastDeviceSampleRate: Double?
    private var lastAggregateSampleRate: Double?
    private var lastTapSampleRate: Double?

    public var diagnostics: AudioEngineDiagnostics {
        stateLock.lock()
        defer { stateLock.unlock() }
        let running = aggregateID != AudioDeviceID(kAudioObjectUnknown)
        guard running else { return .idle }
        return AudioEngineDiagnostics(
            isRunning: true,
            deviceSampleRateHz: lastDeviceSampleRate,
            aggregateSampleRateHz: lastAggregateSampleRate,
            tapSampleRateHz: lastTapSampleRate,
            eqDesignSampleRateHz: sampleRate,
            tapDriftCompensation: appliedDebugOptions?.tapDriftCompensation,
            holdTapWhenBypassed: appliedDebugOptions?.holdTapWhenBypassed
        )
    }

    /// Warm bypass (EQ off, tap still up): release after sustained digital silence.
    private let silenceLock = NSLock()
    private var warmBypassActive = false
    private var bypassSilentFrames = 0
    private var silenceTeardownWorkItem: DispatchWorkItem?
    /// ~-60 dBFS; below this counts as “not playing” for warm-bypass release.
    private static let silencePeakThreshold: Float = 0.001
    private static let silenceReleaseSeconds: Double = 1.0

    public init() {}

    /// Smoothed peak of the *pre-EQ* tap (0…1). Safe to read from the main thread.
    /// Driven from the incoming signal so auto-pregain / big boosts don’t freeze the menu-bar blob.
    public var outputLevel: Float {
        meterLock.lock()
        defer { meterLock.unlock() }
        return meterLevel
    }

    deinit {
        stop(reason: .appQuit)
    }

    public func apply(profile: EQProfile, to device: AudioOutputDevice, colorHex: String) throws {
        _ = colorHex
        stateLock.lock()
        defer { stateLock.unlock() }

        clearWarmBypassTrackingUnlocked()

        // Same device + engine running + same debug knobs: only publish a new curve.
        // (Avoids resetting biquad state every UI poll — that caused periodic pops.)
        // Debug option changes require a full tap/aggregate rebuild.
        if aggregateID != kAudioObjectUnknown,
           currentDeviceUID == device.uid,
           appliedDebugOptions == debugOptions {
            processor.update(profile: profile, sampleRate: sampleRate)
            currentProfileName = profile.name
            status = .engaged(deviceName: device.name, profileName: profile.name)
            return
        }

        teardownUnlocked(reason: .outputChanged)

        do {
            try startUnlocked(profile: profile, device: device)
            currentDeviceUID = device.uid
            currentProfileName = profile.name
            status = .engaged(deviceName: device.name, profileName: profile.name)
        } catch {
            teardownUnlocked(reason: .engineError)
            if let engineError = error as? AudioEngineError, engineError == .permissionDenied {
                status = .needsAudioPermission
            } else {
                status = .unavailable((error as? LocalizedError)?.errorDescription ?? "Failed to start EQ.")
            }
            throw error
        }
    }

    public func stop(reason: AudioEngineStopReason) {
        stateLock.lock()
        teardownUnlocked(reason: reason)
        switch reason {
        case .appQuit, .disabled, .outputChanged, .noDefaultDevice:
            status = .idle
        case .invalidProfile:
            status = .unavailable("Selected profile is missing or invalid.")
        case .engineError:
            // Keep a more specific status if we already classified permission denial.
            if status != .needsAudioPermission {
                status = .unavailable("Audio engine error.")
            }
        }
        stateLock.unlock()
    }

    /// Soft EQ off: crossfade to unity and keep the tap/aggregate alive.
    /// Fully releases once output stays silent for a couple of seconds (see silence tracking).
    /// Immediate teardown still happens on quit, output change, or permission loss (`stop`).
    public func bypass() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard aggregateID != kAudioObjectUnknown else {
            status = .idle
            currentProfileName = nil
            clearWarmBypassTrackingUnlocked()
            return
        }
        processor.clear()
        currentProfileName = nil
        status = .idle
        silenceLock.lock()
        warmBypassActive = true
        bypassSilentFrames = 0
        silenceTeardownWorkItem?.cancel()
        silenceTeardownWorkItem = nil
        silenceLock.unlock()
    }

    private func clearWarmBypassTrackingUnlocked() {
        silenceLock.lock()
        warmBypassActive = false
        bypassSilentFrames = 0
        silenceTeardownWorkItem?.cancel()
        silenceTeardownWorkItem = nil
        silenceLock.unlock()
    }

    // MARK: - Start / stop

    private func startUnlocked(profile: EQProfile, device: AudioOutputDevice) throws {
        // Never install a muted tap until capture is authorized. Creating the tap (or
        // AudioDeviceStart) while TCC is undetermined shows the Allow dialog *after*
        // mute is already live — system audio goes silent until the user answers.
        switch SystemAudioPermission.check() {
        case .authorized:
            break
        case .denied, .undetermined:
            throw AudioEngineError.permissionDenied
        }

        guard let outputDeviceID = deviceID(forUID: device.uid) ?? defaultOutputDeviceID() else {
            throw AudioEngineError.failed("Could not find output device.")
        }
        guard let outputUID = uidString(for: outputDeviceID) else {
            throw AudioEngineError.failed("Could not read output device UID.")
        }

        // Exclude our own process from the tap. If we don't, our EQ'd playback is re-captured
        // and re-EQ'd (feedback) — sounds drastically wrong.
        var exclude: [AudioObjectID] = []
        if let selfProcess = selfProcessObjectID() {
            exclude.append(selfProcess)
        }

        // Device-scoped stereo tap: mute only what was going to this output, keep stream format.
        // Global mixdown can phase-sum channels and thin out bass vs SoundSource's path.
        let excludeNumbers = exclude.map { NSNumber(value: $0) }
        let description = CATapDescription(
            __excludingProcesses: excludeNumbers,
            andDeviceUID: outputUID,
            withStream: 0
        )
        description.name = "Audiochrome"
        description.isPrivate = true
        description.isExclusive = true
        description.muteBehavior = CATapMuteBehavior.muted
        if #available(macOS 26.0, *) {
            let bid = Bundle.main.bundleIdentifier ?? "app.audiochrome.Audiochrome"
            description.bundleIDs = [bid]
            description.isProcessRestoreEnabled = true
        }
        let tapUUID = description.uuid.uuidString

        var tap: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &tap)
        guard tapStatus == noErr, tap != kAudioObjectUnknown else {
            // Tap creation can fail transiently at cold launch even when TCC is granted.
            // Only classify as permission denial when preflight agrees.
            switch SystemAudioPermission.check() {
            case .denied, .undetermined:
                throw AudioEngineError.permissionDenied
            case .authorized:
                throw AudioEngineError.failed("Could not create process tap (status \(tapStatus)).")
            }
        }
        tapID = tap

        // IOProc runs at the aggregate/output clock — design filters for that rate, not the tap's.
        let deviceRate = nominalSampleRate(for: outputDeviceID)
        let tapRate = tapSampleRate(for: tap)
        lastDeviceSampleRate = deviceRate
        lastTapSampleRate = tapRate
        let nominal = deviceRate ?? tapRate ?? sampleRate
        sampleRate = designSampleRate(nominal: nominal)
        processor.update(profile: profile, sampleRate: sampleRate)
        appliedDebugOptions = debugOptions

        let aggregateUID = "app.audiochrome.aggregate.\(tapUUID)"
        let aggregateDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Audiochrome",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUUID,
                    // Without drift compensation Core Audio constantly resamples tap↔device clocks.
                    kAudioSubTapDriftCompensationKey: debugOptions.tapDriftCompensation
                ]
            ],
            kAudioAggregateDeviceTapAutoStartKey: true
        ]

        var aggregate: AudioDeviceID = AudioDeviceID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(aggregateDesc as CFDictionary, &aggregate)
        guard aggStatus == noErr, aggregate != kAudioObjectUnknown else {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
            if Self.isPermissionStatus(aggStatus) {
                throw AudioEngineError.permissionDenied
            }
            throw AudioEngineError.failed("Could not create aggregate device (status \(aggStatus)).")
        }
        aggregateID = aggregate

        let context = Unmanaged.passUnretained(self).toOpaque()
        var procID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcID(aggregate, ProcessTapAudioEngine.ioProc, context, &procID)
        guard procStatus == noErr, let procID else {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioDeviceID(kAudioObjectUnknown)
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
            throw AudioEngineError.failed("Could not create IO proc (status \(procStatus)).")
        }
        ioProcID = procID

        let startStatus = AudioDeviceStart(aggregateID, procID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            ioProcID = nil
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioDeviceID(kAudioObjectUnknown)
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
            // AudioDeviceStart is what triggers the TCC prompt; denial often lands here.
            if Self.isPermissionStatus(startStatus) {
                throw AudioEngineError.permissionDenied
            }
            throw AudioEngineError.failed("Could not start audio device (status \(startStatus)).")
        }

        refreshTapExclusion(description)

        if let aggRate = nominalSampleRate(for: aggregateID) {
            lastAggregateSampleRate = aggRate
            let designRate = designSampleRate(nominal: aggRate)
            if abs(designRate - sampleRate) > 0.5 {
                sampleRate = designRate
                processor.update(profile: profile, sampleRate: sampleRate)
            }
        } else {
            lastAggregateSampleRate = nil
        }

        NSLog(
            "Audiochrome EQ debug: device=%.0f agg=%@ tap=%@ design=%.0f drift=%@ holdBypass=%@",
            lastDeviceSampleRate ?? -1,
            lastAggregateSampleRate.map { String(format: "%.0f", $0) } ?? "nil",
            lastTapSampleRate.map { String(format: "%.0f", $0) } ?? "nil",
            sampleRate,
            debugOptions.tapDriftCompensation ? "on" : "off",
            debugOptions.holdTapWhenBypassed ? "on" : "off"
        )
    }

    private func designSampleRate(nominal: Double) -> Double {
        if let override = debugOptions.eqSampleRateOverrideHz, override > 0 {
            return override
        }
        return max(nominal, 1)
    }

    private func refreshTapExclusion(_ description: CATapDescription) {
        var exclude: [AudioObjectID] = description.processes
        if let selfProcess = selfProcessObjectID(), !exclude.contains(selfProcess) {
            exclude.append(selfProcess)
        }
        description.processes = exclude
        if #available(macOS 26.0, *) {
            let bid = Bundle.main.bundleIdentifier ?? "app.audiochrome.Audiochrome"
            description.bundleIDs = [bid]
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyDescription,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var descRef: Unmanaged<CATapDescription>? = Unmanaged.passUnretained(description)
        let size = UInt32(MemoryLayout<Unmanaged<CATapDescription>?>.size)
        _ = withUnsafeMutablePointer(to: &descRef) { ptr in
            AudioObjectSetPropertyData(tapID, &address, 0, nil, size, ptr)
        }
    }

    private func tapSampleRate(for tapID: AudioObjectID) -> Double? {
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr, asbd.mSampleRate > 0 else { return nil }
        return asbd.mSampleRate
    }

    private func teardownUnlocked(reason: AudioEngineStopReason) {
        _ = reason
        clearWarmBypassTrackingUnlocked()

        if let procID = ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        ioProcID = nil

        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioDeviceID(kAudioObjectUnknown)
        }

        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }

        processor.clear()
        currentDeviceUID = nil
        currentProfileName = nil
        appliedDebugOptions = nil
        lastDeviceSampleRate = nil
        lastAggregateSampleRate = nil
        lastTapSampleRate = nil
        meterLock.lock()
        meterLevel = 0
        meterLock.unlock()
    }

    // MARK: - IOProc

    private static let ioProc: AudioDeviceIOProc = { _, _, inInputData, _, outOutputData, _, clientData in
        guard let clientData else { return noErr }
        let engine = Unmanaged<ProcessTapAudioEngine>.fromOpaque(clientData).takeUnretainedValue()

        let outBuffers = UnsafeMutableAudioBufferListPointer(outOutputData)
        let inBuffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inInputData)
        )

        // Copy tap → output first.
        for (index, outBuffer) in outBuffers.enumerated() {
            guard let outPtr = outBuffer.mData else { continue }
            if index < inBuffers.count, let inPtr = inBuffers[index].mData {
                let copyBytes = min(outBuffer.mDataByteSize, inBuffers[index].mDataByteSize)
                memcpy(outPtr, inPtr, Int(copyBytes))
                if copyBytes < outBuffer.mDataByteSize {
                    memset(outPtr.advanced(by: Int(copyBytes)), 0, Int(outBuffer.mDataByteSize - copyBytes))
                }
            } else {
                memset(outPtr, 0, Int(outBuffer.mDataByteSize))
            }
        }

        // Icon animation follows the incoming mix, not the EQ'd output — otherwise
        // auto-pregain on a big boost (Giga Bass, etc.) drops the peak below the blob's floor.
        engine.updateMeter(from: outBuffers)

        // Planar (one buffer per channel, common for aggregates) vs interleaved.
        let planar = outBuffers.count > 1 && outBuffers.allSatisfy { $0.mNumberChannels <= 1 }
        if planar {
            engine.processor.beginRender()
            var renderedFrames: UInt32 = 0
            for (index, outBuffer) in outBuffers.enumerated() {
                guard let outPtr = outBuffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let frames = outBuffer.mDataByteSize / UInt32(MemoryLayout<Float>.size)
                let channel: EQProcessor.Channel = (index == 1) ? .right : .left
                engine.processor.processMono(outPtr, frames: frames, channel: channel)
                if index == 0 { renderedFrames = frames }
            }
            engine.processor.endRender(frames: renderedFrames)
        } else {
            for outBuffer in outBuffers {
                guard let outPtr = outBuffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let channels = max(outBuffer.mNumberChannels, 1)
                let frames = outBuffer.mDataByteSize / UInt32(MemoryLayout<Float>.size) / channels
                engine.processor.processInterleaved(outPtr, frames: frames, channels: channels)
            }
        }

        let post = engine.peak(from: outBuffers)
        engine.notePeakForWarmBypassRelease(post.peak, frames: post.frames)
        return noErr
    }

    private func peak(from buffers: UnsafeMutableAudioBufferListPointer) -> (peak: Float, frames: Int) {
        var peak: Float = 0
        var frameHint = 0
        for buffer in buffers {
            guard let ptr = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let count = Int(buffer.mDataByteSize / UInt32(MemoryLayout<Float>.size))
            let channels = max(Int(buffer.mNumberChannels), 1)
            let frames = count / channels
            if frames > frameHint { frameHint = frames }
            for i in 0..<count {
                let a = abs(ptr[i])
                if a > peak { peak = a }
            }
        }
        return (peak, frameHint)
    }

    private func updateMeter(from buffers: UnsafeMutableAudioBufferListPointer) {
        var peak: Float = 0
        var sumSq: Float = 0
        var count = 0
        for buffer in buffers {
            guard let ptr = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let n = Int(buffer.mDataByteSize / UInt32(MemoryLayout<Float>.size))
            for i in 0..<n {
                let s = ptr[i]
                let a = abs(s)
                if a > peak { peak = a }
                sumSq += s * s
            }
            count += n
        }
        let rms = count > 0 ? sqrt(sumSq / Float(count)) : 0
        // Peak for hits; RMS so compressed / dense mixes still move the icon.
        let mixed = max(peak, rms * 2.6)
        let shaped = min(1, pow(mixed * 1.8, 0.65))

        meterLock.lock()
        if shaped > meterLevel {
            meterLevel += (shaped - meterLevel) * 0.45
        } else {
            meterLevel *= 0.88
            if meterLevel < 0.008 { meterLevel = 0 }
        }
        meterLock.unlock()
    }

    /// While EQ is soft-off, tear down the tap after sustained silence so we don’t keep it forever.
    private func notePeakForWarmBypassRelease(_ peak: Float, frames: Int) {
        guard frames > 0 else { return }

        silenceLock.lock()
        guard warmBypassActive else {
            silenceLock.unlock()
            return
        }

        if debugOptions.holdTapWhenBypassed {
            bypassSilentFrames = 0
            silenceTeardownWorkItem?.cancel()
            silenceTeardownWorkItem = nil
            silenceLock.unlock()
            return
        }

        if peak < Self.silencePeakThreshold {
            bypassSilentFrames += frames
            let rate = max(sampleRate, 1)
            let needed = Int(rate * Self.silenceReleaseSeconds)
            let shouldRelease = bypassSilentFrames >= needed && silenceTeardownWorkItem == nil
            if shouldRelease {
                let item = DispatchWorkItem { [weak self] in
                    self?.releaseWarmBypassAfterSilence()
                }
                silenceTeardownWorkItem = item
                silenceLock.unlock()
                DispatchQueue.main.async(execute: item)
                return
            }
        } else {
            bypassSilentFrames = 0
            silenceTeardownWorkItem?.cancel()
            silenceTeardownWorkItem = nil
        }
        silenceLock.unlock()
    }

    private func releaseWarmBypassAfterSilence() {
        stateLock.lock()
        defer { stateLock.unlock() }

        silenceLock.lock()
        silenceTeardownWorkItem = nil
        let stillWarm = warmBypassActive && currentProfileName == nil
        silenceLock.unlock()

        guard stillWarm, aggregateID != kAudioObjectUnknown else { return }
        if case .engaged = status { return }

        teardownUnlocked(reason: .disabled)
        status = .idle
    }

    // MARK: - Core Audio helpers

    private func selfProcessObjectID() -> AudioObjectID? {
        var pid = getpid()
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &pid,
            &size,
            &objectID
        )
        guard status == noErr, objectID != kAudioObjectUnknown else { return nil }
        return objectID
    }

    private func defaultOutputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var cfUID = uid as CFString
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPtr in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<CFString>.size),
                uidPtr,
                &size,
                &deviceID
            )
        }
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private func uidString(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.stride)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr else { return nil }
        return value as String?
    }

    private func nominalSampleRate(for deviceID: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate)
        guard status == noErr, rate > 0 else { return nil }
        return Double(rate)
    }

    /// OSStatus values commonly returned when System Audio Recording is denied.
    private static func isPermissionStatus(_ status: OSStatus) -> Bool {
        status == kAudioHardwareIllegalOperationError
            || status == kAudioHardwareBadObjectError
            || status == kAudioHardwareNotRunningError
            || status == -54 // permErr
    }
}
