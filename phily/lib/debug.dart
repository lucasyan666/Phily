import 'package:flutter/foundation.dart';

/// Master switch for all in-app debug affordances — the "DBG" Pro/trial menu
/// and [debugLog] console output.
///
/// Flip this to `true` while developing and **`false` before shipping**: it hides
/// and disables every debug overlay/control in one place, so none of it can leak
/// into a release build.
const bool kPhilyDebug = true;

/// Show the on-screen FPS counter (only renders if [kPhilyDebug] is true).
const bool kShowFPS = false;

/// Debug-gated logger. Prints via [debugPrint] only while [kPhilyDebug] is on,
/// so release builds stay quiet. Use in place of `debugPrint`.
void debugLog(String? message) {
  if (kPhilyDebug) debugPrint(message);
}
