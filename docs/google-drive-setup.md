# Google Drive Setup

This app supports Google Drive as a music source. To enable it you need a Google OAuth client ID —
it takes about five minutes to create one. PKCE means there is no client secret to manage.

---

## Prerequisites

- A Google account (any — personal is fine).
- A free Apple developer account is sufficient; no $99/year paid membership is required for this step.
- Bundle id: `com.willeasp.nanometers.ios` (already set in `project.yml`).

---

## Step 1 — Create a Google Cloud project

1. Go to [console.cloud.google.com](https://console.cloud.google.com/).
2. Click the project selector at the top → **New Project**.
3. Name it anything (e.g. "NanoMeters"), leave Organization as-is, click **Create**.
4. Make sure the new project is selected in the project picker.

---

## Step 2 — OAuth consent screen

1. In the left sidebar: **APIs & Services → OAuth consent screen**.
2. Choose **External** (so you can use any Google account), click **Create**.
3. Fill in the required fields:
   - **App name**: NanoMeters (or anything)
   - **User support email**: your email
   - **Developer contact email**: your email
4. Click **Save and Continue** through the Scopes page.
5. On the **Test users** page: click **Add Users**, add your own Google account email, click **Add**.
   (Only test users can sign in while the app is in testing mode — you don't need to publish.)
6. Click **Save and Continue**, then **Back to Dashboard**.
7. On the **Scopes** tab click **Add or Remove Scopes**, search for `drive.readonly`, check
   `https://www.googleapis.com/auth/drive.readonly`, and click **Update** → **Save and Continue**.

---

## Step 3 — Create the iOS OAuth client ID

1. In the left sidebar: **APIs & Services → Credentials**.
2. Click **+ Create Credentials → OAuth client ID**.
3. **Application type**: iOS.
4. **Bundle ID**: `com.willeasp.nanometers.ios` (exact match — case-sensitive).
5. Click **Create**.
6. A dialog shows your client ID. It looks like:
   ```
   123456789-abcdefghijklmnopqrstuvwxyz012345.apps.googleusercontent.com
   ```
   Copy it.

---

## Step 4 — Put the client ID in a local, gitignored `Secrets.xcconfig`

The client ID is **never committed** (this is a public repo). It lives in a local
`apps/nano-ios/Secrets.xcconfig`, which is gitignored; `project.yml` references it via build-setting
substitution (`$(GOOGLE_OAUTH_CLIENT_ID)`), so the committed tree only ever holds the placeholder.

```sh
cd apps/nano-ios
cp Secrets.example.xcconfig Secrets.xcconfig
```

Open `Secrets.xcconfig` and set **both** values from your one client ID:

```
GOOGLE_OAUTH_CLIENT_ID = 123456789-abcdefghijklmnopqrstuvwxyz012345.apps.googleusercontent.com
GOOGLE_OAUTH_REVERSED_SCHEME = com.googleusercontent.apps.123456789-abcdefghijklmnopqrstuvwxyz012345
```

The reversed scheme is the **reversed client ID** — drop `.apps.googleusercontent.com` and prepend
`com.googleusercontent.apps.`. Google uses it as the callback URL for iOS apps. There is no client
secret — PKCE handles the exchange.

---

## Step 5 — Regenerate the Xcode project and build

```sh
cd apps/nano-ios
xcodegen generate
xcodebuild build -project NanoMeters.xcodeproj -scheme NanoMeters \
  -destination 'platform=iOS Simulator,id=28DD8D81-668A-4887-98E8-BFE3CC625596'
```

The Drive Connect button in **Settings → Sources** will now be enabled. Tap it to trigger the
Google OAuth consent screen. After authorising, add a Drive folder as a root to browse and play.

---

## Notes

- **No client secret** — PKCE (RFC 7636) handles the exchange; the client ID alone is sufficient.
- **Kept out of git** — the client ID lives only in `Secrets.xcconfig` (gitignored) and is substituted
  into the built app's Info.plist at build time. This is a public repo, so the placeholder is what's
  committed. It's a PKCE public client (no secret), but there's no reason to publish your personal id.
- **Keychain** — the app must be signed for `SecItemAdd` to store the token (Simulator included). This
  is handled by `NanoMeters.entitlements` + local signing in `project.yml`; no action needed.
- **Free Apple personal team** — device installs work on the free personal team (7-day expiry;
  re-install with `run-on-device.sh`). TestFlight / App Store distribution requires a paid team.

## Troubleshooting

- **`403 access_denied` / "Google hasn't verified this app … only approved testers have access"** —
  your account isn't a **test user**. In the console: **APIs & Services → OAuth consent screen →
  Audience** (publishing status **Testing**) → **Test users → + Add users** → add your email → Save.
  (Scopes live on the adjacent **Data Access** tab — add `…/auth/drive.readonly` there.) Then retry Connect.
- **"Google hasn't verified this app" interstitial** (after you're a test user) — expected for a
  test-mode client. Tap **Advanced → Go to <app> → Continue** and grant access.
- **Drive row shows "Add your Google client ID"** — `Secrets.xcconfig` is missing or still has the
  placeholder; fill it in and re-run `xcodegen generate`.
