// SPDX-FileCopyrightText: 2026 Gary Frattarola <garyf@parkviewlab.ai>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AVFoundation
import CoreMedia
import Foundation
import GraptostreamCore
import Speech

/// Turns merged audio into provisional and final segments with Apple's SpeechAnalyzer.
/// One analysis session runs per listening period. `.fastResults` keeps provisional
/// text about a second behind the speech and final text about a second after a pause
/// (measured on 2026-10-28; without it, results came in bursts about 4 s apart).
final class Recognizer: @unchecked Sendable {
    struct Output: Sendable {
        var segment: Segment
    }

    enum ModelState: Equatable, Sendable {
        case unknown, installing, ready
        case failed(String)
    }

    /// Provisional and final segments (final ones not yet addressed).
    var onSegment: (@Sendable (Segment) -> Void)?
    var onError: (@Sendable (String) -> Void)?

    let locale = Locale(identifier: "en-US")
    /// A segment still provisional after this long is finalised.
    var maximumSegmentSeconds: Double {
        get { lock.withLock { _maximumSegmentSeconds } }
        set { lock.withLock { _maximumSegmentSeconds = newValue } }
    }
    private var _maximumSegmentSeconds: Double = 30
    /// Whether the current segment has had a provisional version published.
    private var currentPublished = false

    private let lock = NSLock()
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?
    private var resultsTask: Task<Void, Never>?
    private var sessionStart = Date()
    private var counter = 0
    private var currentID: String?
    private var timing = SegmentTiming()
    private var lastSource: String?

    func makeTranscriber() -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults],
                          attributeOptions: [.audioTimeRange])
    }

    /// Installs the speech model for the locale if the system does not have it yet.
    func prepareModel() async -> ModelState {
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [makeTranscriber()]) {
                try await request.downloadAndInstall()
            }
            return .ready
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func start() async throws {
        await stop()
        let transcriber = makeTranscriber()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw NSError(domain: "graptostream", code: 10, userInfo: [NSLocalizedDescriptionKey: "no audio format for the speech engine"])
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        lock.withLock {
            self.analyzer = analyzer
            self.input = continuation
            self.analyzerFormat = format
            self.converter = nil
            self.sessionStart = Date()
            self.currentID = nil
            self.timing.reset()
        }
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    self?.handle(result)
                }
            } catch {
                self?.onError?("speech engine: \(error.localizedDescription)")
            }
        }
        try await analyzer.start(inputSequence: stream)
    }

    func stop() async {
        let (analyzer, input) = lock.withLock {
            let pair = (self.analyzer, self.input)
            self.analyzer = nil
            self.input = nil
            return pair
        }
        input?.finish()
        if let analyzer { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
        await resultsTask?.value
        resultsTask = nil
    }

    /// Feeds one block of mono audio, converting it to the engine's format.
    func feed(_ block: AudioBlock) {
        lock.lock()
        guard let input, let format = analyzerFormat else { lock.unlock(); return }
        let src = block.buffer.format
        if converter == nil || converter!.inputFormat != src {
            converter = AVAudioConverter(from: src, to: format)
        }
        let converter = self.converter
        lastSource = block.source
        lock.unlock()
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(block.buffer.frameLength) * format.sampleRate / src.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var given = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return block.buffer
        }
        if error == nil, out.frameLength > 0 { input.yield(AnalyzerInput(buffer: out)) }
    }

    private func handle(_ result: SpeechTranscriber.Result) {
        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        let end = result.range.end.seconds
        if currentID == nil {
            counter += 1
            currentID = String(format: "%06d", counter)
            currentPublished = false
        }
        // An empty final still closes a segment whose provisional text was published,
        // so that readers replace it; an empty provisional, or an empty final with
        // nothing before it, is not published.
        let publish = !text.isEmpty || (result.isFinal && currentPublished)
        if !result.isFinal, !text.isEmpty { currentPublished = true }
        let id = currentID!
        let hasWords = text.contains { $0.isLetter || $0.isNumber }
        let start = result.isFinal ? result.range.start.seconds
            : timing.provisional(rangeEnd: end, hasWords: hasWords)
        let tooLong = !result.isFinal && timing.isTooLong(end: end, limit: _maximumSegmentSeconds)
        let origin = sessionStart
        let source = lastSource
        if result.isFinal {
            currentID = nil
            timing.reset()
        }
        let analyzer = self.analyzer
        lock.unlock()

        guard publish else { return }
        let seg = Segment(seg: id, state: result.isFinal ? .final : .provisional,
                          start: origin.addingTimeInterval(start.isFinite ? start : 0),
                          end: origin.addingTimeInterval(end.isFinite ? end : 0),
                          text: text, source: source)
        onSegment?(seg)
        if tooLong, let analyzer {
            Task { try? await analyzer.finalize(through: nil) }
        }
    }

}
