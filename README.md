# OneloSwift

![Tests](https://github.com/onelo-tools/onelo-swift/actions/workflows/tests.yml/badge.svg)

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

`OneloAuthView` always loads the centrally-hosted sign-in page in a `WKWebView` — on every plan. Social providers (Google, GitHub, Apple) are handed off to `ASWebAuthenticationSession` automatically.

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
| `onelo.auth` | Hosted sign-in and sessions | `currentSession`, `awaitReady()`, `handleAuthCallback()`, `show(from:)`, `signupMarketingConsent` |
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

Feature flags follow the signed-in Onelo user automatically: every Features call sends that user's access token, so the server knows who is asking. There is nothing to identify. `identify()` and its `userIdHash` argument still compile but are deprecated, and `userIdHash` is no longer sent.

### How an app should start

`features.ready()` returns once the server has confirmed the snapshot for the **current** user — the restored session at launch, the new user after a sign-in or switch. Await it before you present gated UI, so the first render (and the first menu open) is complete. Build menus from the cache, never from a network call per open, and rebuild them when features change:

```swift
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let onelo = Onelo(publishableKey: "onelo_pk_live_YOUR_KEY",
                      baseURL: URL(string: "https://api.onelo.tools")!)
    let menu = NSMenu()
    private var unsubscribe: (@MainActor () -> Void)?

    func applicationDidFinishLaunching(_ note: Notification) {
        onelo.features.declare(["advanced-export", "pro-voices"])
        menu.delegate = self
        // A deploy, a plan change or a sign-in updates the menu while it is open.
        unsubscribe = onelo.features.subscribe { [weak self] in self?.rebuildMenu() }
        Task {
            // Waits for THIS user's snapshot (bounded). Returns at once when it is
            // already confirmed; after a timeout, the persisted snapshot is used
            // and the UI updates when the confirmed one lands.
            await onelo.features.ready(timeout: 3)
            showMainWindow()
        }
    }

    // Built synchronously from the cache on every open — no refresh() here.
    func menuNeedsUpdate(_ menu: NSMenu) { rebuildMenu() }

    private func rebuildMenu() {
        menu.removeAllItems()
        if let item = onelo.features.feature("advanced-export")
            .menuItem(title: "Advanced Export…", action: #selector(export)) {
            menu.addItem(item)
        }
    }
}
```

After a sign-in, await `ready()` again before revealing gated windows: it resets on every identity change, and from 3.100.2 it is safe to await straight from an `isAllowedIn` or `currentSession` observer. `isSnapshotConfirmed` is the same signal as an observable property for SwiftUI.

## Platform notes

- **Tokens are stored in the Keychain** — never `UserDefaults`. See [Session Keychain](#session-keychain).
- **App Attest** proves requests come from a genuine build of your app. It runs automatically when your Onelo app is configured to require it, and is skipped on the Simulator.
- **External links open in the system browser**, not inside the auth WebView.
- **On macOS**, the auth window has a minimum width of 440pt.

## Session Keychain

From 3.101.0 each app keeps its own session. The SDK stores it under the service `com.onelo.auth.<your bundle id>`, so two Onelo apps on one Mac never read or clear each other's session.

**Where the session lives**

| Your app | Keychain | Prompts |
| --- | --- | --- |
| iOS | Data protection keychain | None |
| macOS, signed with a provisioning profile that grants the App ID (`com.apple.application-identifier`) or `keychain-access-groups` | Data protection keychain, your app's default access group | None, also across rebuilds |
| macOS without that entitlement: unsigned, ad-hoc, or Developer ID without a provisioning profile | File-based login keychain, per-app service | Possible on a rebuild whose code signature differs (ad-hoc and unsigned builds); macOS decides, the SDK cannot prevent it |

**For a prompt-free Mac app**, sign it with a provisioning profile: in Xcode, set a Team and turn on the Keychain Sharing capability (or any capability that adds a profile). For a Developer ID app built outside Xcode, create a Developer ID provisioning profile for its App ID, embed it as `Contents/embedded.provisionprofile` and add `com.apple.application-identifier` (`<TEAM_ID>.<bundle id>`) to the signing entitlements. The SDK detects the entitlement at launch without touching the Keychain. If the data protection keychain still refuses access (`errSecMissingEntitlement`), the SDK uses the file-based fallback for the rest of that launch and logs it under the `com.onelo.sdk` subsystem, `keychain` category.

**Upgrading from 3.100.x or earlier.** Earlier versions kept the session under one service, `com.onelo.auth`, shared by every app. On the first launch after the upgrade the SDK reads the old refresh token once and restores the session from it, so a signed-in user stays signed in. On macOS this one read **may show one keychain prompt**; it is never repeated, whether the user allows or denies it (a denial means signing in again). After the server accepts that token, the SDK deletes the old `com.onelo.auth` items, best effort. On macOS, deleting items that another build created may also prompt; an item macOS refuses to delete is left in place and never retried. If the server refuses the token, for example because it belonged to another app, the old items are left for that app.

A Mac app that moves later from the file-based fallback to the data protection keychain (by adding a provisioning profile) asks its users to sign in once more.

The SDK's own `swift test` never touches the Keychain: it runs over an in-memory store.

## Requirements

- **iOS 17+**, **macOS 14+**
- Swift Package Manager

## Links

- **Docs:** [onelo.tools/docs](https://onelo.tools/docs)
- **Dashboard:** [onelo.tools](https://onelo.tools) — your app's snippet comes pre-filled with your keys
- **Issues:** please report them on this repository

## License

MIT
