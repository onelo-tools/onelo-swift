# OneloSwift

Swift SDK for Onelo authentication. Supports iOS 16+ and macOS 13+.

## Installation

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/onelo/onelo-swift", from: "0.1.0")
]
```

## Usage

```swift
import OneloSwift

let auth = OneloAuth(config: OneloConfig(
    supabaseURL: URL(string: "https://your-project.supabase.co")!,
    supabaseAnonKey: "your-anon-key"
))

// Sign in
let session = try await auth.signIn(email: "user@example.com", password: "password")
print(session.user.role) // .creator

// Sign up
let needsVerification = try await auth.signUp(email: "new@example.com", password: "password")

// Reset password
try await auth.resetPassword(email: "user@example.com")

// Sign out
try await auth.signOut()
```

Tokens are stored in the Keychain automatically with `kSecAttrAccessibleWhenUnlocked`.
