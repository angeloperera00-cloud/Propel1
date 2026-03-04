//
//  ScannerView.swift
//  PropelWalk
//

import SwiftUI
import Foundation
import AVFoundation

private var isRunningInXcodePreview: Bool {
    ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
}

// MARK: - Overlay Speaker (queues full text reliably on device)

@MainActor
private final class OverlaySpeaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {

    private let synth = AVSpeechSynthesizer()
    private var didConfigureSession = false

    override init() {
        super.init()
        synth.delegate = self
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
    }

    func speakFull(_ text: String) {
        stop()
        configureSessionIfNeeded()

        let chunks = chunkHelpText(text)

        for (i, chunk) in chunks.enumerated() {
            let u = AVSpeechUtterance(string: chunk)
            u.rate = 0.50
            u.pitchMultiplier = 1.0
            u.volume = 1.0
            u.voice = AVSpeechSynthesisVoice(language: "en-US") ?? AVSpeechSynthesisVoice()

            if i == 0 { u.preUtteranceDelay = 0.15 }
            u.postUtteranceDelay = 0.10

            synth.speak(u) // queued
        }
    }

    private func configureSessionIfNeeded() {
        guard !didConfigureSession else { return }
        didConfigureSession = true

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true, options: [])
        } catch {
            print("OverlaySpeaker audio session error:", error)
        }
    }

    private func chunkHelpText(_ text: String) -> [String] {
        let paragraphs = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var result: [String] = []
        var current = ""

        func flush() {
            let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { result.append(t) }
            current = ""
        }

        for p in paragraphs {
            if current.isEmpty {
                current = p
            } else {
                let candidate = current + "\n\n" + p
                if candidate.count <= 450 {
                    current = candidate
                } else {
                    flush()
                    current = p
                }
            }
        }

        flush()
        return result
    }
}

// MARK: - First-time Help Overlay (iOS-alert style)

private struct PropelFirstTimeHelpOverlay: View {
    let text: String
    let onOK: () -> Void

    @StateObject private var speaker = OverlaySpeaker()
    @State private var didStartSpeaking = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .accessibilityHidden(true)

            VStack(spacing: 0) {
                ScrollView(showsIndicators: true) {
                    Text(text)
                        .font(.system(size: 18, weight: .regular))
                        .foregroundColor(.black)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 16)
                }
                .frame(maxHeight: 520)
                .background(Color(white: 0.92))

                Divider().background(Color.black.opacity(0.35))

                Button {
                    speaker.stop()
                    SpeechManager.shared.stop()
                    onOK()
                } label: {
                    Text("OK")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(.blue)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .accessibilityLabel("OK")
                .accessibilityHint("Closes instructions and continues.")
            }
            .frame(maxWidth: 360)
            .background(Color(white: 0.92))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.black.opacity(0.8), lineWidth: 2)
            )
            .cornerRadius(12)
            .padding(.horizontal, 20)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
        .onAppear {
            guard !isRunningInXcodePreview else { return }
            guard !didStartSpeaking else { return }
            didStartSpeaking = true

            SpeechManager.shared.stop()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                speaker.speakFull(text)
            }
        }
        .onDisappear { speaker.stop() }
    }
}

// MARK: - ScannerView

struct ScannerView: View {

    // Kept for compatibility (no Back button shown)
    let onBack: () -> Void
    let initialMode: AppMode

    @StateObject private var engine = CameraEngine()
    @State private var selectedMode: AppMode
    @State private var didStartEngine = false

    @ObservedObject private var speech = SpeechManager.shared
    @ObservedObject private var haptics = HapticsManager.shared

    // Haptics repeat
    @State private var hapticTimer: Timer?
    @State private var lastHapticState: ScanState = .clear

    // MARK: - Speech timing

    @State private var nextAllowedObstacleSpeechAt: Date = .distantPast
    @State private var nextAllowedUrgentSpeechAt: Date = .distantPast
    @State private var lastSpokenScanState: ScanState = .clear

    private let obstacleSpeechCooldown: TimeInterval = 1.2
    private let clearSpeechCooldown: TimeInterval = 1.8
    private let urgentSpeechCooldown: TimeInterval = 0.55

    // Progress feedback
    @State private var lastProgressSpokenAt: Date = .distantPast
    private let progressSpeakInterval: TimeInterval = 4.0

    // OCR speaking
    @State private var ocrHistory: [String] = []
    private let ocrHistoryMax = 2
    @State private var nextAllowedOCRSpeechAt: Date = .distantPast
    private let ocrCooldown: TimeInterval = 1.2

    // Swipe cooldown
    @State private var lastSwipeAt: Date = .distantPast
    private let swipeCooldown: TimeInterval = 0.6

    // First-time overlay
    @AppStorage("didShowCameraHelp") private var didShowCameraHelp = false
    @State private var showCameraHelp = false

    //  Big menu pages destination
    @State private var menuDestination: CameraMenuDestination?

    private var isBlockingInteraction: Bool {
        showCameraHelp || menuDestination != nil
    }

    private let cameraHelpText: String = """
Welcome to Propel!

Propel is a micro-orientation tool that supports safer movement and quick label reading.
It does not replace a cane or a guide dog.

This app was requested by a blind person to make daily movement and quick label reading easier.

Before you start:
• Try Propel in a safe place first (home or a quiet hallway).
• Keep your volume up (headphones may change where sound plays).
• Hold your phone steady.
• Move slowly. Fast motion can reduce accuracy.

SCAN SPACE (Obstacle Awareness)
Scan Space checks what is in front of you and estimates how close something is (using depth if available, otherwise camera-based estimation).

How to hold the phone:
• Hold the phone chest-high.
• Point forward (not down at the floor).
• Aim the center of the phone toward your walking direction.

What you will hear:
• Clear: The path looks open.
• Caution: Slow down and adjust.
• Stop: Obstacle very close. Stop and change direction.

HAPTIC FEEDBACK (Vibration)
Propel also uses haptics to confirm what it detects:
• Light pulses: something is far.
• Medium pulses: something is near.
• Strong / fast pulses: stop (very close obstacle).

READ LABEL (Product & Expiry Reading)
Read Label speaks visible text it can clearly see on packaging and labels.
Useful in supermarkets and pharmacies.

What it can help you read (when visible):
• Product name and description.
• Expiry date.
• Ingredients and nutrition information.
• Warnings, dosage, and instructions (pharmacy labels).

SWITCHING MODES (Swipe)
• Swipe RIGHT to open Read Label.
• Swipe LEFT to return to Scan Space.
• Or use the bottom mode control.

MENU (Top Left Button)
• Settings.
• Tutorial / Help.
• Siri Shortcuts.

Tap OK to begin.
"""

    init(
        onBack: @escaping () -> Void = {},
        initialMode: AppMode = .scanSpace
    ) {
        self.onBack = onBack
        self.initialMode = initialMode
        self._selectedMode = State(initialValue: initialMode)
    }

    var body: some View {
        ZStack(alignment: .bottom) {

            CameraPreviewView(session: engine.session)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            // Swipe layer (top portion only)
            GeometryReader { geo in
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 20)
                            .onEnded { value in
                                guard !isBlockingInteraction else { return }
                                switchModeBySwipe(value)
                            }
                    )
                    .frame(height: geo.size.height * 0.72)
                    .frame(maxWidth: .infinity, alignment: .top)
            }
            .allowsHitTesting(true)

            VStack {
                topBar
                Spacer()
            }
            .allowsHitTesting(!isBlockingInteraction)

            bottomPanel
                .allowsHitTesting(!isBlockingInteraction)

            if showCameraHelp {
                PropelFirstTimeHelpOverlay(text: cameraHelpText) {
                    speech.stop()
                    showCameraHelp = false
                    didShowCameraHelp = true
                }
                .zIndex(999)
            }
        }

        // Big pages open here
        .sheet(item: $menuDestination) { dest in
            switch dest {
            case .tutorial:
                TutorialPageView()
            case .settings:
                PropelWalkSettingsView(engine: engine)
            case .shortcuts:
                ShortcutsPageView()
            }
        }

        //  Siri -> app wiring
        .onReceive(AppRouter.shared.$requestedMode.compactMap { $0 }) { mode in
            if showCameraHelp {
                showCameraHelp = false
                didShowCameraHelp = true
            }
            selectedMode = mode
            AppRouter.shared.requestedMode = nil
        }
        .onReceive(AppRouter.shared.$requestedMenu.compactMap { $0 }) { dest in
            if showCameraHelp {
                showCameraHelp = false
                didShowCameraHelp = true
            }
            menuDestination = dest
            AppRouter.shared.requestedMenu = nil
        }

        .onAppear {
            guard !isRunningInXcodePreview else { return }

            Task { @MainActor in haptics.setup() }

            if !didStartEngine {
                didStartEngine = true
                engine.start()
            }

            engine.updateInterfaceOrientationFromUI()
            engine.setMode(selectedMode)

            nextAllowedObstacleSpeechAt = .distantPast
            nextAllowedUrgentSpeechAt = .distantPast
            nextAllowedOCRSpeechAt = .distantPast
            lastSpokenScanState = .clear
            ocrHistory.removeAll()
            lastProgressSpokenAt = .distantPast
            lastSwipeAt = .distantPast

            if !didShowCameraHelp {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    showCameraHelp = true
                }
            }
        }
        .onDisappear {
            engine.stop()
            stopRepeatingHaptics()
            speech.stop()
        }

        // Mode switch
        .onChange(of: selectedMode) { newMode in
            guard !isBlockingInteraction else { return }

            engine.setMode(newMode)
            stopRepeatingHaptics()
            Task { @MainActor in haptics.playTransition() }

            nextAllowedObstacleSpeechAt = .distantPast
            nextAllowedUrgentSpeechAt = .distantPast
            lastSpokenScanState = .clear
            lastProgressSpokenAt = .distantPast

            if newMode == .scanSpace {
                speech.speak("Scan Space", rate: 0.5, priority: .normal)
            } else {
                speech.speak("Read Label", rate: 0.5, priority: .normal)
            }
        }

        // ScanState feedback (✅ FIX: NO "Caution" voice anymore — only Clear + Stop)
        .onChange(of: engine.scanState) { newState in
            guard selectedMode == .scanSpace else { return }
            guard !isRunningInXcodePreview else { return }
            guard !isBlockingInteraction else { return }

            updateRepeatingHaptics(for: newState)

            let now = Date()

            switch newState {
            case .stop:
                guard now >= nextAllowedUrgentSpeechAt else { return }
                speech.speak("Stop", rate: 0.45, priority: .urgent)
                nextAllowedUrgentSpeechAt = now.addingTimeInterval(urgentSpeechCooldown)
                nextAllowedObstacleSpeechAt = now.addingTimeInterval(urgentSpeechCooldown)
                lastSpokenScanState = .stop

            case .caution:
                // ✅ SILENT: we still allow haptics + UI to show caution,
                // but we DO NOT speak any caution message.
                // We keep the cooldown so it won’t spam other messages.
                guard now >= nextAllowedObstacleSpeechAt else { return }
                nextAllowedObstacleSpeechAt = now.addingTimeInterval(obstacleSpeechCooldown)
                lastSpokenScanState = .caution

            case .clear:
                guard now >= nextAllowedObstacleSpeechAt else { return }
                speech.speakIfChanged("Clear", rate: 0.5, force: false)
                nextAllowedObstacleSpeechAt = now.addingTimeInterval(clearSpeechCooldown)
                lastSpokenScanState = .clear
            }
        }

        // Progress feedback (only when uncertain)
        .onChange(of: engine.obstacleSeverity) { sevOpt in
            guard selectedMode == .scanSpace else { return }
            guard !isRunningInXcodePreview else { return }
            guard !isBlockingInteraction else { return }

            let sev = sevOpt ?? .uncertain
            let now = Date()

            if sev == .uncertain && engine.obstacleDistanceMeters <= 0.01 {
                if now.timeIntervalSince(lastProgressSpokenAt) >= progressSpeakInterval,
                   now >= nextAllowedObstacleSpeechAt {
                    speech.speakIfChanged("Scanning. Hold steady.", rate: 0.5, force: false)
                    lastProgressSpokenAt = now
                    nextAllowedObstacleSpeechAt = now.addingTimeInterval(obstacleSpeechCooldown)
                }
            }
        }

        // OCR feedback (Read Label)
        .onChange(of: engine.recognizedText) { text in
            guard selectedMode == .readLabel else { return }
            guard !isRunningInXcodePreview else { return }
            guard !isBlockingInteraction else { return }

            let trimmed = normalizeOCR(text)
            guard trimmed.count >= 3 else { return }

            let now = Date()
            guard now >= nextAllowedOCRSpeechAt else { return }

            pushOCR(trimmed)

            let shouldSpeak = isOCRStable() || ocrHistory.count >= ocrHistoryMax
            guard shouldSpeak else { return }

            let best = mostFrequentOCR() ?? trimmed

            Task { @MainActor in haptics.success() }
            speech.speak(best, rate: 0.50, priority: .normal)

            nextAllowedOCRSpeechAt = now.addingTimeInterval(ocrCooldown)
            ocrHistory.removeAll()
        }
        .ignoresSafeArea(edges: .bottom)
        .preferredColorScheme(.dark)
    }

    // MARK: - Swipe helper

    private func switchModeBySwipe(_ value: DragGesture.Value) {
        let dx = value.translation.width
        let dy = value.translation.height

        guard abs(dx) > abs(dy) else { return }
        guard abs(dx) > 35 else { return }

        let now = Date()
        guard now.timeIntervalSince(lastSwipeAt) >= swipeCooldown else { return }
        lastSwipeAt = now

        selectedMode = (dx < 0) ? .readLabel : .scanSpace
    }

    // MARK: - Haptics helpers

    private func updateRepeatingHaptics(for state: ScanState) {
        guard state != lastHapticState else { return }
        lastHapticState = state

        stopRepeatingHaptics()

        switch state {
        case .clear:
            break
        case .caution:
            Task { @MainActor in haptics.tap() }
            hapticTimer = Timer.scheduledTimer(withTimeInterval: 0.90, repeats: true) { _ in
                Task { @MainActor in haptics.tap() }
            }
        case .stop:
            Task { @MainActor in haptics.warning() }
            hapticTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { _ in
                Task { @MainActor in haptics.warning() }
            }
        }
    }

    private func stopRepeatingHaptics() {
        hapticTimer?.invalidate()
        hapticTimer = nil
        lastHapticState = .clear
        Task { @MainActor in haptics.stop() }
    }

    // MARK: - OCR helpers

    private func normalizeOCR(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return lines.prefix(8).joined(separator: "\n")
    }

    private func pushOCR(_ text: String) {
        ocrHistory.append(text)
        if ocrHistory.count > ocrHistoryMax {
            ocrHistory.removeFirst(ocrHistory.count - ocrHistoryMax)
        }
    }

    private func isOCRStable() -> Bool {
        guard ocrHistory.count >= 2 else { return false }
        let a = ocrHistory[ocrHistory.count - 2]
        let b = ocrHistory[ocrHistory.count - 1]
        if a == b { return true }
        return similarity(a, b) >= 0.80
    }

    private func mostFrequentOCR() -> String? {
        guard !ocrHistory.isEmpty else { return nil }
        var counts: [String: Int] = [:]
        for t in ocrHistory { counts[t, default: 0] += 1 }
        return counts.max(by: { $0.value < $1.value })?.key
    }

    private func similarity(_ a: String, _ b: String) -> Double {
        let setA = Set(a.lowercased())
        let setB = Set(b.lowercased())
        let union = setA.union(setB).count
        guard union > 0 else { return 0 }
        let inter = setA.intersection(setB).count
        return Double(inter) / Double(union)
    }

    // MARK: - Text helpers

    private func distanceText(_ meters: Float) -> String {
        guard meters > 0 else { return "Unknown" }
        return String(format: "%.1f m", meters)
    }

    private func severityText(_ severity: ObstacleSeverity) -> String {
        switch severity {
        case .clear: return "Clear"
        case .far: return "Far"
        case .near: return "Near"
        case .veryClose: return "Very Close"
        case .uncertain: return "Uncertain"
        }
    }

    // MARK: - UI

    private var topBar: some View {
        HStack(spacing: 12) {

            CameraMenuButton(destination: $menuDestination)

            Spacer()

            if selectedMode == .scanSpace {
                stateBadge
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.25), value: engine.scanState)
            } else {
                Text("Read Label")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white.opacity(0.75))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.10))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.20), lineWidth: 1))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .background(
            LinearGradient(
                colors: [.black.opacity(0.65), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var stateBadge: some View {
        HStack(spacing: 7) {
            Circle().fill(stateColor).frame(width: 11, height: 11)
            Text(stateLabel)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(stateColor.opacity(0.22))
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(stateColor.opacity(0.55), lineWidth: 1.2))
    }

    private var stateColor: Color {
        switch engine.scanState {
        case .clear: return .green
        case .caution: return .yellow
        case .stop: return .red
        }
    }

    private var stateLabel: String {
        switch engine.scanState {
        case .clear: return "Clear"
        case .caution: return "Caution"
        case .stop: return "Stop"
        }
    }

    private var bottomPanel: some View {
        VStack(spacing: 0) {

            Group {
                if selectedMode == .scanSpace {
                    scanSpaceContent
                } else {
                    readLabelContent
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Picker("Mode", selection: $selectedMode) {
                Text("Scan Space").tag(AppMode.scanSpace)
                Text("Read Label").tag(AppMode.readLabel)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.bottom, 44)
            .padding(.top, 10)
        }
        .background(.ultraThinMaterial)
    }

    private var scanSpaceContent: some View {
        let sev = engine.obstacleSeverity ?? .uncertain

        return VStack(spacing: 12) {
            VStack(spacing: 8) {
                HStack {
                    Text("Distance:")
                        .foregroundColor(.white.opacity(0.75))
                    Spacer()
                    Text(distanceText(engine.obstacleDistanceMeters))
                        .foregroundColor(.white)
                        .fontWeight(.bold)
                }

                HStack {
                    Text("Severity:")
                        .foregroundColor(.white.opacity(0.75))
                    Spacer()
                    Text(severityText(sev))
                        .foregroundColor(.white)
                        .fontWeight(.bold)
                }
            }

            HStack(spacing: 0) {
                stateBlock(label: "Clear", color: .green, isActive: engine.scanState == .clear)
                stateBlock(label: "Caution", color: .yellow, isActive: engine.scanState == .caution)
                stateBlock(label: "Stop", color: .red, isActive: engine.scanState == .stop)
            }
        }
    }

    private func stateBlock(label: String, color: Color, isActive: Bool) -> some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(isActive ? color.opacity(0.25) : Color.clear)
                    .frame(width: 52, height: 52)

                Circle()
                    .fill(isActive ? color : color.opacity(0.18))
                    .frame(width: 38, height: 38)
                    .shadow(color: isActive ? color.opacity(0.7) : .clear, radius: 8)
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isActive)

            Text(label)
                .font(.system(size: 13, weight: isActive ? .bold : .regular))
                .foregroundColor(isActive ? .white : .white.opacity(0.45))
        }
        .frame(maxWidth: .infinity)
    }

    private var readLabelContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "text.viewfinder")
                    .foregroundColor(.white.opacity(0.7))
                Text("Read Label")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.white.opacity(0.7))
                Spacer()

                if engine.recognizedText.isEmpty {
                    HStack(spacing: 4) {
                        Circle().fill(Color.yellow).frame(width: 7, height: 7)
                        Text("Scanning…")
                            .font(.caption2)
                            .foregroundColor(.yellow)
                    }
                } else {
                    HStack(spacing: 4) {
                        Circle().fill(Color.green).frame(width: 7, height: 7)
                        Text("Found")
                            .font(.caption2)
                            .foregroundColor(.green)
                    }
                }
            }

            if engine.recognizedText.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "shippingbox")
                        .font(.largeTitle)
                        .foregroundColor(.white.opacity(0.25))
                    Text("Hold phone 15–30 cm from label")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.45))
                    Text("Keep steady for 1–2 seconds")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.3))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    Text(engine.recognizedText)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(2)
                }
                .frame(height: 110)

                Button {
                    engine.recognizedText = ""
                    ocrHistory.removeAll()
                    nextAllowedOCRSpeechAt = .distantPast
                    Task { @MainActor in haptics.tap() }
                    speech.speak("Cleared", rate: 0.5, priority: .normal)
                } label: {
                    Label("Clear", systemImage: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.6))
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }
}

#if DEBUG
struct ScannerView_Previews: PreviewProvider {
    static var previews: some View {
        ScannerView(onBack: {}, initialMode: .scanSpace)
    }
}
#endif
