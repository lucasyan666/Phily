import Foundation
import Vision
import CoreGraphics
import CoreImage

// MARK: - GridLine

/// A line segment in normalised image coordinates, (0,0) = top-left, (1,1) = bottom-right.
struct GridLine {
  let x1, y1, x2, y2: Float

  /// Minimum distance from point (px, py) to this segment.
  func distance(from px: Float, _ py: Float) -> Float {
    let dx = x2 - x1, dy = y2 - y1
    let lenSq = dx * dx + dy * dy
    if lenSq < 1e-10 { return hypotf(px - x1, py - y1) }
    let t = max(0, min(1, ((px - x1) * dx + (py - y1) * dy) / lenSq))
    return hypotf(px - (x1 + t * dx), py - (y1 + t * dy))
  }
}

// MARK: - EdgeAlignmentDetector

@available(iOS 14.0, *)
enum EdgeAlignmentDetector {

  // MARK: Public API

  /// Analyses a grayscale (Y-plane) image and returns a score in [0, 1]
  /// indicating how well detected edges align with the active composition grid.
  /// - Returns: fraction of grid lines with sufficient edge support, or 0 on failure.
  static func computeScore(yPlane: Data, width: Int, height: Int, mode: String) -> [[String: Double]] {
    let lines = gridLines(for: mode)
    guard !lines.isEmpty else { return [] }

    // Brightness guard: skip when frame is too dark (covered lens, low light).
    // Sum of all Y-plane bytes divided by pixel count gives average luma 0–255.
    let totalLuma = yPlane.reduce(0) { $0 + Int($1) }
    let avgLuma = totalLuma / max(1, width * height)
    guard avgLuma > 22 else { return [] }

    guard let cgImage = makeCGImage(from: yPlane, width: width, height: height) else {
      return []
    }

    // Run VNDetectContoursRequest on the downsampled grayscale frame.
    let request = VNDetectContoursRequest()
    request.contrastAdjustment = 2.0
    request.detectsDarkOnLight = true

    do {
      try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
    } catch {
      return []
    }

    guard let observation = request.results?.first as? VNContoursObservation else {
      return []
    }

    // Collect all normalised contour points.
    // Vision uses bottom-left origin; flip Y to match top-left grid coords.
    var points: [(Float, Float)] = []
    collect(observation.topLevelContours, into: &points)

    // Require a meaningful number of edge points to avoid false positives
    // on near-uniform or near-black frames.
    guard points.count > 40 else { return [] }

    // Stricter minPts threshold reduces random noise hits.
    let threshold: Float = 0.025
    let minPts = max(10, points.count / 18)

    var result: [[String: Double]] = []
    for line in lines {
      let count = points.filter { line.distance(from: $0.0, $0.1) < threshold }.count
      if count >= minPts {
        result.append([
          "x1": Double(line.x1), "y1": Double(line.y1),
          "x2": Double(line.x2), "y2": Double(line.y2),
        ])
      }
    }
    return result
  }

  // MARK: Private helpers

  private static func collect(_ contours: [VNContour], into points: inout [(Float, Float)]) {
    for contour in contours {
      for i in 0 ..< contour.pointCount {
        let pt = contour.normalizedPoints[i]
        // Flip Y: Vision (0,0) = bottom-left → top-left coordinate system.
        points.append((pt.x, 1.0 - pt.y))
      }
      collect(contour.childContours, into: &points)
    }
  }

  private static func makeCGImage(from data: Data, width: Int, height: Int) -> CGImage? {
    let colorSpace = CGColorSpaceCreateDeviceGray()
    guard let provider = CGDataProvider(data: data as CFData) else { return nil }
    return CGImage(
      width: width,
      height: height,
      bitsPerComponent: 8,
      bitsPerPixel: 8,
      bytesPerRow: width,
      space: colorSpace,
      bitmapInfo: CGBitmapInfo(rawValue: 0),
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    )
  }

  // MARK: Grid line definitions (normalised, top-left origin)

  // swiftlint:disable function_body_length
  private static func gridLines(for mode: String) -> [GridLine] {
    switch mode {

    case "ruleOfThirds":
      return [
        GridLine(x1: 1/3, y1: 0, x2: 1/3, y2: 1),
        GridLine(x1: 2/3, y1: 0, x2: 2/3, y2: 1),
        GridLine(x1: 0, y1: 1/3, x2: 1, y2: 1/3),
        GridLine(x1: 0, y1: 2/3, x2: 1, y2: 2/3),
      ]

    case "goldenSection":
      let phi: Float = 1.6180339887
      let w1 = 1 / (phi * phi), w2 = 1 / phi
      let h1 = 1 / (phi * phi), h2 = 1 / phi
      return [
        GridLine(x1: w1, y1: 0, x2: w1, y2: 1),
        GridLine(x1: w2, y1: 0, x2: w2, y2: 1),
        GridLine(x1: 0, y1: h1, x2: 1, y2: h1),
        GridLine(x1: 0, y1: h2, x2: 1, y2: h2),
      ]

    case "cross":
      return [
        GridLine(x1: 0.5, y1: 0, x2: 0.5, y2: 1),
        GridLine(x1: 0, y1: 0.5, x2: 1, y2: 0.5),
      ]

    case "goldenTriangles":
      return [
        GridLine(x1: 0, y1: 0, x2: 1, y2: 1),
        GridLine(x1: 1, y1: 0, x2: 0, y2: 1),
      ]

    case "harmoniousTriangles":
      return [
        GridLine(x1: 1, y1: 0, x2: 0, y2: 1),
        GridLine(x1: 0, y1: 0, x2: 1, y2: 1),
      ]

    case "diagonal":
      return [
        GridLine(x1: 1, y1: 0, x2: 0, y2: 0.55),
        GridLine(x1: 1, y1: 0, x2: 0.45, y2: 1),
      ]

    case "vArrangement":
      return [
        GridLine(x1: 0.5, y1: 0.78, x2: 0.08, y2: 0.12),
        GridLine(x1: 0.5, y1: 0.78, x2: 0.92, y2: 0.12),
      ]

    case "pyramid":
      return [
        GridLine(x1: 0.5, y1: 0.22, x2: 0.12, y2: 0.80),
        GridLine(x1: 0.5, y1: 0.22, x2: 0.88, y2: 0.80),
        GridLine(x1: 0.12, y1: 0.80, x2: 0.88, y2: 0.80),
      ]

    case "radial":
      return (0 ..< 8).map { i in
        let angle = Float(i) * Float.pi * 2 / 8
        let cx: Float = 0.5, cy: Float = 0.5, r: Float = 0.40
        return GridLine(
          x1: cx - cos(angle) * r, y1: cy - sin(angle) * r,
          x2: cx + cos(angle) * r, y2: cy + sin(angle) * r
        )
      }

    case "lArrangement":
      return [
        GridLine(x1: 0.32, y1: 0.20, x2: 0.32, y2: 0.82),
        GridLine(x1: 0.32, y1: 0.20, x2: 0.80, y2: 0.20),
      ]

    case "circular":
      // Approximate the circle with 16 short chord segments.
      let cx: Float = 0.5, cy: Float = 0.5, r: Float = 0.36
      return (0 ..< 16).map { i in
        let a0 = Float(i)     * Float.pi * 2 / 16
        let a1 = Float(i + 1) * Float.pi * 2 / 16
        return GridLine(
          x1: cx + cos(a0) * r, y1: cy + sin(a0) * r,
          x2: cx + cos(a1) * r, y2: cy + sin(a1) * r
        )
      }

    default:
      // Modes with complex curved geometry (fibonacciSpiral, compoundCurve,
      // spiralSection, focalMass) are not scored — return empty to skip analysis.
      return []
    }
  }
  // swiftlint:enable function_body_length
}
