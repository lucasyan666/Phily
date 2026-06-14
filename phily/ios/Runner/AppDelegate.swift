import Flutter
import UIKit
import AVFoundation

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
      case "analyzeRuleOfThirds":     self?.handleAnalyzeRuleOfThirds(call: call, result: result)
      case "detectAnimals":           self?.handleDetectAnimals(call: call, result: result)
      case "detectHorizon":           self?.handleDetectHorizon(call: call, result: result)
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

  // MARK: - analyzeRuleOfThirds

  private func handleAnalyzeRuleOfThirds(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard
      let args   = call.arguments as? [String: Any],
      let width  = args["width"]  as? Int,
      let height = args["height"] as? Int
    else {
      result(FlutterError(code: "INVALID_ARGS", message: "width, height required", details: nil))
      return
    }

    let format = (args["format"] as? String) ?? "gray"
    let typed  = (args["bgra"] as? FlutterStandardTypedData)
              ?? (args["yPlane"] as? FlutterStandardTypedData)
    guard let typed else {
      result(FlutterError(code: "INVALID_ARGS", message: "bgra or yPlane required", details: nil))
      return
    }

    let data = typed.data
    DispatchQueue.global(qos: .userInitiated).async {
      var analysis: [String: Any] = ["aligned": false, "haptic": false]
      if #available(iOS 14.0, *) {
        analysis = RuleOfThirdsDetector.shared.analyze(
          pixels: data, width: width, height: height, format: format
        )
      }
      DispatchQueue.main.async { result(analysis) }
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

  // MARK: - detectHorizon (scene horizon angle via Vision)

  private func handleDetectHorizon(call: FlutterMethodCall, result: @escaping FlutterResult) {
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
    // Optional crop (normalised) limiting analysis to the camera-visible band.
    let cx0 = (args["cropX0"] as? Double) ?? 0
    let cy0 = (args["cropY0"] as? Double) ?? 0
    let cx1 = (args["cropX1"] as? Double) ?? 1
    let cy1 = (args["cropY1"] as? Double) ?? 1
    DispatchQueue.global(qos: .userInitiated).async {
      var horizon: [String: Any]? = nil
      if #available(iOS 13.0, *) {
        horizon = HorizonDetector.detect(
          bgra: data, width: width, height: height,
          cropX0: cx0, cropY0: cy0, cropX1: cx1, cropY1: cy1
        )
      }
      DispatchQueue.main.async { result(horizon) } // nil when none found
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
