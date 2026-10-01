import Flutter
import UIKit
import AVFoundation
import DeviceCheck

// MARK: - Incoming universal links

/// Universal links (the email sign-in link) handed to Dart.
///
/// The app runs on UIScene, so links arrive at the scene, not the app
/// delegate: in the connection options when a link launches the app, or as a
/// continued user activity while it runs. Registered as a scene delegate
/// through the plugin registrar, so `SceneDelegate` stays Flutter's own.
/// Links that land before Dart is listening wait in `pending` until Dart
/// calls `initialLink`.
final class IncomingLinks: NSObject, FlutterSceneLifeCycleDelegate {
  static let shared = IncomingLinks()

  private var channel: FlutterMethodChannel?
  private var pending: URL?

  /// Dart is listening: returns the link that launched the app, if any; later
  /// links go straight to the channel.
  func attach(_ channel: FlutterMethodChannel) -> String? {
    self.channel = channel
    defer { pending = nil }
    return pending?.absoluteString
  }

  private func receive(_ url: URL) {
    if let channel = channel {
      channel.invokeMethod("link", arguments: url.absoluteString)
    } else {
      pending = url
    }
  }

  // Explicit selectors: these are optional protocol methods, so a Swift name
  // that drifted from the Objective-C one would compile and never be called.
  @objc(scene:willConnectToSession:options:)
  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions?
  ) -> Bool {
    if let url = connectionOptions?.userActivities
      .first(where: { $0.activityType == NSUserActivityTypeBrowsingWeb })?
      .webpageURL {
      receive(url)
    }
    return false // let anything else registered see it too
  }

  @objc(scene:continueUserActivity:)
  func scene(_ scene: UIScene, continue userActivity: NSUserActivity) -> Bool {
    guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
          let url = userActivity.webpageURL else { return false }
    receive(url)
    return false
  }
}

// MARK: - Comparable convenience clamp
private extension Comparable {
  func clamped(to range: ClosedRange<Self>) -> Self {
    Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {

  private let sessionQueue = DispatchQueue(
    label: "com.phily.camera.sessionQueue",
    qos: .userInitiated
  )

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    NSLog("[Phily] ✅ native build with share_plus — plugins registered")

    // ── Camera utility channel ────────────────────────────────────────────────
    let cameraRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "PhilyCameraPlugin")!
    let cameraChannel = FlutterMethodChannel(
      name: "phily/camera",
      binaryMessenger: cameraRegistrar.messenger()
    )
    cameraChannel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "getUltraWideCameraId":    self?.handleGetUltraWideCameraId(result: result)
      case "getVirtualCameraId":      self?.handleGetVirtualCameraId(result: result)
      case "getFieldOfView":          self?.handleGetFieldOfView(result: result)
      case "detectAnimals":           self?.handleDetectAnimals(call: call, result: result)
      case "cropVerticalBand":        self?.handleCropVerticalBand(call: call, result: result)
      default: result(FlutterMethodNotImplemented)
      }
    }

    // ── Seamless zoom channel ─────────────────────────────────────────────────
    let zoomRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "PhilyZoomPlugin")!
    let zoomChannel = FlutterMethodChannel(
      name: "com.phily.camera/zoom",
      binaryMessenger: zoomRegistrar.messenger()
    )
    zoomChannel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "setZoom":    self?.handleSetZoom(call: call, result: result)
      case "rampZoom":   self?.handleRampZoom(call: call, result: result)
      case "getZoomInfo": self?.handleGetZoomInfo(result: result)
      default: result(FlutterMethodNotImplemented)
      }
    }

    // ── Haptics channel ───────────────────────────────────────────────────────
    HapticsEngine.shared.prepare()
    let hapticsRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "PhilyHapticsPlugin")!
    let hapticsChannel = FlutterMethodChannel(
      name: "phily/haptics",
      binaryMessenger: hapticsRegistrar.messenger()
    )
    hapticsChannel.setMethodCallHandler { call, result in
      let intensity = (call.arguments as? [String: Any])?["intensity"] as? Double ?? 1.0
      switch call.method {
      case "light":          HapticsEngine.shared.light()
      case "medium":         HapticsEngine.shared.medium()
      case "heavy":          HapticsEngine.shared.heavy()
      case "rigid":          HapticsEngine.shared.rigid()
      case "soft":           HapticsEngine.shared.soft()
      case "selection":      HapticsEngine.shared.selection()
      case "success":        HapticsEngine.shared.success()
      case "warning":        HapticsEngine.shared.warning()
      case "error":          HapticsEngine.shared.error()
      case "alignmentPing":  HapticsEngine.shared.alignmentPing(intensity: intensity)
      case "confirmPing":    HapticsEngine.shared.confirmPing()
      default: result(FlutterMethodNotImplemented); return
      }
      result(nil)
    }

    // ── Platform channel: backend config, DeviceCheck, incoming links ─────────
    let platformRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "PhilyPlatformPlugin")!
    let platformChannel = FlutterMethodChannel(
      name: "phily/platform",
      binaryMessenger: platformRegistrar.messenger()
    )
    platformRegistrar.addSceneDelegate(IncomingLinks.shared)
    platformChannel.setMethodCallHandler { call, result in
      switch call.method {
      // Asked before Firebase starts: without the plist, FirebaseApp.configure()
      // raises an Objective-C exception that would take the app down.
      case "hasFirebaseConfig":
        result(Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil)
      case "deviceCheckToken":
        AppDelegate.handleDeviceCheckToken(result: result)
      case "initialLink":
        result(IncomingLinks.shared.attach(platformChannel))
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  // MARK: - DeviceCheck (trial lock)

  /// A one-off token the server trades with Apple for this device's two
  /// DeviceCheck bits. Nil where DeviceCheck isn't supported (the Simulator).
  private static func handleDeviceCheckToken(result: @escaping FlutterResult) {
    guard DCDevice.current.isSupported else { result(nil); return }
    DCDevice.current.generateToken { data, _ in
      DispatchQueue.main.async { result(data?.base64EncodedString()) }
    }
  }

  // MARK: - Zoom helpers

  private func bestVirtualDevice() -> AVCaptureDevice? {
    var types: [AVCaptureDevice.DeviceType] = []
    if #available(iOS 13.0, *) {
      types = [
        .builtInTripleCamera,
        .builtInDualWideCamera,
        .builtInDualCamera,
        .builtInWideAngleCamera,
      ]
    } else {
      types = [.builtInDualCamera, .builtInWideAngleCamera]
    }
    return AVCaptureDevice.DiscoverySession(
      deviceTypes: types,
      mediaType: .video,
      position: .back
    ).devices.first
  }

  private func handleSetZoom(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard
      let args   = call.arguments as? [String: Any],
      let factor = args["factor"] as? Double
    else {
      result(FlutterError(code: "INVALID_ARGS", message: "factor required", details: nil))
      return
    }
    guard let device = bestVirtualDevice() else {
      result(FlutterError(code: "NO_DEVICE", message: "No virtual camera found", details: nil))
      return
    }
    sessionQueue.async {
      do {
        try device.lockForConfiguration()
        device.videoZoomFactor = CGFloat(factor).clamped(
          to: device.minAvailableVideoZoomFactor...device.maxAvailableVideoZoomFactor
        )
        device.unlockForConfiguration()
        DispatchQueue.main.async { result(nil) }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "LOCK_FAILED", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  private func handleRampZoom(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard
      let args   = call.arguments as? [String: Any],
      let factor = args["factor"] as? Double,
      let rate   = args["rate"]   as? Float
    else {
      result(FlutterError(code: "INVALID_ARGS", message: "factor and rate required", details: nil))
      return
    }
    guard let device = bestVirtualDevice() else {
      result(FlutterError(code: "NO_DEVICE", message: "No virtual camera found", details: nil))
      return
    }
    sessionQueue.async {
      do {
        try device.lockForConfiguration()
        device.ramp(
          toVideoZoomFactor: CGFloat(factor).clamped(
            to: device.minAvailableVideoZoomFactor...device.maxAvailableVideoZoomFactor
          ),
          withRate: rate
        )
        device.unlockForConfiguration()
        DispatchQueue.main.async { result(nil) }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "LOCK_FAILED", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  private func handleGetZoomInfo(result: @escaping FlutterResult) {
    guard let device = bestVirtualDevice() else {
      result(FlutterError(code: "NO_DEVICE", message: "No virtual camera found", details: nil))
      return
    }
    var switchoverFactors: [Double] = []
    if #available(iOS 14.0, *) {
      switchoverFactors = device.virtualDeviceSwitchOverVideoZoomFactors.map { $0.doubleValue }
    }
    result([
      "min":               Double(device.minAvailableVideoZoomFactor),
      "max":               min(Double(device.maxAvailableVideoZoomFactor), 25.0),
      "current":           Double(device.videoZoomFactor),
      "switchoverFactors": switchoverFactors,
    ])
  }

  // MARK: - cropVerticalBand (trim a capture to the framed viewport)

  /// Crops the JPEG at `path` to the on-screen composition band — the region
  /// between the top and bottom panels — and writes a new JPEG beside it.
  /// `topFrac`/`botFrac` are the fractions of the frame hidden behind those
  /// panels (the same insets the Dart overlays use). Runs off the main thread;
  /// returns the new path, or nil to keep the original (nothing to trim / a
  /// decode or write failure). Hardware-accelerated via CoreGraphics — no
  /// full-resolution bitmap is ever held in the Dart heap, so the preview
  /// doesn't hitch and the result lands almost immediately.
  private func handleCropVerticalBand(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard
      let args    = call.arguments as? [String: Any],
      let path    = args["path"]    as? String,
      let topFrac = args["topFrac"] as? Double,
      let botFrac = args["botFrac"] as? Double
    else {
      result(FlutterError(code: "INVALID_ARGS", message: "path, topFrac, botFrac required", details: nil))
      return
    }
    DispatchQueue.global(qos: .userInitiated).async {
      let out = AppDelegate.cropVerticalBand(path: path, topFrac: topFrac, botFrac: botFrac)
      DispatchQueue.main.async { result(out) }
    }
  }

  private static func cropVerticalBand(path: String, topFrac: Double, botFrac: Double) -> String? {
    // UIImage(contentsOfFile:) carries the file's EXIF orientation, and
    // draw(in:) renders it upright — so "top/bottom" are the edges the user
    // actually saw, regardless of how the sensor stored the pixels.
    guard let image = UIImage(contentsOfFile: path) else { return nil }
    let displayW = image.size.width
    let displayH = image.size.height
    guard displayW > 0, displayH > 0 else { return nil }

    let topPts = (CGFloat(topFrac) * displayH).rounded()
    let botPts = (CGFloat(botFrac) * displayH).rounded()
    let newH = displayH - topPts - botPts
    guard newH > 8, newH < displayH else { return nil } // nothing worth trimming

    let format = UIGraphicsImageRendererFormat.default()
    format.scale = image.scale     // preserve native pixel dimensions
    format.opaque = true
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: displayW, height: newH), format: format)
    let cropped = renderer.image { _ in
      // Shift the upright image up by the hidden top band; the canvas height
      // clips off the bottom band — leaving exactly the visible frame.
      image.draw(in: CGRect(x: 0, y: -topPts, width: displayW, height: displayH))
    }

    guard let data = cropped.jpegData(compressionQuality: 0.92) else { return nil }
    let dir = (path as NSString).deletingLastPathComponent
    let outPath = "\(dir)/phily_\(Int(Date().timeIntervalSince1970 * 1000)).jpg"
    do {
      try data.write(to: URL(fileURLWithPath: outPath), options: .atomic)
      return outPath
    } catch {
      return nil
    }
  }

  // MARK: - detectAnimals (cats/dogs via Vision)

  private func handleDetectAnimals(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard
      let args   = call.arguments as? [String: Any],
      let typed  = args["bgra"] as? FlutterStandardTypedData,
      let width  = args["width"]  as? Int,
      let height = args["height"] as? Int
    else {
      result(FlutterError(code: "INVALID_ARGS", message: "bgra, width, height required", details: nil))
      return
    }

    let data = typed.data
    DispatchQueue.global(qos: .userInitiated).async {
      var animals: [[String: Any]] = []
      if #available(iOS 13.0, *) {
        animals = AnimalDetector.detect(bgra: data, width: width, height: height)
      }
      DispatchQueue.main.async { result(animals) }
    }
  }

  /// The active back camera's field of view (degrees, along the sensor's long /
  /// horizontal axis). In portrait that long axis maps to the preview's vertical
  /// extent, so Dart uses this to project the gravity horizon's height.
  private func handleGetFieldOfView(result: @escaping FlutterResult) {
    let fov = bestVirtualDevice()?.activeFormat.videoFieldOfView ?? 0
    result(Double(fov))
  }

  private func handleGetVirtualCameraId(result: @escaping FlutterResult) {
    let session = AVCaptureDevice.DiscoverySession(
      deviceTypes: [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera],
      mediaType: .video,
      position: .back
    )
    result(session.devices.first?.uniqueID)
  }

  private func handleGetUltraWideCameraId(result: @escaping FlutterResult) {
    let session = AVCaptureDevice.DiscoverySession(
      deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera],
      mediaType: .video,
      position: .back
    )
    result(session.devices.first { $0.deviceType == .builtInUltraWideCamera }?.uniqueID)
  }
}
