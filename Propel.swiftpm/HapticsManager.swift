//
//  HapticsManager.swift
//  Propel
//
//  Better, calmer haptics for blind users
//  Fixes included:
//  - Cooldowns so haptics don’t feel “weird / too much”
//  - Only repeats at stable intervals per severity
//  - Still supports CoreHaptics + UIKit fallback
//  - Keeps your existing API (tap/success/warning/playTransition/playObstaclePattern/stop)
//  -  Adds user toggle: isEnabled
//

import Foundation
import CoreHaptics

#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class HapticsManager: ObservableObject {

    static let shared = HapticsManager()
    private init() {}

    private var engine: CHHapticEngine?
    private var supportsCoreHaptics = false
    private var didAttemptSetup = false

    @Published var isEngineRunning = false

    // NEW: User setting toggle (bind this in Settings)
    @Published var isEnabled: Bool = true

    // MARK: - Anti-spam cooldowns (NEW)

    private var lastPulseAt: Date = .distantPast
    private var lastSeverity: ObstacleSeverity? = nil

    /// Minimum time between pulses for each severity
    private func cooldown(for severity: ObstacleSeverity) -> TimeInterval {
        switch severity {
        case .clear:
            return 2.0
        case .far:
            return 1.4
        case .near:
            return 0.9
        case .veryClose:
            return 0.45
        case .uncertain:
            return 1.6
        }
    }

    #if canImport(UIKit)
    private let impactLight = UIImpactFeedbackGenerator(style: .light)
    private let impactMedium = UIImpactFeedbackGenerator(style: .medium)
    private let impactHeavy = UIImpactFeedbackGenerator(style: .heavy)
    private let notifGen = UINotificationFeedbackGenerator()
    #endif

    // MARK: - Setup

    func setup() {
        didAttemptSetup = true
        supportsCoreHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics

        #if canImport(UIKit)
        impactLight.prepare()
        impactMedium.prepare()
        impactHeavy.prepare()
        notifGen.prepare()
        #endif

        guard supportsCoreHaptics else {
            isEngineRunning = false
            engine = nil
            return
        }

        do {
            // Stop any previous engine cleanly
            engine?.stop()

            let newEngine = try CHHapticEngine()
            engine = newEngine

            try newEngine.start()
            isEngineRunning = true

            newEngine.resetHandler = { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    do {
                        try self.engine?.start()
                        self.isEngineRunning = true
                    } catch {
                        self.isEngineRunning = false
                        print("HapticsManager: engine restart failed:", error)
                    }
                }
            }

            newEngine.stoppedHandler = { [weak self] reason in
                Task { @MainActor in
                    self?.isEngineRunning = false
                }
                print("HapticsManager: engine stopped:", reason)
            }

        } catch {
            supportsCoreHaptics = false
            isEngineRunning = false
            engine = nil
            print("HapticsManager: create engine failed:", error)
        }
    }

    private func setupIfNeeded() {
        //  Don’t waste work if user turned haptics off
        guard isEnabled else { return }

        if !didAttemptSetup {
            setup()
            return
        }
        if supportsCoreHaptics && engine == nil {
            setup()
        }
    }

    // MARK: - Simple feedback

    func tap() {
        guard isEnabled else { return }
        setupIfNeeded()
        #if canImport(UIKit)
        impactMedium.prepare()
        impactMedium.impactOccurred()
        #endif
    }

    func success() {
        guard isEnabled else { return }
        setupIfNeeded()
        #if canImport(UIKit)
        notifGen.prepare()
        notifGen.notificationOccurred(.success)
        #endif
    }

    func warning() {
        guard isEnabled else { return }
        setupIfNeeded()
        #if canImport(UIKit)
        notifGen.prepare()
        notifGen.notificationOccurred(.warning)
        #endif
    }

    func playTransition() {
        guard isEnabled else { return }
        setupIfNeeded()

        guard supportsCoreHaptics, let engine else {
            #if canImport(UIKit)
            impactMedium.prepare()
            impactMedium.impactOccurred()
            #endif
            return
        }

        do {
            let events: [CHHapticEvent] = [
                CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [
                        .init(parameterID: .hapticIntensity, value: 0.6),
                        .init(parameterID: .hapticSharpness, value: 0.4)
                    ],
                    relativeTime: 0
                )
            ]
            let pattern = try CHHapticPattern(events: events, parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            #if canImport(UIKit)
            impactMedium.prepare()
            impactMedium.impactOccurred()
            #endif
        }
    }

    // MARK: - Obstacle haptics (calmed down)

    /// Call this whenever severity updates. It will:
    /// - Pulse immediately on severity change
    /// - Otherwise pulse only after the cooldown interval
    func playObstaclePattern(severity: ObstacleSeverity) {
        guard isEnabled else { return }
        setupIfNeeded()

        let now = Date()

        // If severity changed, allow immediate pulse
        if lastSeverity != severity {
            lastSeverity = severity
            lastPulseAt = .distantPast
        }

        //  Respect cooldown (prevents “weird / too much” buzzing)
        let cd = cooldown(for: severity)
        if now.timeIntervalSince(lastPulseAt) < cd {
            return
        }
        lastPulseAt = now

        guard supportsCoreHaptics, let engine else {
            playUIKitFallback(severity: severity)
            return
        }

        do {
            let pattern = try makePattern(severity: severity)
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            playUIKitFallback(severity: severity)
        }
    }

    // MARK: - Patterns

    private func makePattern(severity: ObstacleSeverity) throws -> CHHapticPattern {
        switch severity {

        case .clear:
            // One soft pulse (rarely, due to cooldown)
            return try CHHapticPattern(events: [
                CHHapticEvent(eventType: .hapticTransient,
                              parameters: [.init(parameterID: .hapticIntensity, value: 0.18)],
                              relativeTime: 0)
            ], parameters: [])

        case .far:
            return try CHHapticPattern(events: [
                CHHapticEvent(eventType: .hapticTransient,
                              parameters: [.init(parameterID: .hapticIntensity, value: 0.38)],
                              relativeTime: 0)
            ], parameters: [])

        case .near:
            // Two pulses, but calmer than before
            return try CHHapticPattern(events: [
                CHHapticEvent(eventType: .hapticTransient,
                              parameters: [.init(parameterID: .hapticIntensity, value: 0.62)],
                              relativeTime: 0),
                CHHapticEvent(eventType: .hapticTransient,
                              parameters: [.init(parameterID: .hapticIntensity, value: 0.52)],
                              relativeTime: 0.16)
            ], parameters: [])

        case .veryClose:
            // Short urgent burst
            var events: [CHHapticEvent] = []
            for i in 0..<3 {
                events.append(
                    CHHapticEvent(eventType: .hapticTransient,
                                  parameters: [.init(parameterID: .hapticIntensity, value: 0.90)],
                                  relativeTime: Double(i) * 0.10)
                )
            }
            return try CHHapticPattern(events: events, parameters: [])

        case .uncertain:
            // Gentle double tap (rarely)
            return try CHHapticPattern(events: [
                CHHapticEvent(eventType: .hapticTransient,
                              parameters: [.init(parameterID: .hapticIntensity, value: 0.28)],
                              relativeTime: 0),
                CHHapticEvent(eventType: .hapticTransient,
                              parameters: [.init(parameterID: .hapticIntensity, value: 0.28)],
                              relativeTime: 0.22)
            ], parameters: [])
        }
    }

    // MARK: - UIKit fallback

    private func playUIKitFallback(severity: ObstacleSeverity) {
        #if !canImport(UIKit)
        return
        #else
        switch severity {
        case .clear:
            impactLight.prepare()
            impactLight.impactOccurred()

        case .far:
            impactLight.prepare()
            impactLight.impactOccurred()

        case .near:
            impactMedium.prepare()
            impactMedium.impactOccurred()

        case .veryClose:
            impactHeavy.prepare()
            impactHeavy.impactOccurred()

        case .uncertain:
            impactLight.prepare()
            impactLight.impactOccurred()
        }
        #endif
    }

    func stop() {
        // Stop repeating engine
        engine?.stop()
        isEngineRunning = false

        // Reset cooldown tracking
        lastPulseAt = .distantPast
        lastSeverity = nil
    }
}
