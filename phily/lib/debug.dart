/// Master switch for all in-app debug affordances — the FPS counter and the
/// "DBG" Pro/trial menu.
///
/// Flip this to `true` while developing and **`false` before shipping**: it hides
/// and disables every debug overlay/control in one place, so none of it can leak
/// into a release build.
const bool kPhilyDebug = true;
