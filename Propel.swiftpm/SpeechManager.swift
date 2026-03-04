//
//  SpeechManager.swift
//  PropelWalk
//
//   Fixes:
//  - Speaks LONG texts fully (not only the first line)
//  - Adds speakLong(...) that splits and queues chunks
//  - Priority support (urgent interrupts)
//  - Coalesces short pending speech (latest wins)
//  - Anti-repeat protection
//  - Device-safe audio session (.playback + spokenAudio)
//

import Foundation
import AVFoundation

@MainActor
final class SpeechManager: NSObject, ObservableObject {

    static let shared = SpeechManager()

    private let synthesizer = AVSpeechSynthesizer()

    @Published var isSpeaking = false

    // MARK: - Timing / anti-spam

    private var lastSpokenText: String = ""
    private var lastSpokenTime: Date = .distantPast

    /// Minimum interval between normal messages (fast for OCR/feedback)
    private let minimumSpeechInterval: TimeInterval = 0.3

    /// Extra interval to block repeating the SAME message too often
    private let sameTextRepeatInterval: TimeInterval = 2.0

    // MARK: - Pending short speech (latest wins)

    private var pendingText: String?
    private var pendingRate: Float = 0.5
    private var pendingPriority: Priority = .normal

    // MARK: - Long speech queue (NEW)

    private struct QueueItem {
        let text: String
        let rate: Float
        let priority: Priority
    }

    private var speechQueue: [QueueItem] = []
    private var isSpeakingQueue: Bool = false

    // MARK: - Audio session

    private var audioConfigured = false

    // MARK: - Priority

    enum Priority {
        case normal
        case urgent
    }

    private override init() {
        super.init()
        synthesizer.delegate = self
        configureIfNeeded()
        observeAudioSession()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Audio session

    private func configureIfNeeded() {
        guard !audioConfigured else { return }
        audioConfigured = true
        applySession()
    }

    private func applySession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback,
                                    mode: .spokenAudio,
                                    options: [.duckOthers])
            try session.setActive(true, options: [])
        } catch {
            print("❌ Speech audio session error:", error)
        }
    }

    private func prepareForSpeechNow() {
        // Re-apply every time (fixes “some other code changed my session”)
        applySession()
    }

    private func observeAudioSession() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance()
        )
    }

    @objc private func handleInterruption(_ n: Notification) {
        applySession()
        // continue queue if any
        speakNextFromQueueIfNeeded()
        // or pending
        speakPendingIfAny()
    }

    @objc private func handleRouteChange(_ n: Notification) {
        applySession()
    }

    // MARK: - Public API (SHORT messages)

    /// Speak a short message.
    /// - urgent: interrupts current speech immediately (use for "Stop")
    func speak(_ text: String,
               rate: Float = 0.5,
               priority: Priority = .normal) {

        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }

        configureIfNeeded()
        prepareForSpeechNow()

        let now = Date()

        // If we are currently speaking a long queue, treat normal short speech as "pending"
        if isSpeakingQueue && priority == .normal {
            pendingText = t
            pendingRate = rate
            pendingPriority = priority
            return
        }

        // Prevent repeating too frequently (normal only)
        if priority == .normal, t == lastSpokenText {
            if now.timeIntervalSince(lastSpokenTime) < sameTextRepeatInterval {
                return
            }
        }

        // If currently speaking
        if synthesizer.isSpeaking {
            if priority == .urgent {
                // Urgent interrupts everything
                pendingText = nil
                speechQueue.removeAll()
                isSpeakingQueue = false
                synthesizer.stopSpeaking(at: .immediate)
            } else {
                // Latest wins for short messages
                pendingText = t
                pendingRate = rate
                pendingPriority = priority
                return
            }
        }

        // Throttle normal speech
        if priority == .normal {
            let dt = now.timeIntervalSince(lastSpokenTime)
            if dt < minimumSpeechInterval {
                pendingText = t
                pendingRate = rate
                pendingPriority = priority
                return
            }
        }

        speakUtteranceNow(t, rate: rate)
        lastSpokenText = t
        lastSpokenTime = now
    }

    func speakIfChanged(_ text: String, rate: Float = 0.5, force: Bool = false) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }

        if !force, t == lastSpokenText { return }
        speak(t, rate: rate, priority: .normal)
    }

    // MARK: - Public API (LONG messages)  FIX

    /// Speak a LONG text fully (help screens, onboarding instructions).
    /// It splits into chunks and speaks them one-by-one.
    func speakLong(_ text: String,
                   rate: Float = 0.5,
                   priority: Priority = .urgent) {

        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }

        configureIfNeeded()
        prepareForSpeechNow()

        // Urgent long speech should interrupt any current speech
        if priority == .urgent {
            pendingText = nil
            speechQueue.removeAll()
            isSpeakingQueue = false
            if synthesizer.isSpeaking {
                synthesizer.stopSpeaking(at: .immediate)
            }
        } else {
            // If normal and currently speaking, just queue after
            // (but still clear any "pending short" because long should be consistent)
            pendingText = nil
        }

        // Build chunks
        let chunks = splitIntoSpeakableChunks(cleaned, maxChars: 180)

        // Queue them
        speechQueue = chunks.map { QueueItem(text: $0, rate: rate, priority: priority) }
        isSpeakingQueue = true

        // Start speaking first item
        speakNextFromQueueIfNeeded()
    }

    // MARK: - Stop

    func stop() {
        pendingText = nil
        speechQueue.removeAll()
        isSpeakingQueue = false
        synthesizer.stopSpeaking(at: .immediate)
    }

    func testSpeech() {
        speak("Propel test voice is working.", rate: 0.5, priority: .urgent)
    }

    // MARK: - Internals

    private func speakUtteranceNow(_ text: String, rate: Float) {
        prepareForSpeechNow()

        let u = AVSpeechUtterance(string: text)
        u.rate = rate
        u.volume = 1.0
        u.pitchMultiplier = 1.0
        u.voice = AVSpeechSynthesisVoice(language: "en-US") ?? AVSpeechSynthesisVoice()

        synthesizer.speak(u)
    }

    private func speakNextFromQueueIfNeeded() {
        guard isSpeakingQueue else { return }
        guard !synthesizer.isSpeaking else { return }

        if speechQueue.isEmpty {
            // Queue finished
            isSpeakingQueue = false
            // After finishing long speech, speak pending short (if any)
            speakPendingIfAny()
            return
        }

        let next = speechQueue.removeFirst()
        speakUtteranceNow(next.text, rate: next.rate)

        lastSpokenText = next.text
        lastSpokenTime = Date()
    }

    private func speakPendingIfAny() {
        guard !synthesizer.isSpeaking else { return }
        guard let t = pendingText else { return }

        let r = pendingRate
        let p = pendingPriority

        pendingText = nil
        pendingRate = 0.5
        pendingPriority = .normal

        speak(t, rate: r, priority: p)
    }

    private func splitIntoSpeakableChunks(_ text: String, maxChars: Int) -> [String] {
        // First split by paragraphs/newlines to keep structure
        let paragraphs = text
            .components(separatedBy: CharacterSet.newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var chunks: [String] = []

        for p in paragraphs {
            // Split paragraphs by sentences-ish
            let parts = p.split(whereSeparator: { $0 == "." || $0 == "!" || $0 == "?" })
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            var current = ""

            for part in parts {
                let sentence = part + "."
                if current.isEmpty {
                    current = sentence
                } else if (current.count + 1 + sentence.count) <= maxChars {
                    current += " " + sentence
                } else {
                    chunks.append(current)
                    current = sentence
                }
            }

            if !current.isEmpty {
                chunks.append(current)
            }
        }

        // Fallback if something weird: ensure not empty
        if chunks.isEmpty {
            return [text]
        }
        return chunks
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension SpeechManager: AVSpeechSynthesizerDelegate {

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = true
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            // Continue long queue first
            self.speakNextFromQueueIfNeeded()
            // If no queue, pending may run
            self.speakPendingIfAny()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            // After cancel, continue queue if it exists
            self.speakNextFromQueueIfNeeded()
            self.speakPendingIfAny()
        }
    }
}
