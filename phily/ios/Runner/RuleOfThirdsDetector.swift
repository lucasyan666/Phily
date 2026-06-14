import Foundation
import Vision
import CoreGraphics

// MARK: - RuleOfThirdsDetector
//
// Detection hierarchy (run face + animal in one handler pass for speed):
//   1. Human face   → VNDetectFaceRectanglesRequest   → eye-level key point
//   2. Cat / Dog    → VNRecognizeAnimalsRequest        → upper-body (head) key point
//   3. High-contrast object → VNGenerateObjectnessBasedSaliencyImageRequest
//
// Highlight shape: smooth ellipse (36-segment oval) — looks like a camera focus ring.
// Using an ellipse instead of a bounding-box rectangle makes the glow hug the
// subject and look intentional rather than mechanical.

@available(iOS 14.0, *)
final class RuleOfThirdsDetector {

  static let shared = RuleOfThirdsDetector()
  private init() {}

  // ── Rule-of-Thirds power points (normalised, top-left origin) ───────────────
  private static let powerPoints: [(x: Float, y: Float)] = [
    (1/3, 1/3), (2/3, 1/3),
    (1/3, 2/3), (2/3, 2/3),
  ]

  // How close the subject key-point must be to a power point.
  // 0.14 = 14 % of the shorter screen dimension — tight enough to feel intentional.
  private let radius: Float    = 0.14
  private let gateFrames       = 2      // consecutive aligned frames before haptic
  private let emaAlpha: CGFloat = 0.35  // bbox / key-point smoothing

  // ── Mutable state ─────────────────────────────────────────────────────────────
  private var smoothedBbox:  CGRect?
  private var smoothedKeyPt: CGPoint?
  private var consecutiveAligned = 0
  private var lastPowerPointIdx:  Int?
  private var hapticFired         = false

  // Cached orientation: once we learn which one detects faces on this device,
  // reuse it so we run face detection ONCE per frame instead of up to 5×.
  // This is the single biggest latency win — slashes per-frame tracking lag.
  private var cachedOrientation: CGImagePropertyOrientation?

  // MARK: - Public

  func analyze(pixels: Data, width: Int, height: Int, format: String = "gray",
               orientation: CGImagePropertyOrientation = .right) -> [String: Any] {
    let image = (format == "bgra")
      ? makeColorImage(from: pixels, width: width, height: height)
      : makeImage(from: pixels, width: width, height: height)
    guard let image else { return miss() }

    // ── Determine orientation ─────────────────────────────────────────────────
    // Once cached, run face detection exactly once with the known orientation.
    // Before that, probe candidates until one finds a face, then cache it.
    let candidates: [CGImagePropertyOrientation] =
      cachedOrientation.map { [$0] } ?? [orientation, .up, .left, .down, .right]
    var faces: [VNFaceObservation] = []
    var usedOrientation = cachedOrientation ?? orientation

    for ori in candidates {
      let req = VNDetectFaceRectanglesRequest()
      if #available(iOS 15.0, *) { req.revision = VNDetectFaceRectanglesRequestRevision3 }
      try? VNImageRequestHandler(cgImage: image, orientation: ori, options: [:]).perform([req])
      let found = (req.results as? [VNFaceObservation]) ?? []
      if !found.isEmpty {
        faces = found
        usedOrientation = ori
        cachedOrientation = ori   // lock it in — no more probing
        break
      }
    }

    // Animals use the orientation that worked for faces (or the default).
    let animalReq = VNRecognizeAnimalsRequest()
    try? VNImageRequestHandler(cgImage: image, orientation: usedOrientation, options: [:])
      .perform([animalReq])

    // ── Collect ALL faces ─────────────────────────────────────────────────────
    var detections: [[String: Any]] = []

    for f in faces {
      let r = flip(f.boundingBox)
      detections.append([
        "x": Double(r.minX), "y": Double(r.minY),
        "w": Double(r.width), "h": Double(r.height),
        "label": "face", "confidence": 1.0,
      ])
    }

    // ── Collect ALL cats / dogs (head region = upper portion of body bbox) ────
    let animals = (animalReq.results as? [VNRecognizedObjectObservation]) ?? []
    for a in animals {
      guard a.labels.contains(where: { ["cat","dog"].contains($0.identifier.lowercased()) })
      else { continue }
      let body = a.boundingBox
      let head = CGRect(
        x:      body.minX + body.width  * 0.10,
        y:      body.minY + body.height * 0.55,
        width:  body.width  * 0.80,
        height: body.height * 0.45
      )
      let r = flip(head)
      let label = a.labels.first?.identifier.lowercased() ?? "animal"
      detections.append([
        "x": Double(r.minX), "y": Double(r.minY),
        "w": Double(r.width), "h": Double(r.height),
        "label": label, "confidence": Double(a.confidence),
      ])
    }

    NSLog("[Detector] faces=\(faces.count) animals=\(animals.count) → boxes=\(detections.count) ori=\(usedOrientation.rawValue)")

    // For the None-mode test we only need raw detection boxes.
    return [
      "aligned": false,
      "haptic":  false,
      "score":   0.0,
      "edgeSegments": [[String: Double]](),
      "detections":   detections,
    ]
  }

  // MARK: - Core processing

  /// - Parameter keyYAboveC: fraction of bbox height to shift key point above centre (0 = centre).
  private func process(
    visionBbox:    CGRect,
    keyYAboveC:    Double,
    ellipseScaleX: Double,
    ellipseScaleY: Double,
    label: String = "obj",
    confidence: Double = 1.0
  ) -> [String: Any] {

    let rawBbox = flip(visionBbox)
    let bbox    = smooth(rawBbox)

    // Key point: composition is judged at eye level (face) or subject centre.
    let rawKey = CGPoint(x: rawBbox.midX, y: rawBbox.midY - rawBbox.height * keyYAboveC)
    let keyPt  = smoothPoint(rawKey)

    // ── Alignment check ───────────────────────────────────────────────────────
    let kx = Float(keyPt.x), ky = Float(keyPt.y)
    var bestIdx:   Int?  = nil
    var bestScore: Float = 0

    for (i, pt) in Self.powerPoints.enumerated() {
      let dist   = hypotf(kx - pt.x, ky - pt.y)
      let inside = bbox.contains(CGPoint(x: Double(pt.x), y: Double(pt.y)))
      guard dist < radius || inside else { continue }
      let score: Float = inside && dist >= radius
        ? 0.35
        : max(0, 1.0 - dist / radius)
      if score > bestScore { bestScore = score; bestIdx = i }
    }

    // ── Temporal gate ─────────────────────────────────────────────────────────
    var fireHaptic = false
    if let idx = bestIdx {
      if idx == lastPowerPointIdx {
        consecutiveAligned += 1
      } else {
        consecutiveAligned = 1; lastPowerPointIdx = idx; hapticFired = false
      }
      if consecutiveAligned >= gateFrames && !hapticFired {
        fireHaptic = true; hapticFired = true
      }
    } else {
      decay()
    }

    let confirmed = bestIdx != nil && consecutiveAligned >= gateFrames

    // ── Ellipse outline ───────────────────────────────────────────────────────
    // A smooth oval hugs the subject better than a rectangle and matches the
    // camera-focus-ring visual language. 36 segments = visually smooth arc.
    let edges: [[String: Double]] = confirmed ? ellipse(
      cx: Double(bbox.midX),
      cy: Double(bbox.midY),
      rx: bbox.width  * ellipseScaleX,
      ry: bbox.height * ellipseScaleY
    ) : []

    var out: [String: Any] = [
      "aligned":      confirmed,
      "haptic":       fireHaptic,
      "score":        Double(bestScore),
      "edgeSegments": edges,
      "bbox": ["x": Double(bbox.minX), "y": Double(bbox.minY),
               "w": Double(bbox.width), "h": Double(bbox.height)],
    ]
    // Include a simple detection entry so the Dart side can render object-aware
    // overlays (label, bbox, confidence). Coordinates are normalised [0..1].
    out["detections"] = [[
      "x": Double(bbox.minX), "y": Double(bbox.minY),
      "w": Double(bbox.width), "h": Double(bbox.height),
      "label": label, "confidence": confidence
    ]]
    if let idx = bestIdx {
      let pt = Self.powerPoints[idx]
      out["intersectionIndex"] = idx
      out["intersectionPoint"] = ["x": Double(pt.x), "y": Double(pt.y)]
    }
    return out
  }

  // MARK: - Ellipse geometry

  private func ellipse(cx: Double, cy: Double, rx: Double, ry: Double) -> [[String: Double]] {
    let n = 36
    return (0..<n).map { i in
      let a0 = Double(i)     / Double(n) * 2 * .pi
      let a1 = Double(i + 1) / Double(n) * 2 * .pi
      return ["x1": cx + rx * cos(a0), "y1": cy + ry * sin(a0),
              "x2": cx + rx * cos(a1), "y2": cy + ry * sin(a1)]
    }
  }

  // MARK: - Helpers

  private func smooth(_ r: CGRect) -> CGRect {
    guard let p = smoothedBbox else { smoothedBbox = r; return r }
    let a = emaAlpha
    let s = CGRect(
      x: p.minX*(1-a)+r.minX*a, y: p.minY*(1-a)+r.minY*a,
      width: p.width*(1-a)+r.width*a, height: p.height*(1-a)+r.height*a
    )
    smoothedBbox = s; return s
  }

  private func smoothPoint(_ r: CGPoint) -> CGPoint {
    guard let p = smoothedKeyPt else { smoothedKeyPt = r; return r }
    let a = emaAlpha
    let s = CGPoint(x: p.x*(1-a)+r.x*a, y: p.y*(1-a)+r.y*a)
    smoothedKeyPt = s; return s
  }

  private func decay() {
    if consecutiveAligned > 0 { consecutiveAligned -= 1 }
    if consecutiveAligned == 0 {
      lastPowerPointIdx = nil; hapticFired = false
      smoothedBbox = nil; smoothedKeyPt = nil
    }
  }

  private func miss() -> [String: Any] {
    ["aligned": false, "haptic": false, "score": 0.0,
     "edgeSegments": [[String: Double]]()]
  }

  private func flip(_ vb: CGRect) -> CGRect {
    CGRect(x: vb.minX, y: 1.0 - vb.maxY, width: vb.width, height: vb.height)
  }

  private func makeImage(from data: Data, width: Int, height: Int) -> CGImage? {
    guard let provider = CGDataProvider(data: data as CFData) else { return nil }
    return CGImage(
      width: width, height: height,
      bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
      space: CGColorSpaceCreateDeviceGray(),
      bitmapInfo: CGBitmapInfo(rawValue: 0),
      provider: provider, decode: nil,
      shouldInterpolate: false, intent: .defaultIntent
    )
  }

  /// Build a CGImage from tightly-packed BGRA8888 bytes (bytesPerRow = width*4).
  /// byteOrder32Little + premultipliedFirst is the correct combination for BGRA.
  private func makeColorImage(from data: Data, width: Int, height: Int) -> CGImage? {
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

// MARK: - HorizonDetector
//
// Estimates the scene horizon as the straight line that best separates the frame
// into a brighter region (sky) and a darker region (ground / sea). Unlike
// VNDetectHorizonRequest — which only reports a roll *angle* for near-level shots
// and carries no position — this returns BOTH the line's angle AND a point on it,
// and works across the full in-quadrant tilt range. Input is the already-upright,
// downsampled, tightly-packed BGRA buffer prepared in Dart.

@available(iOS 13.0, *)
enum HorizonDetector {

  /// Returns `["angle": radians, "x": nx, "y": ny, "strength": contrast]` where
  /// (nx, ny) is a normalised point on the horizon line (top-left origin) and the
  /// angle is the line's roll (0 = level, +ve = right-side-down in image space),
  /// or nil when no sufficiently strong brightness edge is present.
  static func detect(bgra: Data, width: Int, height: Int) -> [String: Any]? {
    guard width >= 16, height >= 16 else { return nil }

    // ── Downsample to tiny luma + "blueness" grids (≈64px on the long side) ────
    // Blueness (B − (R+G)/2) separates sky from sea/sand where the two have
    // similar brightness but different colour — luma alone misses those horizons.
    let target = 64
    let step = max(1, max(width, height) / target)
    let gw = width / step
    let gh = height / step
    guard gw >= 8, gh >= 8 else { return nil }

    var lum = [Float](repeating: 0, count: gw * gh)
    var blue = [Float](repeating: 0, count: gw * gh)
    bgra.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
      let p = raw.bindMemory(to: UInt8.self)
      let rowStride = width * 4
      for gy in 0..<gh {
        let rowBase = gy * step * rowStride
        for gx in 0..<gw {
          let i = rowBase + gx * step * 4
          let b = Float(p[i]), g = Float(p[i + 1]), r = Float(p[i + 2])
          let idx = gy * gw + gx
          lum[idx] = 0.114 * b + 0.587 * g + 0.299 * r   // Rec.601 luma
          blue[idx] = b - 0.5 * (r + g)                   // blueness
        }
      }
    }

    let cx = Float(gw) * 0.5
    let cy = Float(gh) * 0.5
    let R = (Float(gw) + Float(gh)) * 0.5      // half-diagonal-ish offset span
    let binCount = Int(2 * R) + 2
    let minSupport = Float(gw * gh) * 0.12     // each side must hold ≥12% of pixels

    var lumSum = [Float](repeating: 0, count: binCount)
    var blueSum = [Float](repeating: 0, count: binCount)
    var cnt = [Float](repeating: 0, count: binCount)

    // Score one candidate angle = its strongest split. Blends the luma step
    // (hard horizons) with a blueness step (sky vs sea/sand) and nudges toward
    // the brighter band being on top, as the sky usually is.
    func evaluate(_ th: Float) -> (score: Float, offset: Float) {
      let nx = -sin(th), ny = cos(th)          // unit normal to the line
      for i in 0..<binCount { lumSum[i] = 0; blueSum[i] = 0; cnt[i] = 0 }
      for gy in 0..<gh {
        let fy = Float(gy) - cy
        for gx in 0..<gw {
          let t = (Float(gx) - cx) * nx + fy * ny   // signed perpendicular offset
          let bin = Int(t + R)
          if bin < 0 || bin >= binCount { continue }
          let idx = gy * gw + gx
          lumSum[bin] += lum[idx]
          blueSum[bin] += blue[idx]
          cnt[bin] += 1
        }
      }
      var totLum: Float = 0, totBlue: Float = 0, totCnt: Float = 0
      for i in 0..<binCount { totLum += lumSum[i]; totBlue += blueSum[i]; totCnt += cnt[i] }

      var bestS: Float = 0, bestOff: Float = 0
      var lumL: Float = 0, blueL: Float = 0, cntL: Float = 0
      for k in 0..<binCount {
        lumL += lumSum[k]; blueL += blueSum[k]; cntL += cnt[k]
        let cntR = totCnt - cntL
        if cntL < minSupport || cntR < minSupport { continue }
        let topLum = lumL / cntL, botLum = (totLum - lumL) / cntR
        let topBlue = blueL / cntL, botBlue = (totBlue - blueL) / cntR
        var s = abs(topLum - botLum) + 0.7 * abs(topBlue - botBlue)
        if topLum > botLum { s *= 1.12 }   // prefer brighter (sky) band on top
        if s > bestS { bestS = s; bestOff = Float(k) + 0.5 - R }
      }
      return (bestS, bestOff)
    }

    // Coarse sweep (5°) across the tilt range, then refine ±4° at 1° steps so the
    // result isn't quantised to 5° — which otherwise leaves a level horizon
    // visibly tilted.
    var best: (score: Float, angle: Float, offset: Float) = (0, 0, 0)
    var deg: Float = -62
    while deg <= 62 {
      let r = evaluate(deg * .pi / 180)
      if r.score > best.score { best = (r.score, deg * .pi / 180, r.offset) }
      deg += 5
    }
    let coarse = best.angle * 180 / .pi
    var rdeg = coarse - 4
    while rdeg <= coarse + 4 {
      let r = evaluate(rdeg * .pi / 180)
      if r.score > best.score { best = (r.score, rdeg * .pi / 180, r.offset) }
      rdeg += 1
    }

    // Need a clear step to even consider it a horizon (Dart adds a confidence +
    // temporal-stability gate on top).
    guard best.score >= 14 else { return nil }

    let nx = -sin(best.angle), ny = cos(best.angle)
    let px = cx + best.offset * nx
    let py = cy + best.offset * ny
    return [
      "angle":    Double(best.angle),
      "x":        Double(px / Float(gw)),   // normalised, top-left origin
      "y":        Double(py / Float(gh)),
      "strength": Double(best.score),
    ]
  }
}
