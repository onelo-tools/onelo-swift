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
.package(url: "https://github.com/onelo-tools/onelo-swift", from: "2.0.0")
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

Drop in a ready-made login screen with full visual customization:

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

// UIKit / programmatic
onelo.auth.show(from: self) { session in
    print("Signed in:", session.user.email ?? "")
}
```

`OneloAuthConfig` lets you customize colors, corner radius, button height, and more. See `OneloAuthConfig.swift` for all options.

All screens include hardcoded "Powered by Onelo" branding.

## Feature Status Values

| Status | Meaning |
|--------|---------|
| `.enabled` | Feature is on |
| `.greyed` | Visible but disabled |
| `.hidden` | Not shown |
| `.upsell` | Show upgrade prompt |
