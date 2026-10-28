// SPDX-FileCopyrightText: 2026 Gary Frattarola <garyf@parkviewlab.ai>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// A block of merged mono audio, with the input that carried it.
struct AudioBlock: @unchecked Sendable {
    var buffer: AVAudioPCMBuffer
    var source: String
}

/// Captures the selected inputs as shared inputs (several are combined into a private
/// aggregate device), measures each input's level, and merges them into one mono
/// stream by keeping the channel currently carrying speech.
final class AudioCapture: @unchecked Sendable {
    /// Per-device levels, 0...1, by device uid.
    var onLevels: (@Sendable ([String: Float]) -> Void)?
    /// Merged mono audio.
    var onAudio: (@Sendable (AudioBlock) -> Void)?
    /// The engine stopped on its own (a device left, or its configuration changed).
    var onInterrupted: (@Sendable (String) -> Void)?

    private let engine = AVAudioEngine()
    private var aggregate: AudioObjectID?
    private var channelMap: [(uid: String, label: String)] = []
    private var current = 0
    private var challenger: (channel: Int, blocks: Int)?
    private var configObserver: NSObjectProtocol?
    private(set) var running = false

    /// Starts capture from `devices`. Throws if the input cannot be opened.
    func start(_ devices: [InputDevice]) throws {
        stop()
        guard !devices.isEmpty else { return }
        let deviceID: AudioObjectID
        if devices.count == 1 {
            deviceID = devices[0].id
        } else {
            guard let agg = AudioDevices.makeAggregate(of: devices) else {
                throw NSError(domain: "graptostream", code: 1, userInfo: [NSLocalizedDescriptionKey: "the selected microphones could not be combined"])
            }
            aggregate = agg
            deviceID = agg
        }
        channelMap = devices.flatMap { d in
            (0..<d.channels).map { c in (d.uid, d.channels > 1 ? "\(d.name) ch \(c + 1)" : d.name) }
        }
        current = 0
        challenger = nil

        let input = engine.inputNode
        guard let unit = input.audioUnit else {
            throw NSError(domain: "graptostream", code: 2, userInfo: [NSLocalizedDescriptionKey: "no input unit"])
        }
        var id = deviceID
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &id, UInt32(MemoryLayout<AudioObjectID>.size))
        guard status == noErr else {
            throw NSError(domain: "graptostream", code: 3, userInfo: [NSLocalizedDescriptionKey: "the input device could not be opened (\(status))"])
        }
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw NSError(domain: "graptostream", code: 4, userInfo: [NSLocalizedDescriptionKey: "the input has no channels"])
        }
        let frames = AVAudioFrameCount(format.sampleRate / 10)  // about 100 ms per block
        input.installTap(onBus: 0, bufferSize: frames, format: format) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                                queue: nil) { [weak self] _ in
            self?.onInterrupted?("the input's configuration changed")
        }
        engine.prepare()
        try engine.start()
        running = true
    }

    func stop() {
        if running {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        running = false
        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
        configObserver = nil
        if let a = aggregate { AudioDevices.destroyAggregate(a) }
        aggregate = nil
    }

    static func rms(_ p: UnsafePointer<Float>, _ n: Int) -> Float {
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { sum += p[i] * p[i] }
        return (sum / Float(n)).squareRoot()
    }

    /// A level on a 0...1 scale from -60 dBFS to 0 dBFS.
    static func meter(_ rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return max(0, min(1, (db + 60) / 60))
    }

    /// Speech below this level never takes over the merge.
    static let speechFloor: Float = 0.01
    /// A channel takes over after this many consecutive louder blocks (about 0.3 s).
    static let switchBlocks = 3

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        var levels: [Float] = []
        for c in 0..<channels { levels.append(Self.rms(data[c], n)) }

        // Levels per device: the loudest of its channels.
        var byDevice: [String: Float] = [:]
        for (c, level) in levels.enumerated() where c < channelMap.count {
            let uid = channelMap[c].uid
            byDevice[uid] = max(byDevice[uid] ?? 0, Self.meter(level))
        }
        onLevels?(byDevice)

        // The merge: stay on the current channel unless another is clearly louder for a while.
        if current >= channels { current = 0 }
        if let loudest = levels.indices.max(by: { levels[$0] < levels[$1] }), loudest != current,
           levels[loudest] > Self.speechFloor, levels[loudest] > levels[current] * 2 {
            if challenger?.channel == loudest {
                challenger!.blocks += 1
            } else {
                challenger = (loudest, 1)
            }
            if challenger!.blocks >= Self.switchBlocks {
                current = loudest
                challenger = nil
            }
        } else {
            challenger = nil
        }

        guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate, channels: 1,
                                       interleaved: false),
              let out = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buffer.frameLength) else { return }
        out.frameLength = buffer.frameLength
        out.floatChannelData![0].update(from: data[current], count: n)
        let label = current < channelMap.count ? channelMap[current].label : "input"
        onAudio?(AudioBlock(buffer: out, source: label))
    }
}

/// Feeds a recording at real-time pace instead of the microphones, for testing
/// without microphone permission (`--feed <file>`). Loops at the end.
final class FileFeed: @unchecked Sendable {
    var onAudio: (@Sendable (AudioBlock) -> Void)?
    private var task: Task<Void, Never>?

    func start(_ url: URL) {
        stop()
        task = Task.detached { [weak self] in
            while !Task.isCancelled {
                guard let file = try? AVAudioFile(forReading: url) else { return }
                let src = file.processingFormat
                guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: src.sampleRate, channels: 1,
                                               interleaved: false) else { return }
                let chunk = AVAudioFrameCount(src.sampleRate / 10)
                let start = Date()
                var fed = 0.0
                while file.framePosition < file.length, !Task.isCancelled {
                    guard let buf = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: chunk),
                          (try? file.read(into: buf, frameCount: chunk)) != nil,
                          let out = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buf.frameLength),
                          let d = buf.floatChannelData else { return }
                    out.frameLength = buf.frameLength
                    out.floatChannelData![0].update(from: d[0], count: Int(buf.frameLength))
                    self?.onAudio?(AudioBlock(buffer: out, source: url.lastPathComponent))
                    fed += Double(buf.frameLength) / src.sampleRate
                    let ahead = start.addingTimeInterval(fed).timeIntervalSinceNow
                    if ahead > 0 { try? await Task.sleep(nanoseconds: UInt64(ahead * 1e9)) }
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
