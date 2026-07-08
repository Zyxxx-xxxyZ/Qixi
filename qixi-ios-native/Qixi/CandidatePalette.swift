import SwiftUI

enum CandidatePalette {
  static let unknownAnalysisComponents = CandidateColorComponents(
    red: 0.470,
    green: 0.494,
    blue: 0.548,
    alpha: 0.58
  )
  static let unknownAnalysisColor = unknownAnalysisComponents.color

  static func color(deltaPercent k: Double) -> Color {
    components(deltaPercent: k).color
  }

  static func components(deltaPercent k: Double) -> CandidateColorComponents {
    let green = (0.145, 0.647, 0.416)
    let yellow = (0.996, 0.804, 0.180)
    let orange = (0.961, 0.455, 0.098)
    let red = (0.780, 0.180, 0.302)
    let blackRed = (0.230, 0.018, 0.045)

    if k >= -3.0 {
      let t = clamp((k + 3.0) / 3.0)
      return components(green, alpha: lerp(0.56, 0.92, t))
    }
    if k >= -5.0 {
      let t = clamp((-3.0 - k) / 2.0)
      let rgb = mix(green, yellow, t)
      return components(rgb, alpha: lerp(0.56, 0.50, t))
    }
    if k >= -10.0 {
      let t = clamp((-5.0 - k) / 5.0)
      let rgb = mix(yellow, orange, t)
      return components(rgb, alpha: lerp(0.50, 0.48, t))
    }
    if k >= -20.0 {
      let t = clamp((-10.0 - k) / 10.0)
      let rgb = mix(orange, red, t)
      return components(rgb, alpha: lerp(0.48, 0.82, t))
    }
    let t = clamp((-20.0 - k) / 30.0)
    let rgb = mix(red, blackRed, t)
    return components(rgb, alpha: lerp(0.82, 0.94, t))
  }

  private static func components(
    _ rgb: (Double, Double, Double),
    alpha: Double
  ) -> CandidateColorComponents {
    CandidateColorComponents(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: alpha)
  }

  private static func clamp(_ value: Double) -> Double {
    min(1.0, max(0.0, value))
  }

  private static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
    a + (b - a) * t
  }

  private static func mix(
    _ a: (Double, Double, Double),
    _ b: (Double, Double, Double),
    _ t: Double
  ) -> (Double, Double, Double) {
    (lerp(a.0, b.0, t), lerp(a.1, b.1, t), lerp(a.2, b.2, t))
  }
}
