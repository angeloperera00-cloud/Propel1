import SwiftUI
import UIKit
import AppIntents
import AVFoundation

// MARK: - Simple Router (for Siri -> app navigation)
@MainActor
final class AppRouter: ObservableObject {
    static let shared = AppRouter()

    @Published var requestedMode: AppMode? = nil
    @Published var requestedMenu: CameraMenuDestination? = nil

    func open(_ dest: CameraMenuDestination) { requestedMenu = dest }
    func setMode(_ mode: AppMode) { requestedMode = mode }

    func clear() {
        requestedMode = nil
        requestedMenu = nil
    }
}

// MARK: - Destinations
enum CameraMenuDestination: String, Identifiable {
    case tutorial
    case settings
    case shortcuts
    var id: String { rawValue }
}

// MARK: - Menu Button
struct CameraMenuButton: View {
    @Binding var destination: CameraMenuDestination?

    var body: some View {
        Menu {
            Button { destination = .tutorial } label: {
                Label("Tutorial", systemImage: "questionmark.circle")
            }
            Button { destination = .settings } label: {
                Label("Settings", systemImage: "gearshape")
            }
            Button { destination = .shortcuts } label: {
                Label("Shortcuts", systemImage: "wave.3.right")
            }
        } label: {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.white)
                .padding(.vertical, 12)
                .padding(.horizontal, 14)
                .background(Color.white.opacity(0.18))
                .overlay(Capsule().stroke(Color.white.opacity(0.35), lineWidth: 1.2))
                .clipShape(Capsule())
        }
        .accessibilityLabel("Menu")
        .accessibilityHint("Opens settings, tutorial, and shortcuts")
        .accessibilitySortPriority(100)
    }
}

// MARK: - Tutorial Page (full story + spoken)
struct TutorialPageView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var speaker = TutorialSpeaker()

    private let bg = Color(red: 0.94, green: 0.94, blue: 0.96)

    private let fullStory: String = """
Welcome to Propel!

Propel is a micro-orientation tool that supports safer movement and quick label reading.
It does not replace a cane or a guide dog.

This app was built with input from blind users and members of blind communities.

Before you start:
• Try Propel in a safe place first (home or a quiet hallway).
• Keep your volume up. Headphones may change where sound plays.
• Hold your phone steady.
• Move slowly. Fast motion can reduce accuracy.
• Always use your cane or guide dog as you normally would.

SCAN SPACE (Obstacle Awareness)
Scan Space checks what is in front of you and estimates how close something is.
If your device supports depth, it uses depth for better distance.
If not, it uses camera-based estimation.

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

Tip:
If you feel strong fast vibration, stop first, then decide whether to turn, step back, or change direction.
If you are unsure, pause and re-scan slowly.

READ LABEL (Product & Expiry Reading)
Read Label speaks visible text it can clearly see on packaging and labels.
Useful in supermarkets and pharmacies.

What it can help you read (when visible):
• Product name and description.
• Expiry date.
• Ingredients and nutrition information.
• Warnings, dosage, and instructions (pharmacy labels).

Tips for better label reading:
• Hold the phone 15–30 cm from the label.
• Keep steady for 1–2 seconds.
• Reduce glare by tilting the phone slightly.
• If results are wrong, move closer or change the angle and try again.

SWITCHING MODES (Swipe)
• Swipe RIGHT to open Read Label.
• Swipe LEFT to return to Scan Space.
• Or use the bottom mode control.

MENU
Use the menu button to open:
• Settings (turn haptics or voice on/off, and auto light).
• Tutorial (this page).
• Siri Shortcuts (voice commands).

SIRI SHORTCUTS
You can say:
• “Scan Space”
• “Read Label”
• “Open Tutorial”
• “Open Settings”
• “Open Shortcuts”

SAFETY REMINDER
Propel is a support tool. It can help, but it can make mistakes.
Always prioritize safety, move slowly, and rely on your mobility skills and tools.
"""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Text(fullStory)
                        .font(.system(size: 18))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 40)
            }
            .background(bg.ignoresSafeArea())
            .navigationTitle("Tutorial")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        speaker.stop()
                        dismiss()
                    }
                    .foregroundColor(.black)
                    .accessibilityLabel("Close tutorial")
                }
            }
            .onAppear { speaker.speak(fullStory) }
            .onDisappear { speaker.stop() }
        }
        .preferredColorScheme(.light)
    }
}

// A tiny speaker wrapper so this file is standalone.
@MainActor
final class TutorialSpeaker: ObservableObject {
    private let synth = AVSpeechSynthesizer()
    private var didConfigureSession = false

    func stop() { synth.stopSpeaking(at: .immediate) }

    func speak(_ text: String) {
        stop()
        configureSessionIfNeeded()
        SpeechManager.shared.stop()

        let chunks = chunk(text, max: 420)
        for (i, chunk) in chunks.enumerated() {
            let u = AVSpeechUtterance(string: chunk)
            u.rate = 0.50
            u.pitchMultiplier = 1.0
            u.volume = 1.0
            u.voice = AVSpeechSynthesisVoice(language: "en-US") ?? AVSpeechSynthesisVoice()
            if i == 0 { u.preUtteranceDelay = 0.10 }
            u.postUtteranceDelay = 0.08
            synth.speak(u)
        }
    }

    private func configureSessionIfNeeded() {
        guard !didConfigureSession else { return }
        didConfigureSession = true
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true, options: [])
        } catch {
            print("TutorialSpeaker audio session error:", error)
        }
    }

    private func chunk(_ text: String, max: Int) -> [String] {
        let cleaned = text.replacingOccurrences(of: "\r\n", with: "\n")
        let paragraphs = cleaned
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var out: [String] = []
        var current = ""

        func flush() {
            let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append(t) }
            current = ""
        }

        for p in paragraphs {
            if current.isEmpty {
                current = p
            } else {
                let candidate = current + "\n\n" + p
                if candidate.count <= max {
                    current = candidate
                } else {
                    flush()
                    current = p
                }
            }
        }
        flush()
        return out
    }
}

// MARK: - Settings Page (ONLY toggles you asked for)
struct PropelWalkSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @ObservedObject private var haptics = HapticsManager.shared

    // Safe voice toggle even if SpeechManager doesn't have isEnabled yet
    @AppStorage("voiceEnabled") private var voiceEnabled: Bool = true

    // Persist torch preference
    @AppStorage("autoTorchEnabled") private var autoTorchEnabled: Bool = true

    private let bg = Color(red: 0.94, green: 0.94, blue: 0.96)

    let engine: CameraEngine

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Feedback")
                            .font(.headline)
                            .foregroundColor(.black)

                        //  FIXED HERE: isEnabled (not enabled)
                        Toggle(isOn: $haptics.isEnabled) {
                            Text("Haptics")
                                .foregroundColor(.black)
                        }
                        .tint(.black)

                        Toggle(isOn: $voiceEnabled) {
                            Text("Voice feedback")
                                .foregroundColor(.black)
                        }
                        .tint(.black)
                        .onChange(of: voiceEnabled) { on in
                            if !on { SpeechManager.shared.stop() }
                            // If you add SpeechManager.shared.isEnabled later, set it here too.
                        }

                    }
                    .padding(18)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Camera")
                            .font(.headline)
                            .foregroundColor(.black)

                        Toggle(isOn: $autoTorchEnabled) {
                            Text("Auto light")
                                .foregroundColor(.black)
                        }
                        .tint(.black)
                        .onChange(of: autoTorchEnabled) { newValue in
                            engine.setAutoTorchEnabled(newValue)
                        }

                        Text("Auto light turns on the phone torch in dark environments.")
                            .font(.footnote)
                            .foregroundColor(.black.opacity(0.65))
                    }
                    .padding(18)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 40)
            }
            .background(bg.ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(.black)
                        .accessibilityLabel("Close settings")
                }
            }
        }
        .preferredColorScheme(.light)
        .onAppear {
            engine.setAutoTorchEnabled(autoTorchEnabled)
        }
    }
}

// MARK: - Shortcuts Page (donate + show voice phrases)
struct ShortcutsPageView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var donationStatus: String?

    private let bg = Color(red: 0.94, green: 0.94, blue: 0.96)

    private let phrases = [
        "Scan Space in PropelWalk",
        "Read Label in PropelWalk",
        "Open Tutorial in PropelWalk",
        "Open Settings in PropelWalk",
        "Open Shortcuts in PropelWalk"
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {

                    VStack(spacing: 12) {
                        Text("Shortcuts")
                            .font(.system(size: 32, weight: .bold))
                            .foregroundColor(.black)

                        Text("Add Siri shortcuts so you can control Propel Walk by voice.")
                            .font(.system(size: 18))
                            .foregroundColor(.black)
                            .multilineTextAlignment(.center)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                    VStack(alignment: .leading, spacing: 12) {
                        Text("With Siri you can say:")
                            .font(.headline)
                            .foregroundColor(.black)

                        ForEach(phrases, id: \.self) { phrase in
                            HStack(alignment: .top, spacing: 10) {
                                Text("•").font(.headline).foregroundColor(.black)
                                Text(phrase).font(.system(size: 18, weight: .semibold)).foregroundColor(.black)
                            }
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("With Siri you can say: \(phrases.joined(separator: ", ")).")

                    Button {
                        Task { await donateShortcuts() }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "wave.3.right")
                                .font(.system(size: 22, weight: .bold))
                            Text("Add to Siri")
                                .font(.system(size: 20, weight: .bold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 58)
                        .background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add Siri shortcuts")

                    if let donationStatus {
                        Text(donationStatus)
                            .font(.footnote)
                            .foregroundColor(.black.opacity(0.7))
                            .multilineTextAlignment(.center)
                            .padding(.top, 6)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 40)
            }
            .background(bg.ignoresSafeArea())
            .navigationTitle("Shortcuts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(.black)
                        .accessibilityLabel("Close shortcuts")
                }
            }
        }
        .preferredColorScheme(.light)
    }

    private func donateShortcuts() async {
        do {
            try await ScanSpaceIntent().donate()
            try await ReadLabelIntent().donate()
            try await OpenTutorialIntent().donate()
            try await OpenSettingsIntent().donate()
            try await OpenShortcutsIntent().donate()
            await MainActor.run { donationStatus = "Done. Siri shortcuts are ready." }
        } catch {
            await MainActor.run { donationStatus = "Could not add shortcuts: \(error.localizedDescription)" }
        }
    }
}

// MARK: - AppIntents (CONNECTED)

struct ScanSpaceIntent: AppIntent {
    static var title: LocalizedStringResource { "Scan Space" }
    static var description: IntentDescription { "Switches PropelWalk to Scan Space mode." }
    static var openAppWhenRun: Bool { true }

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.setMode(.scanSpace)
        return .result()
    }
}

struct ReadLabelIntent: AppIntent {
    static var title: LocalizedStringResource { "Read Label" }
    static var description: IntentDescription { "Switches PropelWalk to Read Label mode." }
    static var openAppWhenRun: Bool { true }

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.setMode(.readLabel)
        return .result()
    }
}

struct OpenTutorialIntent: AppIntent {
    static var title: LocalizedStringResource { "Open Tutorial" }
    static var description: IntentDescription { "Opens the Tutorial page in PropelWalk." }
    static var openAppWhenRun: Bool { true }

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.open(.tutorial)
        return .result()
    }
}

struct OpenSettingsIntent: AppIntent {
    static var title: LocalizedStringResource { "Open Settings" }
    static var description: IntentDescription { "Opens the Settings page in PropelWalk." }
    static var openAppWhenRun: Bool { true }

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.open(.settings)
        return .result()
    }
}

struct OpenShortcutsIntent: AppIntent {
    static var title: LocalizedStringResource { "Open Shortcuts" }
    static var description: IntentDescription { "Opens the Shortcuts page in PropelWalk." }
    static var openAppWhenRun: Bool { true }

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.open(.shortcuts)
        return .result()
    }
}
