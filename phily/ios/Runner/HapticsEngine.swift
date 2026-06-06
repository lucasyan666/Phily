import UIKit
import CoreHaptics

/// Centralised haptic feedback for Phily.
/// Exposed to Flutter via the "phily/haptics" MethodChannel.
/// Call `HapticsEngine.shared.prepare()` once on app launch.
final class HapticsEngine {

  static let shared = HapticsEngine()
  private var engine: CHHapticEngine?

  private init() {}

  // MARK: - Lifecycle

  /// Pre-warms the CoreHaptics engine so the first call has no latency.
  func prepare() {
    guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
    do {
      engine = try CHHapticEngine()
      engine?.isAutoShutdownEnabled = true
      engine?.stoppedHandler = { [weak self] _ in
        try? self?.engine?.start()
      }
      try engine?.start()
    } catch {
      engine = nil
    }
  }

  // MARK: - Simple impacts (UIKit fallback always works)

  func light()     { impact(.light) }
  func medium()    { impact(.medium) }
  func heavy()     { impact(.heavy) }
  func rigid()     { impact(.rigid) }
  func soft()      { impact(.soft) }
  func selection() { UISelectionFeedbackGenerator().selectionChanged() }
  func success()   { UINotificationFeedbackGenerator().notificationOccurred(.success) }
  func warning()   { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
  func error()     { UINotificationFeedbackGenerator().notificationOccurred(.error) }

  private func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle, intensity: CGFloat = 1.0) {
    let g = UIImpactFeedbackGenerator(style: style)
    g.prepare()
    g.impactOccurred(intensity: intensity)
  }

  // MARK: - Custom CoreHaptics patterns

  /// Sharp tap + soft echo — used when a composition line aligns.
  /// `intensity` in [0, 1]; falls back to a UIKit medium impact on older hardware.
  func alignmentPing(intensity: Double = 1.0) {
    guard CHHapticEngine.capabilitiesForHardware().supportsHaptics,
          let engine else {
      impact(.medium, intensity: CGFloat(intensity))
      return
    }

    let i = Float(intensity.clamped(to: 0...1))
    let events: [CHHapticEvent] = [
      // Primary sharp tap
      CHHapticEvent(
        eventType: .hapticTransient,
        parameters: [
          CHHapticEventParameter(parameterID: .hapticIntensity, value: i),
          CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.85),
        ],
        relativeTime: 0
      ),
      // Soft resonance echo at 80 ms
      CHHapticEvent(
        eventType: .hapticTransient,
        parameters: [
          CHHapticEventParameter(parameterID: .hapticIntensity, value: i * 0.35),
          CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.20),
        ],
        relativeTime: 0.08
      ),
    ]

    play(events: events, engine: engine)
  }

  /// Double-tap pattern — used when composition alignment is strong / confirmed.
  func confirmPing() {
    guard CHHapticEngine.capabilitiesForHardware().supportsHaptics,
          let engine else {
      impact(.medium)
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { self.impact(.medium) }
      return
    }

    let events: [CHHapticEvent] = [
      CHHapticEvent(
        eventType: .hapticTransient,
        parameters: [
          CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.8),
          CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.7),
        ],
        relativeTime: 0
      ),
      CHHapticEvent(
        eventType: .hapticTransient,
        parameters: [
          CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
          CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.9),
        ],
        relativeTime: 0.12
      ),
    ]

    play(events: events, engine: engine)
  }

  // MARK: - Private

  private func play(events: [CHHapticEvent], engine: CHHapticEngine) {
    do {
      let pattern = try CHHapticPattern(events: events, parameters: [])
      let player  = try engine.makePlayer(with: pattern)
      try player.start(atTime: CHHapticTimeImmediate)
    } catch {
      // CoreHaptics failed — silent fallback (UIKit calls already used above).
    }
  }
}

// MARK: - Comparable clamp (local to this file)

private extension Comparable {
  func clamped(to range: ClosedRange<Self>) -> Self {
    Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
  }
}
