# OneloSwift

Swift SDK for [Onelo](https://onelo.tools) authentication. Supports iOS 16+ and macOS 13+.

## Installation

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/onelo-tools/onelo-swift", branch: "main")
]
```

Or in Xcode: **File → Add Package Dependencies** → paste the URL above.

## Quick Start

Initialize with your publishable key from the Onelo dashboard:

```swift
import OneloSwift

let auth = OneloAuth(config: OneloConfig(publishableKey: "onelo_pk_live_..."))
```

### SwiftUI

```swift
@main
struct MyApp: App {
    @StateObject private var auth = OneloAuth(
        config: OneloConfig(publishableKey: "onelo_pk_live_...")
    )

    var body: some Scene {
        WindowGroup {
            if auth.isRevoked {
                Text("This version of the app is no longer supported. Please update.")
            } else if !auth.isReady {
                ProgressView()
            } else if auth.currentSession == nil {
                LoginView().environmentObject(auth)
            } else {
                ContentView().environmentObject(auth)
            }
        }
    }
}
```

## API

### Sign Up

```swift
let needsVerification = try await auth.signUp(email: "user@example.com", password: "password")
// Returns false if user is immediately signed in (email confirmation disabled)
// Returns true if email verification is required
```

### Sign In

```swift
let session = try await auth.signIn(email: "user@example.com", password: "password")
print(session.user.id)
```

### Sign Out

```swift
try await auth.signOut()
```

### Password Reset

```swift
try await auth.resetPassword(email: "user@example.com")
```

### Magic Link

```swift
try await auth.signInWithMagicLink(email: "user@example.com")
```

### Refresh Session

Sessions are restored automatically on app launch. You can also refresh manually:

```swift
let session = try await auth.refreshSession()
```

## Published Properties

| Property | Type | Description |
|---|---|---|
| `currentSession` | `OneloSession?` | Active session, `nil` if not signed in |
| `isReady` | `Bool` | `true` once SDK has initialized |
| `isLoading` | `Bool` | `true` during async auth operations |
| `isRevoked` | `Bool` | `true` if the publishable key was revoked or the app was deleted |

## Session

```swift
if let session = auth.currentSession {
    print(session.user.id)
    print(session.user.email ?? "")
    print(session.accessToken)
    print(session.isExpired)
}
```

## Security

- Tokens are stored in the Keychain with `kSecAttrAccessibleWhenUnlocked`
- PKCE (Proof Key for Code Exchange) is used automatically for all auth flows — no client secret needed in your app
- All auth requests go through the Onelo backend, which validates app membership and tracks `last_seen_at`

## Error Handling

```swift
do {
    try await auth.signIn(email: email, password: password)
} catch let error as OneloError {
    switch error {
    case .serverError(let msg):
        print(msg) // e.g. "Incorrect email or password"
    case .notAuthenticated:
        print("Not signed in")
    case .invalidPublishableKey:
        print("Check your publishable key in the Onelo dashboard")
    default:
        print(error.localizedDescription)
    }
}
```
