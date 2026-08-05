import CoreAudio
import Foundation
import Darwin

/// System-wide EQ via Core Audio process tap (macOS 14.2+).
/// Tap (muted when read) → EQ → replay through a private aggregate with the current output.
@available(macOS 14.2, *)
public final class ProcessTapAudioEngine: AudioEngine, @unchecked Sendable {
    public private(set) var status: AudioEngineStatus = .idle

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

    public init() {}

    /// Smoothed peak magnitude of the EQ'd output (0…1). Safe to read from the main thread.
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

        // Same device + engine running: only publish a new curve if it actually changed.
        // (Avoids resetting biquad state every UI poll — that caused periodic pops.)
        if aggregateID != kAudioObjectUnknown, currentDeviceUID == device.uid {
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
        sampleRate = nominalSampleRate(for: outputDeviceID)
            ?? tapSampleRate(for: tap)
            ?? sampleRate
        processor.update(profile: profile, sampleRate: sampleRate)

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
                    kAudioSubTapDriftCompensationKey: true
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

        if let aggRate = nominalSampleRate(for: aggregateID), abs(aggRate - sampleRate) > 0.5 {
            sampleRate = aggRate
            processor.update(profile: profile, sampleRate: sampleRate)
        }
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

        // Planar (one buffer per channel, common for aggregates) vs interleaved.
        let planar = outBuffers.count > 1 && outBuffers.allSatisfy { $0.mNumberChannels <= 1 }
        if planar {
            for (index, outBuffer) in outBuffers.enumerated() {
                guard let outPtr = outBuffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let frames = outBuffer.mDataByteSize / UInt32(MemoryLayout<Float>.size)
                let channel: EQProcessor.Channel = (index == 1) ? .right : .left
                engine.processor.processMono(outPtr, frames: frames, channel: channel)
            }
        } else {
            for outBuffer in outBuffers {
                guard let outPtr = outBuffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let channels = max(outBuffer.mNumberChannels, 1)
                let frames = outBuffer.mDataByteSize / UInt32(MemoryLayout<Float>.size) / channels
                engine.processor.processInterleaved(outPtr, frames: frames, channels: channels)
            }
        }

        engine.updateMeter(from: outBuffers)
        return noErr
    }

    private func updateMeter(from buffers: UnsafeMutableAudioBufferListPointer) {
        var peak: Float = 0
        for buffer in buffers {
            guard let ptr = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let count = Int(buffer.mDataByteSize / UInt32(MemoryLayout<Float>.size))
            for i in 0..<count {
                let a = abs(ptr[i])
                if a > peak { peak = a }
            }
        }
        // Soft knee so typical music (often <0.3 peak) still animates visibly.
        let shaped = min(1, pow(peak * 1.8, 0.65))

        meterLock.lock()
        if shaped > meterLevel {
            meterLevel += (shaped - meterLevel) * 0.45
        } else {
            meterLevel *= 0.88
            if meterLevel < 0.008 { meterLevel = 0 }
        }
        meterLock.unlock()
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
