# OneDrive Setup

This app supports Microsoft OneDrive as a music source. To enable it you need a Microsoft Entra
(Azure AD) **Application (client) ID** — it takes about five minutes to create one. It's a public
client using PKCE, so there is **no client secret** to manage.

---

## Prerequisites

- A Microsoft account (personal — outlook.com / hotmail.com / live.com). This app is registered for
  **personal accounts only**.
- A free Apple developer account is sufficient; no $99/year paid membership is required for this step.
- Bundle id: `com.willeasp.nanometers.ios` (already set in `project.yml`).

---

## Step 1 — Register the app in Microsoft Entra

1. Go to the [Entra admin center → App registrations](https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade)
   (or [portal.azure.com](https://portal.azure.com/) → **Microsoft Entra ID → App registrations**).
2. Click **+ New registration**.
3. **Name**: anything (e.g. "NanoMeters").
4. **Supported account types**: choose **Personal Microsoft accounts only**.
   (This matches the `/consumers` authority the app uses. Don't pick a "work/school" option.)
5. Leave **Redirect URI** blank for now (we add it as an iOS platform in Step 2). Click **Register**.
6. On the app's **Overview** page, copy the **Application (client) ID** — a GUID like
   `00000000-0000-0000-0000-000000000000`. You'll paste it in Step 4.

---

## Step 2 — Add the iOS/macOS redirect platform

1. In the app, go to **Manage → Authentication**.
2. Click **+ Add a platform → iOS / macOS**.
3. **Bundle ID**: `com.willeasp.nanometers.ios` (exact match — case-sensitive).
4. Click **Configure**. Entra computes the redirect URI for you:
   ```
   msauth.com.willeasp.nanometers.ios://auth
   ```
   This is exactly what the app uses (it's the MSAL convention, and it works for a raw PKCE flow too).
   Click **Done**.

> Do **not** register this redirect under the "Web" or "Single-page application" platforms — those
> activate CORS/`Origin` handling that the identity platform rejects for a native app, and sign-in
> will fail. It must be the **iOS/macOS** platform.

---

## Step 3 — Grant the Graph permissions

1. Go to **Manage → API permissions**.
2. Click **+ Add a permission → Microsoft Graph → Delegated permissions**.
3. Add **`Files.Read`** (read the user's files) and **`offline_access`** (issue a refresh token so the
   source survives past the ~1h access-token lifetime).
4. No admin consent is required — a personal account self-consents on first sign-in.

---

## Step 4 — Put the client ID in a local, gitignored `Secrets.xcconfig`

The client ID is **never committed** (this is a public repo). It lives in a local
`apps/nano-ios/Secrets.xcconfig`, which is gitignored; `project.yml` references it via build-setting
substitution (`$(MICROSOFT_OAUTH_CLIENT_ID)`), so the committed tree only ever holds the placeholder.

```sh
cd apps/nano-ios
cp Secrets.example.xcconfig Secrets.xcconfig   # if you don't already have one
```

Open `Secrets.xcconfig` and set the client ID (the redirect scheme already defaults to your bundle id
in `Config.xcconfig`, so you only need the client ID):

```
MICROSOFT_OAUTH_CLIENT_ID = 00000000-0000-0000-0000-000000000000
```

There is no client secret — PKCE (RFC 7636) handles the exchange.

---

## Step 5 — Regenerate the Xcode project and build

```sh
cd apps/nano-ios
xcodegen generate
xcodebuild build -project NanoMeters.xcodeproj -scheme NanoMeters \
  -destination 'platform=iOS Simulator,id=28DD8D81-668A-4887-98E8-BFE3CC625596'
```

The OneDrive **Connect** button in **Settings → Sources → Add Source** is now enabled (it shows
"Needs setup" until the client ID is present). Tap it to trigger the Microsoft sign-in, then add a
OneDrive folder as a root to browse and play.

---

## Notes

- **Personal accounts only** — the app authorizes against the `/consumers` authority. A work/school
  account will be rejected at sign-in. (Widening this later means re-registering the supported account
  type and re-consenting.)
- **No client secret** — it's a public PKCE client; the client ID alone is sufficient.
- **Refresh-token rotation** — Microsoft issues a new refresh token on every refresh; the app persists
  it automatically (the OneDrive source would otherwise die after the first rotation).
- **Kept out of git** — the client ID lives only in `Secrets.xcconfig` (gitignored), substituted into
  the built app's Info.plist at build time. The redirect scheme (`msauth.<bundle-id>`) is derived from
  the public bundle id, so it's defaulted in the committed `Config.xcconfig`.
- **Keychain** — the app must be signed for `SecItemAdd` to store the token (Simulator included),
  handled by `NanoMeters.entitlements` + local signing in `project.yml`; no action needed.

## Troubleshooting

- **`AADSTS50011` redirect-URI mismatch** — the redirect in Entra doesn't match
  `msauth.com.willeasp.nanometers.ios://auth`. Re-check Step 2: it must be added under the
  **iOS/macOS** platform with the exact bundle id, not Web/SPA.
- **`AADSTS900971` / "no reply address"** — same cause; the iOS platform redirect wasn't saved.
- **Sign-in rejected with a work/school account** — expected. This registration is personal-accounts
  only; sign in with an outlook.com / hotmail.com / live.com account.
- **OneDrive row shows "Add your Microsoft client ID"** — `Secrets.xcconfig` is missing the client ID
  or still has the placeholder; fill it in and re-run `xcodegen generate`.
- **Source goes amber (~1h after connecting)** — `offline_access` wasn't granted (Step 3); without it
  Graph never issues a refresh token. Add the permission and reconnect.
