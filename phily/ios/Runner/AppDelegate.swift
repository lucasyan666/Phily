import Flutter
import UIKit
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {

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
      case "analyzeFrame":
        self?.handleAnalyzeFrame(call: call, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
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
