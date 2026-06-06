package com.example.phily

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import kotlin.concurrent.thread

class MainActivity : FlutterActivity() {
	private val CHANNEL = "phily/camera"

	override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
		super.configureFlutterEngine(flutterEngine)

		MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
			when (call.method) {
				"analyzeRuleOfThirds" -> handleAnalyzeRuleOfThirds(call.arguments as? Map<*, *>, result)
				"getUltraWideCameraId", "getVirtualCameraId" -> result.success(null)
				else -> result.notImplemented()
			}
		}
	}

	private fun handleAnalyzeRuleOfThirds(args: Map<*, *>?, result: MethodChannel.Result) {
		if (args == null) { result.error("INVALID_ARGS", "args required", null); return }
		val width = (args["width"] as? Int) ?: run { result.error("INVALID_ARGS", "width required", null); return }
		val height = (args["height"] as? Int) ?: run { result.error("INVALID_ARGS", "height required", null); return }

		// yPlane may be passed as a byte[] or as FlutterStandardTypedData (ByteBuffer)
		val yPlaneRaw = args["yPlane"]
		val bytes: ByteArray? = when (yPlaneRaw) {
			is ByteArray -> yPlaneRaw
			is ByteBuffer -> {
				val b = ByteArray(yPlaneRaw.remaining())
				yPlaneRaw.get(b)
				b
			}
			else -> null
		}

		if (bytes == null) { result.error("INVALID_ARGS", "yPlane bytes required", null); return }

		// Do light processing off the UI thread
		thread {
			// Simple saliency: threshold to find connected region of bright pixels
			var minX = width; var minY = height; var maxX = 0; var maxY = 0
			var count = 0
			var sumIntensity = 0L

			// Adaptive threshold: mean + stddev * 0.5
			var sum = 0L
			var sumSq = 0L
			for (i in bytes.indices) {
				val v = bytes[i].toInt() and 0xFF
				sum += v
				sumSq += v * v
			}
			val n = bytes.size
			val mean = sum.toDouble() / n
			val variance = (sumSq.toDouble() / n) - (mean * mean)
			val std = if (variance > 0) Math.sqrt(variance) else 0.0
			val thresh = (mean + std * 0.5).coerceIn(16.0, 220.0)

			var y = 0
			var x = 0
			for (idx in 0 until n) {
				val v = bytes[idx].toInt() and 0xFF
				if (v >= thresh) {
					x = idx % width
					y = idx / width
					if (x < minX) minX = x
					if (y < minY) minY = y
					if (x > maxX) maxX = x
					if (y > maxY) maxY = y
					count++
					sumIntensity += v
				}
			}

			val detections = mutableListOf<Map<String, Any>>()
			if (count > 8) {
				val bx = minX.toDouble() / width.toDouble()
				val by = minY.toDouble() / height.toDouble()
				val bw = ((maxX - minX + 1).toDouble() / width.toDouble()).coerceAtMost(1.0)
				val bh = ((maxY - minY + 1).toDouble() / height.toDouble()).coerceAtMost(1.0)
				val conf = ((sumIntensity.toDouble() / count) / 255.0).coerceIn(0.0, 1.0)
				detections.add(mapOf(
					"x" to bx,
					"y" to by,
					"w" to bw,
					"h" to bh,
					"label" to "salient",
					"confidence" to conf
				))
			}

			val out: MutableMap<String, Any> = mutableMapOf(
				"aligned" to false,
				"haptic" to false,
				"score" to 0.0,
				"edgeSegments" to listOf<Map<String, Double>>(),
				"bbox" to mapOf("x" to 0.0, "y" to 0.0, "w" to 0.0, "h" to 0.0),
				"detections" to detections
			)

			runOnUiThread { result.success(out) }
		}
	}
}
