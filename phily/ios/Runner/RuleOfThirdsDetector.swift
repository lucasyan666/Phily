import Foundation
import Vision
import CoreGraphics

// MARK: - AnimalDetector
//
// Cat/dog detection via Apple's Vision (VNRecognizeAnimalsRequest). Built into
// iOS — no added app size. Input is the already-upright, tightly-packed BGRA
// buffer prepared in Dart; results are normalised [0,1] with a top-left origin.

@available(iOS 13.0, *)
enum AnimalDetector {

  static func detect(bgra: Data, width: Int, height: Int) -> [[String: Any]] {
    guard let image = makeColorImage(from: bgra, width: width, height: height) else {
      return []
    }
    let req = VNRecognizeAnimalsRequest()
    // Bytes are already upright, so no rotation.
    guard (try? VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
            .perform([req])) != nil,
          let results = req.results as? [VNRecognizedObjectObservation]
    else { return [] }

    var out: [[String: Any]] = []
    for r in results {
      guard let top = r.labels.first,
            ["cat", "dog"].contains(top.identifier.lowercased())
      else { continue }
      let b = r.boundingBox // normalised, bottom-left origin
      out.append([
        "x": Double(b.minX),
        "y": Double(1.0 - b.maxY),   // flip Y → top-left origin
        "w": Double(b.width),
        "h": Double(b.height),
        "label": top.identifier.lowercased(),
        "confidence": Double(top.confidence),
      ])
    }
    return out
  }

  private static func makeColorImage(from data: Data, width: Int, height: Int) -> CGImage? {
    guard let provider = CGDataProvider(data: data as CFData) else { return nil }
    let bitmapInfo = CGBitmapInfo(rawValue:
      CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    return CGImage(
      width: width, height: height,
      bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: bitmapInfo,
      provider: provider, decode: nil,
      shouldInterpolate: false, intent: .defaultIntent
    )
  }
}
