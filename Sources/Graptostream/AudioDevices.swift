// SPDX-FileCopyrightText: 2026 Gary Frattarola <garyf@parkviewlab.ai>
// SPDX-License-Identifier: AGPL-3.0-or-later

import CoreAudio
import Foundation

/// An audio input device as Core Audio describes it.
struct InputDevice: Identifiable, Hashable, Sendable {
    var id: AudioObjectID
    var uid: String
    var name: String
    var channels: Int
    var transport: UInt32

    var isBluetooth: Bool {
        transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    var isAggregate: Bool { transport == kAudioDeviceTransportTypeAggregate }
}

/// Reads the system's input devices and reports when they change. Nothing here
/// changes a device: no format, no hog mode, no voice processing.
enum AudioDevices {
    static func address(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func allDeviceIDs() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
        return ids
    }

    static func string(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var addr = address(sel)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    static func transport(_ id: AudioObjectID) -> UInt32 {
        var addr = address(kAudioDevicePropertyTransportType)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value)
        return value
    }

    static func inputChannels(_ id: AudioObjectID) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// The input devices, excluding aggregates (including the app's own private one).
    static func inputs() -> [InputDevice] {
        allDeviceIDs().compactMap { id in
            let ch = inputChannels(id)
            guard ch > 0, let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
            let d = InputDevice(id: id, uid: uid, name: string(id, kAudioObjectPropertyName) ?? uid, channels: ch,
                                transport: transport(id))
            return d.isAggregate ? nil : d
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Calls `onChange` on the main queue whenever the device list changes. Returns a cancel function.
    static func watch(_ onChange: @escaping @Sendable () -> Void) -> () -> Void {
        var addr = address(kAudioHardwarePropertyDevices)
        let block: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, block)
        return {
            var a = address(kAudioHardwarePropertyDevices)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main, block)
        }
    }

    /// A private aggregate of several inputs, visible only to this process, with drift
    /// compensation on every device but the first, which provides the clock.
    static func makeAggregate(of devices: [InputDevice]) -> AudioObjectID? {
        guard devices.count > 1 else { return nil }
        let desc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "graptostream inputs",
            kAudioAggregateDeviceUIDKey: "ai.parkviewlab.graptostream.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceMainSubDeviceKey: devices[0].uid,
            kAudioAggregateDeviceSubDeviceListKey: devices.enumerated().map { i, d in
                [kAudioSubDeviceUIDKey: d.uid, kAudioSubDeviceDriftCompensationKey: i == 0 ? 0 : 1]
            },
        ]
        var id: AudioObjectID = 0
        return AudioHardwareCreateAggregateDevice(desc as CFDictionary, &id) == noErr ? id : nil
    }

    static func destroyAggregate(_ id: AudioObjectID) {
        AudioHardwareDestroyAggregateDevice(id)
    }
}
