#!/usr/bin/env bash
# Finishes wiring Firebase into the iOS app, after `flutterfire configure`
# has put ios/Runner/GoogleService-Info.plist in place. Safe to run again.
#
#   cd phily && ./tool/wire_firebase_ios.sh              # free team: Google only
#   cd phily && ./tool/wire_firebase_ios.sh --paid-team  # + Apple, email link
#
# Adds the settings that depend on your Firebase project, or on a paid Apple
# Developer Program team, and so can't be committed in advance:
#   1. Google Sign-In's callback URL scheme (REVERSED_CLIENT_ID) → Info.plist
#   2. applinks:<project>.firebaseapp.com → Runner.entitlements, so the
#      email sign-in link opens the app instead of Safari.
#   3. The Sign in with Apple capability → Runner.entitlements.
#
# 2 and 3 need a PAID team: a free personal team can't sign an app that has
# either, and the build fails with "Personal development teams … do not
# support the Sign In with Apple capability". So they only run with
# --paid-team.
set -euo pipefail

PAID=false
[[ ${1:-} == --paid-team ]] && PAID=true

cd "$(dirname "$0")/../ios"
PB=/usr/libexec/PlistBuddy
CONFIG=Runner/GoogleService-Info.plist
INFO=Runner/Info.plist
ENT=Runner/Runner.entitlements

if [[ ! -f $CONFIG ]]; then
  echo "✗ $CONFIG is missing. Run 'flutterfire configure' in phily/ first." >&2
  exit 1
fi

PROJECT_ID=$($PB -c "Print :PROJECT_ID" "$CONFIG")
REVERSED=$($PB -c "Print :REVERSED_CLIENT_ID" "$CONFIG" 2>/dev/null || true)

# 1 ─ Google Sign-In URL scheme ───────────────────────────────────────────────
if [[ -z $REVERSED ]]; then
  echo "! No REVERSED_CLIENT_ID yet. Enable Google under Authentication →"
  echo "  Sign-in method, then run 'flutterfire configure' again and re-run this."
elif grep -q "$REVERSED" "$INFO"; then
  echo "✓ Google URL scheme already present"
else
  $PB -c "Add :CFBundleURLTypes array" "$INFO" 2>/dev/null || true
  n=$($PB -c "Print :CFBundleURLTypes" "$INFO" | grep -c "^    Dict {" || true)
  $PB -c "Add :CFBundleURLTypes:$n dict" "$INFO"
  $PB -c "Add :CFBundleURLTypes:$n:CFBundleTypeRole string Editor" "$INFO"
  $PB -c "Add :CFBundleURLTypes:$n:CFBundleURLSchemes array" "$INFO"
  $PB -c "Add :CFBundleURLTypes:$n:CFBundleURLSchemes:0 string $REVERSED" "$INFO"
  echo "✓ Added Google URL scheme $REVERSED"
fi

if ! $PAID; then
  plutil -lint "$INFO" >/dev/null
  echo "Done (Google only). After joining the Apple Developer Program, re-run"
  echo "with --paid-team to add Sign in with Apple and the email-link domain."
  exit 0
fi

# 2 ─ Associated domain for the email link ────────────────────────────────────
DOMAIN="applinks:$PROJECT_ID.firebaseapp.com"
if grep -q "$DOMAIN" "$ENT"; then
  echo "✓ Associated domain already present"
else
  $PB -c "Add :com.apple.developer.associated-domains array" "$ENT" 2>/dev/null || true
  $PB -c "Add :com.apple.developer.associated-domains:0 string $DOMAIN" "$ENT"
  echo "✓ Added associated domain $DOMAIN"
fi

# 3 ─ Sign in with Apple ───────────────────────────────────────────────────────
if grep -q "com.apple.developer.applesignin" "$ENT"; then
  echo "✓ Sign in with Apple already present"
else
  $PB -c "Add :com.apple.developer.applesignin array" "$ENT"
  $PB -c "Add :com.apple.developer.applesignin:0 string Default" "$ENT"
  echo "✓ Added Sign in with Apple"
fi

plutil -lint "$INFO" "$ENT" >/dev/null
echo "Done. Open Xcode once so automatic signing picks up the new capabilities."
