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

  /// Dedicated serial queue for all AVCaptureDevice configuration work.
  /// The Flutter camera plugin uses its own internal queue for session operations;
  /// this queue serialises our *additional* device property writes (videoZoomFactor,
  /// ramp, etc.) so they never contend with the plugin's session queue or with
  /// each other, and never execute on the platform main thread.
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

    // Register the camera channel via the plugin registry messenger —
    // this avoids the window.rootViewController deprecation warning and
    // works correctly after the UISceneDelegate migration.
    let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "PhilyCameraPlugin")!
    let channel = FlutterMethodChannel(
      name: "phily/camera",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "getUltraWideCameraId":
        self?.handleGetUltraWideCameraId(result: result)
      case "getVirtualCameraId":
        self?.handleGetVirtualCameraId(result: result)
      case "analyzeFrame":
        self?.handleAnalyzeFrame(call: call, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    // ── Seamless zoom channel ─────────────────────────────────────────────────
    // Bypasses Flutter's CameraController.setZoomLevel() (which routes through
    // the plugin's own AVCaptureDevice lock, potentially conflicting with our
    // rapid drag updates) and writes directly to AVCaptureDevice.videoZoomFactor.
    //
    // Because we set videoZoomFactor on the SAME device object that the Flutter
    // plugin's AVCaptureSession is using, the change is applied to the live
    // session immediately and atomically — no session teardown, no frame drop.
    //
    // Apple's virtual device (builtInTripleCamera / builtInDualWideCamera)
    // handles physical lens blending internally based on
    // virtualDeviceSwitchOverVideoZoomFactors, which is why crossing 1× is
    // completely seamless at the hardware level.
    let zoomRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "PhilyZoomPlugin")!
    let zoomChannel = FlutterMethodChannel(
      name: "com.phily.camera/zoom",
      binaryMessenger: zoomRegistrar.messenger()
    )
    zoomChannel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "setZoom":
        self?.handleSetZoom(call: call, result: result)
      case "rampZoom":
        self?.handleRampZoom(call: call, result: result)
      case "getZoomInfo":
        self?.handleGetZoomInfo(result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  // MARK: - Zoom helpers

  /// Returns the best virtual (multi-lens) back camera available on this device.
  /// Priority: triple camera → dual-wide → dual → plain wide-angle.
  /// This is the same device the Flutter plugin initialised with (since
  /// _probeForVirtualCamera uses the identical priority order).
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

  // MARK: - setZoom
  //
  // Applies an immediate (non-animated) zoom. Ideal for continuous drag input.
  // Calls device.videoZoomFactor directly — iOS blends lenses internally using
  // virtualDeviceSwitchOverVideoZoomFactors without any visible frame gap.

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

    // Dispatch to sessionQueue so device configuration never blocks the
    // platform main thread and never races with other session operations.
    sessionQueue.async {
      do {
        try device.lockForConfiguration()
        let clamped = CGFloat(factor).clamped(
          to: device.minAvailableVideoZoomFactor...device.maxAvailableVideoZoomFactor
        )
        device.videoZoomFactor = clamped
        device.unlockForConfiguration()
        DispatchQueue.main.async { result(nil) }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "LOCK_FAILED", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  // MARK: - rampZoom
  //
  // Applies a hardware-animated zoom ramp. Use for discrete tap-to-zoom
  // transitions (e.g. tapping a major tick mark) where a smooth glide looks
  // better than an instant jump. The OS cancels any previous ramp atomically.

  private func handleRampZoom(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard
      let args   = call.arguments as? [String: Any],
      let factor = args["factor"] as? Double,
      let rate   = args["rate"]   as? Float   // zoom units per second, e.g. 4.0
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
        let clamped = CGFloat(factor).clamped(
          to: device.minAvailableVideoZoomFactor...device.maxAvailableVideoZoomFactor
        )
        device.ramp(toVideoZoomFactor: clamped, withRate: rate)
        device.unlockForConfiguration()
        DispatchQueue.main.async { result(nil) }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "LOCK_FAILED", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  // MARK: - getZoomInfo
  //
  // Returns the full zoom capability profile of the virtual device:
  //   min, max         — hardware limits (capped at 25 for UX)
  //   current          — current videoZoomFactor
  //   switchoverFactors — the exact zoom values where iOS transitions between
  //                       physical lenses (ultra-wide → wide → telephoto).
  //                       The Flutter UI uses these to draw accent tick marks
  //                       on the zoom wheel, matching the native Camera app.

  private func handleGetZoomInfo(result: @escaping FlutterResult) {
    guard let device = bestVirtualDevice() else {
      result(FlutterError(code: "NO_DEVICE", message: "No virtual camera found", details: nil))
      return
    }

    var switchoverFactors: [Double] = []
    if #available(iOS 14.0, *) {
      // virtualDeviceSwitchOverVideoZoomFactors reports the hardware-native
      // boundaries. e.g. on iPhone 14 Pro: [2.0, 6.0]
      //   < 2.0  → ultra-wide lens active
      //   2–6.0  → wide-angle lens active
      //   > 6.0  → telephoto lens active
      switchoverFactors = device.virtualDeviceSwitchOverVideoZoomFactors.map { $0.doubleValue }
    }

    let hardwareMax = Double(device.maxAvailableVideoZoomFactor)
    let cappedMax   = min(hardwareMax, 25.0)

    result([
      "min":               Double(device.minAvailableVideoZoomFactor),
      "max":               cappedMax,
      "current":           Double(device.videoZoomFactor),
      "switchoverFactors": switchoverFactors,
    ])
  }

  // MARK: - getVirtualCameraId
  //
  // Returns the uniqueID of the best virtual multi-camera device on this device.
  // Virtual devices (builtInTripleCamera, builtInDualWideCamera) handle the
  // entire 0.5x–max zoom range through a SINGLE AVCaptureSession by routing
  // to the correct physical lens internally — no session swap, no black frame.

  private func handleGetVirtualCameraId(result: @escaping FlutterResult) {
    let session = AVCaptureDevice.DiscoverySession(
      deviceTypes: [
        .builtInTripleCamera,
        .builtInDualWideCamera,
        .builtInDualCamera,
      ],
      mediaType: .video,
      position: .back
    )
    // Prefer triple camera (widest range), then dual-wide, then dual.
    let best = session.devices.first
    result(best?.uniqueID)
  }

  // MARK: - getUltraWideCameraId

  private func handleGetUltraWideCameraId(result: @escaping FlutterResult) {
    let session = AVCaptureDevice.DiscoverySession(
      deviceTypes: [
        .builtInUltraWideCamera,
        .builtInWideAngleCamera,
        .builtInTelephotoCamera,
      ],
      mediaType: .video,
      position: .back
    )
    let ultraWide = session.devices.first { $0.deviceType == .builtInUltraWideCamera }
    result(ultraWide?.uniqueID)
  }

  // MARK: - analyzeFrame

  private func handleAnalyzeFrame(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard
      let args   = call.arguments as? [String: Any],
      let typed  = args["yPlane"] as? FlutterStandardTypedData,
      let width  = args["width"]  as? Int,
      let height = args["height"] as? Int,
      let mode   = args["mode"]   as? String
    else {
      result(FlutterError(code: "INVALID_ARGS", message: "Missing frame arguments", details: nil))
      return
    }

    let data = typed.data
    DispatchQueue.global(qos: .userInitiated).async {
      var segments: [[String: Double]] = []
      if #available(iOS 14.0, *) {
        segments = EdgeAlignmentDetector.computeScore(
          yPlane: data,
          width: width,
          height: height,
          mode: mode
        )
      }
      DispatchQueue.main.async { result(segments) }
    }
  }
}
