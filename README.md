# OneloSwift

The Onelo SDK for iOS and macOS, written in Swift.

Part of [Onelo](https://onelo.tools): hosted sign-in, a paywall on **your own Stripe** account, plan-gated feature flags, uptime monitoring, in-app feedback, a public roadmap and a waitlist — one SDK, wired together.

## Install

In Xcode: **File → Add Package Dependencies…**, then paste:

```
https://github.com/onelo-tools/onelo-swift
```

## Quick start

```swift
import SwiftUI
import OneloSwift

@main
struct MyApp: App {
    @StateObject var auth = OneloAuth(config: .init(
        publishableKey: "onelo_pk_live_YOUR_KEY",
        apiUrl: URL(string: "https://api.onelo.tools")!,
        callbackScheme: "myapp"
    ))

    var body: some Scene {
        WindowGroup {
            OneloAuthView(auth: auth) {
                ContentView().environmentObject(auth)
            }
            .onOpenURL { url in
                Task { try? await auth.handleAuthCallback(url) }
            }
        }
    }
}
```

`OneloAuthView` must be your **root view** — it presents sign-in when needed and renders your content once the user is in.

Read the signed-in user anywhere below it:

```swift
@EnvironmentObject var auth: OneloAuth

Text(auth.currentSession?.user.email ?? "")
```

If you present your own windows and need to react to entitlement changes, observe `auth.$isAllowedIn`.

## Sign-in is always hosted

`OneloAuthView` always loads the centrally-hosted sign-in page in a `WKWebView` — on both Free and Paid plans. Social providers (Google, GitHub, Apple, on paid plans) are handed off to `ASWebAuthenticationSession` automatically.

**Branding is configured in the Onelo dashboard** — colours, logo and copy are applied to the hosted page there, not in Swift code.

## Modules

Create the full client when you need the non-auth modules:

```swift
let onelo = Onelo(
    publishableKey: "onelo_pk_live_YOUR_KEY",
    baseURL: URL(string: "https://api.onelo.tools")!
)
```

| Accessor | What it does | Key methods |
|---|---|---|
| `onelo.auth` | Hosted sign-in and sessions | `currentSession`, `awaitReady()`, `handleAuthCallback()`, `show(from:)` |
| `onelo.features` | Plan-gated feature flags | `declare()`, `feature()`, `ready()`, `refresh()` |
| `onelo.monitor` | Error and event reporting | `event()`, `track()`, `capture()`, `breadcrumb()`, `setUserId()` |
| `onelo.paywall` | Subscription cancellation | `cancelSubscription()` |
| `onelo.feedback` | In-app bug reports and feature requests | `open()`, `openAsWindow()` |
| `onelo.forms` | Form submissions | `submit()` |
| `onelo.waitlist` | Pre-launch signups | `join()` |

Two surfaces are SwiftUI views rather than accessors:

- **`OneloCustomerPortalView(auth:onDismiss:)`** — cancel, change plan, refunds and invoices.
- **Consent** — the versioned terms / privacy gate is presented automatically by `OneloAuthView`. To drive it yourself, use `auth.requiredConsents()`.

### Feature status

A flag is more than on/off — `FeatureStatus` carries the state your UI should render: `.enabled`, `.disabled`, `.greyed`, `.hidden`, `.upsell`, `.new`, `.beta`, `.coming_soon`.

```swift
switch onelo.features.feature("export-button").status {
case .enabled:      showExportButton()
case .upsell:       showUpgradePrompt()
case .coming_soon:  showComingSoonBadge()
default:            break
}
```

## Platform notes

- **Tokens are stored in the Keychain** — never `UserDefaults`.
- **App Attest** proves requests come from a genuine build of your app. It runs automatically when your Onelo app is configured to require it, and is skipped on the Simulator.
- **External links open in the system browser**, not inside the auth WebView.
- **On macOS**, the auth window has a minimum width of 440pt.

## Requirements

- **iOS 17+**, **macOS 14+**
- Swift Package Manager

## Links

- **Docs:** [onelo.tools/docs](https://onelo.tools/docs)
- **Dashboard:** [onelo.tools](https://onelo.tools) — your app's snippet comes pre-filled with your keys
- **Issues:** please report them on this repository

## License

MIT
