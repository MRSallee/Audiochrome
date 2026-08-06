import CoreAudio
import Foundation

public final class AudioDeviceService: @unchecked Sendable {
    private var defaultListenerBlock: AudioObjectPropertyListenerBlock?
    private var devicesListenerBlock: AudioObjectPropertyListenerBlock?
    private let lock = NSLock()

    public init() {}

    deinit {
        stopObserving()
    }

    public func defaultOutputUID() -> String? {
        defaultOutputDevice()?.uid
    }

    public func defaultOutputDevice() -> AudioOutputDevice? {
        guard let deviceID = defaultOutputDeviceID() else { return nil }
        return makeDevice(deviceID, defaultUID: uid(for: deviceID))
    }

    public func outputDevices() -> [AudioOutputDevice] {
        let defaultUID = defaultOutputUID()
        return allOutputDeviceIDs().compactMap { makeDevice($0, defaultUID: defaultUID) }
            .filter { !DeviceIdentity.isInternalAudiochromeDevice(uid: $0.uid, name: $0.name) }
    }

    /// Fires on the main queue when the default output or device list changes.
    public func startObserving(onChange: @escaping @Sendable () -> Void) {
        stopObserving()

        let queue = DispatchQueue.main
        let defaultBlock: AudioObjectPropertyListenerBlock = { _, _ in
            onChange()
        }
        let devicesBlock: AudioObjectPropertyListenerBlock = { _, _ in
            onChange()
        }

        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultAddress,
            queue,
            defaultBlock
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress,
            queue,
            devicesBlock
        )

        lock.lock()
        defaultListenerBlock = defaultBlock
        devicesListenerBlock = devicesBlock
        lock.unlock()
    }

    public func stopObserving() {
        lock.lock()
        let defaultBlock = defaultListenerBlock
        let devicesBlock = devicesListenerBlock
        defaultListenerBlock = nil
        devicesListenerBlock = nil
        lock.unlock()

        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        if let defaultBlock {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &defaultAddress,
                DispatchQueue.main,
                defaultBlock
            )
        }
        if let devicesBlock {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &devicesAddress,
                DispatchQueue.main,
                devicesBlock
            )
        }
    }

    // MARK: - Core Audio helpers

    private func makeDevice(_ deviceID: AudioDeviceID, defaultUID: String?) -> AudioOutputDevice? {
        guard let uid = uid(for: deviceID) else { return nil }
        let transport = transportTypeName(for: deviceID)
        let resolved = resolveFriendlyName(for: deviceID, transport: transport)
        guard !resolved.isEmpty else { return nil }
        return AudioOutputDevice(
            uid: uid,
            name: resolved,
            isDefault: uid == defaultUID,
            isAvailable: true,
            transport: transport
        )
    }

    /// Prefer a room/device label when Core Audio only exposes the generic "AirPlay" name.
    private func resolveFriendlyName(for deviceID: AudioDeviceID, transport: String?) -> String {
        let candidates: [String?] = [
            name(for: deviceID),
            stringProperty(deviceID, selector: kAudioObjectPropertyName, scope: kAudioObjectPropertyScopeGlobal),
            stringProperty(deviceID, selector: kAudioObjectPropertyElementName, scope: kAudioDevicePropertyScopeOutput),
            stringProperty(deviceID, selector: kAudioObjectPropertyElementCategoryName, scope: kAudioDevicePropertyScopeOutput)
        ]

        let cleaned = candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // Prefer anything more specific than the generic AirPlay label.
        if let better = cleaned.first(where: { $0.caseInsensitiveCompare("AirPlay") != .orderedSame }) {
            return better
        }

        // Only probe data-source names when the device label is missing/generic —
        // some HAL proxies crash on that property even after HasProperty.
        if let dataSource = dataSourceName(for: deviceID)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !dataSource.isEmpty {
            return dataSource
        }
        return cleaned.first ?? ""
    }

    private func dataSourceName(for deviceID: AudioDeviceID) -> String? {
        guard let sourceID = dataSourceID(for: deviceID) else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSourceNameForIDCFString,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }

        var qualifier = sourceID
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            deviceID,
            &address,
            UInt32(MemoryLayout<UInt32>.size),
            &qualifier,
            &size
        ) == noErr, size > 0 else {
            return nil
        }

        // CFStringRef out-parameter (not Optional CFString?) — the Optional layout
        // can pass a null buffer into HAL under release optimization.
        var unmanaged: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &unmanaged) { ptr in
            AudioObjectGetPropertyData(
                deviceID,
                &address,
                UInt32(MemoryLayout<UInt32>.size),
                &qualifier,
                &size,
                ptr
            )
        }
        guard status == noErr, let unmanaged else { return nil }
        return unmanaged.takeUnretainedValue() as String
    }

    private func dataSourceID(for deviceID: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var size = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
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

    private func allOutputDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        ) == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceIDs
        ) == noErr else { return [] }

        return deviceIDs.filter { hasOutputChannels($0) }
    }

    private func hasOutputChannels(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else {
            return false
        }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw) == noErr else {
            return false
        }
        let bufferList = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        var channels = 0
        for buffer in buffers {
            channels += Int(buffer.mNumberChannels)
        }
        return channels > 0
    }

    private func transportTypeName(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<UInt32>.size)
        var transport: UInt32 = 0
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport) == noErr else {
            return nil
        }
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "BuiltIn"
        case kAudioDeviceTransportTypeAggregate: return "Aggregate"
        case kAudioDeviceTransportTypeVirtual: return "Virtual"
        case kAudioDeviceTransportTypePCI: return "PCI"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeFireWire: return "FireWire"
        case kAudioDeviceTransportTypeBluetooth: return "Bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE: return "BluetoothLE"
        case kAudioDeviceTransportTypeHDMI: return "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        case kAudioDeviceTransportTypeAVB: return "AVB"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        default: return String(format: "0x%08x", transport)
        }
    }

    private func uid(for deviceID: AudioDeviceID) -> String? {
        stringProperty(
            deviceID,
            selector: kAudioDevicePropertyDeviceUID,
            scope: kAudioObjectPropertyScopeGlobal
        )
    }

    private func name(for deviceID: AudioDeviceID) -> String? {
        stringProperty(
            deviceID,
            selector: kAudioDevicePropertyDeviceNameCFString,
            scope: kAudioObjectPropertyScopeGlobal
        )
    }

    private func stringProperty(
        _ deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var unmanaged: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &unmanaged) { ptr in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let unmanaged else { return nil }
        return unmanaged.takeUnretainedValue() as String
    }
}
