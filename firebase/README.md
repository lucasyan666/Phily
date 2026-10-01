# Phily backend

Firebase, in London (`europe-west2`). Three callable Cloud Functions, a
Firestore database closed to clients, and Firebase Auth.

| Function | Called by | Does |
|---|---|---|
| `submitFeedback` | Feedback sheet | Validates, stores in `feedback/`, pings your WhatsApp via CallMeBot |
| `claimTrial` | `PhilyPro` (once per device) | Asks Apple DeviceCheck whether this phone already had a trial |
| `deleteAccount` | Account sheet | Deletes the user's feedback and their Auth account |

The app runs without any of this. With no `GoogleService-Info.plist`, sign-in and
feedback say "not connected in this build" and everything else works.

## What is stored

| Data | Where | Why | Kept |
|---|---|---|---|
| Feedback text, kind, app + iOS version, guide it came from | Firestore `feedback/` (London) | To read and act on it | 24 months (TTL on `expireAt`) |
| Email + the exact consent sentence + version + time | Same record, **only if the user switched consent on** | To reply | Same |
| Account uid on feedback | Same record, if signed in | So deleting the account deletes the feedback | Same |
| Sign-in email, name, provider | Firebase Auth (Google, global) | The account | Until the user deletes it |
| Hashed IP or uid + a counter | Firestore `rateLimits/` | Stop floods | 1 day (TTL) |
| Trial start date | The phone's Keychain | Survive reinstall | On device |
| "Trial used" bit | Apple DeviceCheck | Survive a wiped phone | Apple's servers |

Firestore rules deny every client read and write (`firestore.rules`). Only the
functions touch it. Encryption: TLS in transit, AES-256 at rest (Google's
default), sign-in tokens in the iOS Keychain.

## Cost

At Phily's size, **£0 a month**. The Blaze (pay-as-you-go) plan is required for
Cloud Functions, so Google holds a card, but the free allowance is 2 million
function calls a month, and Firestore and Auth for Apple/Google/email are free
at this scale. Secret Manager's free tier covers six secrets; this uses five.
**Set a budget alert** (Google Cloud console → Billing → Budgets, e.g. £1) so any
surprise emails you.

CallMeBot is free. It's an unofficial service, personal use only, with no uptime
guarantee. Every message is saved in Firestore before the ping is attempted, so
a failed ping loses nothing; look for `notified: false`.

## One-time setup

You need: a Google account, a **paid** Apple Developer Program membership (the free personal team, `Q7K6S5CMVK`, can't use Sign in with Apple, email links or DeviceCheck keys; enrolling gives you a new Team ID to use below),
and the Firebase CLI (`npm i -g firebase-tools`, then `firebase login`).

1. **Create the project** at console.firebase.google.com. Upgrade it to
   **Blaze** and set the budget alert above.
2. **Firestore** → Create database → *Production mode* → location
   **`europe-west2` (London)**. The location can't be changed later.
3. **Authentication** → Sign-in method, enable:
   - **Apple**. For account deletion to revoke Apple's token, fill in its *OAuth
     code flow configuration*: Services ID can be left blank for iOS-only; add
     Team ID, the Key ID and the `.p8` from step 5.
   - **Google**.
   - **Email/Password**, with **Email link (passwordless sign-in)** switched on.
4. **Project settings → Your apps → add iOS**: bundle ID `com.lucasyan.phily`,
   your paid Team ID (App Store ID once you have one). Then, in `phily/`:
   ```sh
   dart pub global activate flutterfire_cli
   flutterfire configure --platforms=ios      # writes ios/Runner/GoogleService-Info.plist
   ./tool/wire_firebase_ios.sh                # Google URL scheme
   ./tool/wire_firebase_ios.sh --paid-team    # later: + Sign in with Apple, email-link domain
   ```
   Open Xcode once so automatic signing picks up Sign in with Apple and
   Associated Domains. Check the email-link domain is live:
   `curl https://PROJECT_ID.firebaseapp.com/.well-known/apple-app-site-association`
5. **Apple key**: developer.apple.com → Certificates, IDs & Profiles → Keys → +.
   Enable **DeviceCheck** and **Sign in with Apple** on the one key and download
   the `.p8`. Apple lets you download it only once, so store it somewhere safe.
6. **CallMeBot**: add the bot's WhatsApp number listed at
   callmebot.com/blog/free-api-whatsapp-messages (it changes now and then), send
   it `I allow callmebot to send me messages`, and wait for your API key.
7. **Secrets** (each command prompts for the value), from this folder:
   ```sh
   firebase use --add                                      # pick the project
   firebase functions:secrets:set CALLMEBOT_PHONE          # +447700900123
   firebase functions:secrets:set CALLMEBOT_APIKEY
   firebase functions:secrets:set APPLE_TEAM_ID            # your paid Team ID
   firebase functions:secrets:set APPLE_DEVICECHECK_KEY_ID
   firebase functions:secrets:set APPLE_DEVICECHECK_KEY < AuthKey_XXXXXXXXXX.p8
   ```
8. **App Check** → Apps → your iOS app → **App Attest** → Save. The functions
   enforce it, so until this is done every call is refused.
   For debug builds (`flutter run`), the app uses the debug provider: run it from
   Xcode, copy the `Firebase App Check debug token` line from the console, and
   add it under App Check → Apps → ⋮ → *Manage debug tokens*.
9. **Deploy**:
   ```sh
   cd functions && npm install && npm test && cd ..
   firebase deploy --only functions,firestore
   ```
10. **Retention** (turns the `expireAt` fields into automatic deletion):
    ```sh
    gcloud firestore fields ttls update expireAt --collection-group=feedback --enable-ttl
    gcloud firestore fields ttls update expireAt --collection-group=rateLimits --enable-ttl
    ```
11. **Try it**: send feedback from the app. It should appear in Firestore and on
    your WhatsApp within a few seconds. Logs: `firebase functions:log`.

## Replying to people

Feedback with consent carries the user's email. Two things to know:

- Reply **only about that message**. That is what they agreed to (the stored
  `consentText`). Newsletters need a separate opt-in under UK PECR.
- Sign in with Apple users may hide their address behind
  `…@privaterelay.appleid.com`. Mail to it only arrives if you register your
  sending address or domain in the Apple developer portal under Services → Sign
  in with Apple for Email Communication.

## Legal checklist (UK GDPR)

Not legal advice, but what a small UK app like this needs:

- [ ] **ICO data protection fee.** A UK business that processes personal
      data almost certainly has to pay it: tier 1, about £52 a year, at ico.org.uk.
- [ ] **Privacy policy** (`lucasyan666.github.io/phily-legal`). Add:
      what the table above says; that feedback is stored by Google (Firebase) in
      London and forwarded to the developer's WhatsApp through CallMeBot and
      Meta; that account data is held by Google under its data-processing terms
      (international transfers covered by the UK–US data bridge); retention (24
      months); that email is collected only with consent and used only to reply;
      how to delete (in-app **Delete account**, or ask by email for feedback sent
      while signed out); a contact address; the right to complain to the ICO.
- [ ] **App Store Connect → App Privacy** (it currently says no data is
      collected). Declare, all *linked to the user*, none used for tracking:
      Contact Info → **Email Address** and **Name** (App Functionality);
      Identifiers → **User ID** (App Functionality); User Content → **Customer
      Support** (App Functionality); Diagnostics → **Other Diagnostic Data**
      (app/iOS version, App Functionality).
- [x] **Guideline 4.8**: Sign in with Apple is offered beside Google.
- [x] **Guideline 5.1.1(v)**: sign-in is optional; in-app account deletion;
      the Apple token is revoked on deletion.
- [x] **Consent**: off by default, recorded with its exact wording and version,
      withdrawable (switch it off before sending; delete the account after).
