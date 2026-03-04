//
//  FirstTimeHelpOverlay.swift
//  PropelWalk
//

import SwiftUI
import Foundation

private var isRunningInXcodePreview: Bool {
    ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
}

struct FirstTimeHelpOverlay: View {
    let text: String
    let onDismiss: () -> Void

    @State private var didStartSpeaking = false

    var body: some View {
        ZStack {
            // Dim background like iOS alert
            Color.black.opacity(0.35)
                .ignoresSafeArea()

            // Alert card
            VStack(spacing: 0) {

                // Text area
                ScrollView(showsIndicators: true) {
                    Text(text)
                        .font(.system(size: 18, weight: .regular))
                        .foregroundColor(.black)
                        .multilineTextAlignment(.leading)                 //  left aligned text
                        .padding(.horizontal, 18)
                        .padding(.vertical, 16)
                        .frame(maxWidth: .infinity, alignment: .leading) // left aligned frame
                }
                .frame(maxHeight: 520)
                .background(Color(white: 0.92))

                Divider()
                    .background(Color.black.opacity(0.35))

                // Blue OK button (text only) like system alert
                Button {
                    SpeechManager.shared.stop()
                    onDismiss()
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
        }
        .onAppear {
            // Do not auto-speak in Xcode Preview
            guard !isRunningInXcodePreview else { return }

            // Speak FULL text once (chunked)
            guard !didStartSpeaking else { return }
            didStartSpeaking = true

            SpeechManager.shared.stop()

            // Small delay helps on real devices when camera/audio just started
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                speakLongText(text)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Propel instructions")
        .accessibilityHint("Swipe to read. Double tap OK to continue.")
        .accessibilityAddTraits(.isModal)
    }

    // MARK: - Speak long text in chunks (prevents “only first sentence” issue)

    private func speakLongText(_ fullText: String) {
        let chunks = chunkHelpText(fullText)

        var delay: TimeInterval = 0

        for (index, chunk) in chunks.enumerated() {
            let words = max(1, chunk.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count)

            // Estimate duration so chunks don’t overlap.
            // ~2.0–2.3 words/sec is a reasonable spoken pace.
            let estimatedDuration = max(2.2, Double(words) / 2.1)
            let gap: TimeInterval = 0.35

            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                // First chunk is urgent so it starts immediately
                if index == 0 {
                    SpeechManager.shared.speak(chunk, rate: 0.50, priority: .urgent)
                } else {
                    SpeechManager.shared.speak(chunk, rate: 0.50, priority: .normal)
                }
            }

            delay += estimatedDuration + gap
        }
    }

    private func chunkHelpText(_ text: String) -> [String] {
        // Split by blank lines first (paragraphs)
        let paragraphs = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // Ensure chunks are not too large (device-friendly)
        var result: [String] = []
        var current = ""

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { result.append(trimmed) }
            current = ""
        }

        for p in paragraphs {
            if current.isEmpty {
                current = p
            } else {
                let candidate = current + "\n\n" + p

                // Keep chunks under ~450 characters so iOS doesn't cut / lag
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

// MARK: - Preview

#Preview {
    ZStack {
        // Fake “camera” background
        LinearGradient(
            colors: [.black, .gray],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()

        FirstTimeHelpOverlay(
            text: """
Welcome to Propel!

Propel supports safer movement and quick label reading. It does not replace a cane or a guide dog.
Built with input from blind users and blind communities.

START HERE
1) Turn your volume up.
2) Hold the phone upright (portrait), at chest height.
3) Point the camera forward in the direction you are walking.
4) Move slowly.

SCAN SPACE (walking help)
• Keep the phone chest-high and facing forward.
• Listen for:
  - Clear = path seems open
  - Caution = slow down and adjust
  - Stop = very close, stop and change direction

VIBRATION (haptics)
• Light = far
• Medium = near
• Strong / fast = stop

READ LABEL (text reading)
1) Hold the phone 15–30 cm from the label.
2) Put the label in the center of the screen.
3) Hold steady for 1–2 seconds.
Tip: if it reads the wrong thing, move slightly closer or tilt to reduce glare.

SWITCH MODES
• Swipe RIGHT = Read Label
• Swipe LEFT = Scan Space
• Or use the bottom mode control

The MENU BUTTON is at the top left. It opens Settings, Tutorial, and Siri Shortcuts.
click ok to continue
""",
            onDismiss: { print("Dismiss tapped") }
        )
    }
}
