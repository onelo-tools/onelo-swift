# onelo-swift

Swift SDK for [Onelo](https://onelo.tools) — features, paywall, forms, waitlist, and authentication.

Supports iOS 17+ and macOS 14+.

## Installation

Add via Xcode: **File → Add Package Dependencies** → paste:

```
https://github.com/onelo-tools/onelo-swift
```

Or in `Package.swift`:
```swift
.package(url: "https://github.com/onelo-tools/onelo-swift", from: "2.2.0")
```

## Quick Start

```swift
import OneloSwift

let onelo = Onelo(publishableKey: "pk_live_...")

// Set user context after login
await onelo.identify(currentUser.id, plan: "pro")

// Features
if onelo.features.isEnabled("export-button") {
    showExportButton()
}

// Paywall
if onelo.paywall.check("pro") {
    // user has pro access
}

// Forms
let result = await onelo.forms.submit("feedback", data: ["message": "Great app!"])

// Waitlist
let joined = await onelo.waitlist.join("beta", email: "user@example.com")
```

## Modules

| Module | Access | Description |
|--------|--------|-------------|
| `onelo.features` | `OneloFeatures` | Feature flags — `isEnabled()`, `status()` |
| `onelo.paywall` | `OneloPaywall` | Plan gating — `check()` |
| `onelo.forms` | `OneloForms` | Form submission — `submit()` |
| `onelo.waitlist` | `OneloWaitlist` | Waitlist signup — `join()` |
| `OneloAuth` | (standalone) | PKCE authentication flow |

## Authentication

`OneloAuth` handles the full PKCE authentication flow and is available separately:

```swift
import OneloSwift

let auth = OneloAuth(config: OneloConfig(...))
await auth.signIn()
```

## Auth UI

Drop in a ready-made login screen:

```swift
import OneloSwift
import SwiftUI

// SwiftUI embed
OneloAuthView(
    auth: onelo.auth.authObject,
    config: OneloAuthConfig(
        accentColor: .purple,
        appName: "My App",
        appLogo: Image("AppLogo")
    )
) { session in
    print("Signed in:", session.user.email ?? "")
}

// UIKit / AppKit (programmatic)
onelo.auth.show(from: self) { session in
    print("Signed in:", session.user.email ?? "")
}
```

### Customization & Plan Gating

`OneloAuthConfig` exposes full visual control:

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `accentColor` | `Color` | Onelo indigo | Buttons, links, focus rings |
| `backgroundColor` | `Color` | System bg | Main sheet background |
| `surfaceColor` | `Color` | System secondary bg | Input field background |
| `textColor` | `Color` | `.primary` | Primary text |
| `subtitleColor` | `Color` | `.secondary` | Subtitles, placeholders |
| `buttonForegroundColor` | `Color` | `.white` | Text/icon color inside buttons |
| `inputBorderColor` | `Color` | `primary.opacity(0.1)` | Input field border color |
| `inputBorderWidth` | `CGFloat` | `1` | Input field border width (0 to hide) |
| `appLogo` | `Image?` | `nil` | Logo shown at top |
| `appName` | `String` | `""` | App name shown below logo |
| `cornerRadius` | `CGFloat` | `10` | Buttons and input fields |
| `buttonHeight` | `CGFloat` | `48` | Primary action button height |
| `inputHeight` | `CGFloat` | `48` | Input field height |

**Plan gating:** On the free plan, `OneloAuthConfig` is ignored — the auth UI always renders with Onelo's default brand (indigo accent, system colors). On paid plans, developers get full control.

```swift
// Free plan — config is silently ignored, Onelo brand is used
OneloAuthView(auth: auth, config: OneloAuthConfig(accentColor: .purple)) { ... }

// Paid plan — full customization honoured
OneloAuthView(auth: auth, config: OneloAuthConfig(
    accentColor: .purple,
    buttonForegroundColor: .white,
    inputBorderColor: Color.purple.opacity(0.3),
    inputBorderWidth: 1.5
)) { ... }
```

All screens include hardcoded "Powered by Onelo" branding.

## Feature Status Values

| Status | Meaning |
|--------|---------|
| `.enabled` | Feature is on |
| `.greyed` | Visible but disabled |
| `.hidden` | Not shown |
| `.upsell` | Show upgrade prompt |
