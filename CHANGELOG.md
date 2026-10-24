# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [3.105.0] — 2026-10-23

### Added

- `onelo.affiliates.capture(url:consent:)` captures an Affiliate referral from the link that opened your app
  (#929). It reads `?ref=<code>` or `?onelo_click=<id>`. Without consent nothing
  is stored on the device. With consent the click is kept and tied to the user
  who signs in, so their purchase is attributed whichever checkout opens.

## [3.104.0-staging] — 2026-10-03

### Added

- Marketing Consent for your own screens (#818). `OneloAuth.signupMarketingConsent` (`OneloSignupMarketingConsent`: `asked`, `text`, `language`) tells a custom sign-up screen whether to show the optional checkbox and with what text, from `/api/sdk/config` asked in the device language. `signUp(email:password:marketingConsent:)` sends the consent (and its language) only when ticked; `signUp(email:password:)` is unchanged. `OneloWaitlist.join(_:email:slug:consent:)` takes `OneloWaitlistConsent(marketing:custom:)`.

## [3.103.0-staging] — 2026-10-03

### Added

- Email Verification (#819). `OneloUser` carries `emailVerified` and `accessReason` (`"email_unverified"` when the app is withheld for it), decoded from the server and kept in the stored session. When the parent App requires Email Verification, `isAllowedIn` stays false until the user opens the link; `OneloAuthView` shows Onelo's "check your inbox" page, which resends and hands the session back by itself. Apps with their own screen get `resendVerificationEmail(redirectTo:)` (returns `OneloVerificationResend`) and `confirmEmail(token:)` (the `onelo_verify_token` from their landing; refreshes the signed-in session afterwards); new `OneloError` cases `verificationRateLimited`, `emailVerificationOff`, `invalidVerificationToken`, `invalidVerifyRedirect`. `revalidateEntitlement()` refreshes `allowedIn`, `emailVerified` and `accessReason` together.

## [3.102.0-staging] — 2026-10-03

### Added

- A signed-in user's feedback report names a verified reporter (#820). With an Onelo Auth session, `feedback.open()` / `fetchHostedURL()` send the user's access token (`Authorization: Bearer`) on `/api/sdk/feedback/initiate`; Onelo stores the report with that user and `reporter_verified=true`, so no `userId` is needed. A refused token is refreshed and retried once; refused again, the form still opens without it. Signed out, the report stays anonymous; an explicit `userId` without a session is still an unverified label.

## [3.101.0-staging] — 2026-10-01

### Changed

- The session now lives in a Keychain store scoped to the app (#740). Before, every app on a Mac shared the service `com.onelo.auth` in the file-based keychain, so apps such as Turingo kept showing "wants to use your confidential information stored in com.onelo.auth", and "Always Allow" did not stick. The service is now `com.onelo.auth.<bundle id>`: two Onelo apps on one Mac keep separate sessions.
- On iOS, and on macOS when the app is signed with a provisioning profile that grants its App ID or `keychain-access-groups`, the session is stored in the data protection keychain (`kSecUseDataProtectionKeychain`), in the app's default access group. Storing, restoring and clearing it causes no prompt, also across rebuilds.
- A macOS app without that entitlement (unsigned, ad-hoc, or Developer ID without a provisioning profile) uses the file-based keychain under the same per-app service. A data protection call that answers `errSecMissingEntitlement` switches to this fallback for the launch. An ad-hoc or unsigned rebuild can still prompt; macOS decides. The README's "Session Keychain" section says what an app needs for the prompt-free path.

### Added

- One-time migration from the shared `com.onelo.auth` store. On the first launch after the upgrade, the SDK reads only the old refresh token, once, and restores the session from it with one refresh: a signed-in user stays signed in. On macOS that read may prompt once; it is never retried. The old items are deleted, best effort, only after the server accepts that migrated token. A token the server refuses (another app's) is cleared from this app and the old items are kept for their owner.
- `hasStoredSessionSync()` is also true for a store that holds only a refresh token, so the launch shows the restore splash for a migrated session.

### Fixed

- An offline launch with no cached config no longer leaves `isRestoringSession` true for the whole launch.

## [3.100.2-staging] — 2026-10-01

### Fixed

- `ready()` right after a sign-in or a user switch now waits for the signed-in user's snapshot (#731). The session watcher loads the new identity a turn after the session changes, and a host that awaited `ready()` from `isAllowedIn` or `currentSession` ran first: `ready()` returned at once on the previous identity's confirmation, so gated UI opened with the anonymous or the previous user's features. `Onelo` now tells Features about the signed-in user synchronously on every session change: `isSnapshotConfirmed` turns false at once, `ready()` waits, and a late confirmation for the previous identity releases nobody.

## [3.100.1-staging] — 2026-10-01

### Fixed

- A rejected publishable key now ends the session restore at launch (#732). The stored session is cleared as before and `isRevoked` becomes true. `isRestoringSession` now also becomes false, so Features load the signed-out identity. Before this change they waited all launch for an identity that never came: `ready()` timed out and every `refresh()` waited 10 s and then did nothing.

### Changed

- Session storage sits behind an internal storage seam (#732). Apps keep the same store: `KeychainStorage(service: "com.onelo.auth")`, with no migration of stored sessions and no public API change. The SDK's own test suite now uses an in-memory store and never touches the real Keychain. Running `swift test` no longer raises the "xctest wants to use … com.onelo.auth" dialog or hangs on it. A guard test fails when a test builds the SDK over the real Keychain.
- New `Onelo`-level launch tests: a launch with a stored session renders the restored user's complete, confirmed snapshot first; a restore that never finishes keeps the stored user's snapshot and never resolves anonymously.

## [3.100.0-staging] — 2026-10-01

### Fixed

A feature snapshot now belongs to one identity (onelo-swift-staging#1). Gated UI could open with only some features, filling in after several opens.

- A `/resolve` answer is applied only when the identity that sent it is still current. A late anonymous answer (from the activation refresh at launch, before the session was restored) or a previous user's answer is dropped. It is no longer applied in memory or persisted under the current user's key.
- A signed-in user whose token is refused, even after a refresh, no longer gets the anonymous snapshot in place of their own. `/resolve` makes no anonymous retry for a signed-in user. The Event Stream's anonymous fallback connection no longer replaces their snapshot.
- A new identity starts from its own persisted snapshot or from an empty one. It no longer starts from the previous identity's snapshot.
- `since_version` is sent only for a version the server confirmed for the current identity in this session. The version is app-wide, so a persisted snapshot used to be answered `up_to_date` and kept even when it was wrong for this user.
- At launch with a stored session, the anonymous identity is no longer loaded ahead of the restore. The stored user's persisted snapshot renders at once, unconfirmed. `refresh()` and the lifecycle refresh wait for the restore (at most 10 s). The discovery batch-ping no longer delays the identity's own load.
- `ready()` now means "the snapshot is confirmed for the current identity". It resets on every identity change. It ends on a stream snapshot or a `/resolve` for that identity, and each identity change starts that `/resolve` immediately.

### Added

- `OneloFeatures.isSnapshotConfirmed`: an observable form of the same signal.
- README: "How an app should start" — await `ready()` before presenting gated UI, and build menus in `menuNeedsUpdate` and on `subscribe`.

## [3.99.0-staging] — 2026-10-01

### Added

- A magic link sent from the hosted sign-in page and opened on another device now completes in the app after the person types the code shown there (#541). `presentHostedSignIn` waits on its sheet. When the same-device link reaches the app through `.onOpenURL` → `handleAuthCallback`, the sheet finishes with that session and closes instead of hanging.

### Fixed

- `presentHostedSignIn` now exchanges the returned code with the verifier of the flow it bound on `/auth/initiate`. It used to send the `/api/sdk/config` verifier, which the backend refused with "PKCE verification failed".
- A refused code exchange now reports the backend's reason (`detail`, e.g. "code_verifier required" or "PKCE verification failed") instead of a bare "Code exchange failed". There is one attempt, no retry, and the stored verifier is kept.

## [3.98.0-staging] — 2026-09-29

### Changed

- SDK chrome is painted from the app's Branding (#681). New `OneloBrandTokens` (decoded from `brand_tokens` on `/api/sdk/config` and the store / portal / upgrade initiate responses, cached in the keychain for the first paint) and `OneloAuth.brandTokens`. The retry "Sign In" button, skeletons and shimmer, the "Signing you in…" cover, the portal and feedback grounds, skeletons, error page and ✕ now use it. `OneloAuthConfig` colours and `cornerRadius` are optional: `nil` (the default) means "use the brand tokens", an explicit value still overrides; `.default` and `.oneloBranded` compile unchanged and both follow the Branding. Before config → neutral, never Onelo orange. Feature badges keep their named status colours.

## [3.97.1-staging] — 2026-09-29

### Fixed

- A standalone `OneloFeatures` no longer reconnects its Event Stream every two minutes on a healthy connection (#368). The server keeps the stream alive with a `: keepalive` comment every 30 s, but the parser dropped comment lines, so the 90 s staleness check saw only named events and cycled an idle stream. The parser now surfaces a comment as a comment frame; `OneloEventStream` reports every frame (event or keepalive) as activity and dispatches only named events, so no handler ever receives a keepalive. A stream that delivers nothing for 90 s is still reconnected.

## [3.97.0-staging] — 2026-09-29

### Fixed

- Social sign-in in `OneloAuthView` no longer shows the idle sign-in form while it finishes (#666). When Google, GitHub or Apple returns a code from the system sheet (`ASWebAuthenticationSession`), the hosted page is covered with "Signing you in…" on the branding background until the code exchange settles, then the app (or the store) appears. The cover is removed on failure (retry screen) and never shown for a cancelled sheet or for password sign-in. Native twin of the hosted page's pending state on the web (#543).

## [3.96.0-staging] — 2026-09-29

### Fixed

- After a purchase or a plan switch in `OneloAuthView`'s store, the portal container (`openCustomerPortal` / `openUpgrade(forPlan:)`) or a system-browser store (`handleAuthCallback` / `handlePortalCallback`), the app shows the new plan at once instead of waiting for the Event Stream (#659). Every successful hand-back forces `features.refresh(force: true)` and `revalidateEntitlement()`; a `plan_switch_pending` switch is re-checked after 1, 2, 4, 8 and 15 s until the features change. `handlePortalCallback` now also accepts a store purchase / switch hand-back (returns true). New public `OneloPlanChange`; one refresher (`PlanChange.swift`), wired by `Onelo`.
- The entitlement now follows a plan change live (#635): `OneloAuth` listens for the Event Stream's per-user `paywall.access_changed` frame and calls `revalidateEntitlement()`.

## [3.95.0-staging] — 2026-09-28

### Fixed

- The access-gate store no longer signs the user out when its link dies (#619). A `token_expired` hand-back on an `exit=signout` surface re-resolves on the same session, so the gate reopens the store on a fresh link; only `invalid_token` (the ✕ / "Use a different account") signs out, as before.
## [3.94.0-staging] — 2026-09-28

### Added

- The feedback sheet and window (`feedbackSheet`, `openAsWindow`) now keeps the reporter when the form was left open longer than its 30-minute reporter token (#622). On submit the hosted form asks the SDK for a fresh token (`onelo:renew_request`, kind `feedback`); the SDK calls `/api/sdk/feedback/initiate` again with the same options and hands the new form URL back, and the report is sent with its reporter. Before, such a report was stored without a reporter and nobody was told.

## [3.93.0-staging] — 2026-09-28

### Added

- `OneloPortalIntent.changePlan` opens the Customer Portal straight into the plan picker, the same as `@onelo/js` (#606). It is available on `auth.openCustomerPortal(intent:)`, `auth.openCustomerPortalInBrowser(intent:)`, `auth.initiateCustomerPortal(intent:)` and `OneloCustomerPortalView(auth:intent:onDismiss:)`. The hosted portal asks the backend where the change goes.
- `onelo.features.subscribe { … }` is a change callback for AppKit / UIKit code, the same as `features.subscribe` in the JS, Electron and React Native SDKs (#606). It fires on every feature-snapshot change, including a plan change pushed over the Event Stream, and returns a closure that removes the listener.
- `auth.openCustomerPortal(intent:)` presents the portal in the SDK's own window (macOS) or sheet (iOS). No presentation anchor is needed (#606).

### Changed

- `onelo.openUpgrade(forPlan:)` opens the upgrade in the SDK's own portal window instead of the system browser (#606). The store's hand-back (a purchase, a plan switch, or "Return to app" on a spent link) closes the window, and the entitlement is re-read before the call returns.
- `auth.openCustomerPortal(from:)` is deprecated. It now presents the same SDK window instead of `ASWebAuthenticationSession`, which never received the store's hand-back. The `context` argument is ignored. The accessory-app fallback to the system browser is gone, because the SDK window works in menu-bar apps.
- The embedded portal relay re-expresses the store's postMessage hand-back (`onelo:code`, `onelo:done`, `onelo:cancel`) as `onelo://callback?…` in the deep-link wire format, and `classifyHandBack` decodes it (#627). The relay no longer classifies anything itself. "Return to app" on a spent store link now closes the portal. The `onelo://checkout-complete` sentinel is retired.

## [3.92.0-staging] — 2026-09-28

### Changed

- One decoder for every `<scheme>://callback` hand-back (#615): `OneloAuthView` and `handlePortalCallback` (every portal presentation) classify `?code=`, `?source=store&event=…`, `?source=portal[&event=…]` and `?error=` through the same function. `event=plan_switch_pending` (a paid switch still being updated) is a success like any other plan switch. `handlePortalCallback` now requires the canonical `<scheme>://callback` host.

## [3.91.0-staging] — 2026-09-28

### Added

- `OneloCustomerPortalView` renews an expired portal token instead of showing "Link expired" to a signed-in user (#613 / #614). The portal relay turns the page's self-posted `onelo:renew_request` into `onelo://renew-portal?request_id=…`; the view calls its URL provider again (`auth.initiateCustomerPortal()`) and posts the reply back into the page. Signed out → `renew_failed` / `not_authenticated`.

## [3.90.0-staging] — 2026-09-28

### Fixed

- After a month↔year plan switch or a scheduled downgrade, `OneloCustomerPortalView` dismisses by itself (#599): the portal relay forwards the store's code-less `onelo:done` hand-back like a finished purchase. `OneloAuthView` treats `<scheme>://callback?source=store&event=plan_switched|switch_scheduled` as a success and re-resolves the flow, instead of showing "Auth callback missing code parameter". The new plan arrives over the Event Stream.

## [3.89.2-staging] — 2026-09-28

### Fixed

- `OneloAuthView`: the "Sign In" retry button shown after a cancelled or failed sign-in now uses your app's Branding brand colour (`primary_color` from `/api/sdk/config`), instead of Onelo orange (#601). Neutral grey when the app has no brand colour. Removed the unused `HostedSignInButton` view.

## [3.89.1-staging] — 2026-09-27

### Fixed

- `OneloCustomerPortalView`: a purchase started from the portal ("Change plan", "View plans", upgrade) now shows the store's "Taking you back…" success screen for about 1.5 s and then dismisses the portal, instead of leaving the buyer on "You're in!" (#592). The new plan arrives over the live entitlement stream.

## [3.89.0-staging] — 2026-09-26

### Changed

- A refused session refresh now says what happened (#548). New `OneloError` cases: `.sessionEnded` ("Your session ended — please sign in again") for `session_compromised`, `session_expired` and `session_invalid`; `.userRevoked` ("suspended", sets `isUserRevoked`) only for `banned`; `.noActivePlan` for `no_plan_available`. Previously these surfaced as `.serverError("HTTP 401")` / `"HTTP 403"` and a ban did not set `isUserRevoked`.
- Uncaught crashes captured by Monitor carry `meta.origin` (`onelo_sdk` or `app`), read from the mangled module of the first non-runtime frame.
- A transient refresh failure — offline, a lost response, `429`, or a `5xx` including the new `503 refresh_unavailable` — no longer clears the Keychain session. `refreshSession()` throws `.networkError` and the refresh is retried after 5 s, 10 s, 20 s, 40 s, then every 60 s.

## [3.88.1-staging] — 2026-09-25

### Changed

- Corrected a source comment in `OneloAuthView`: the Google and GitHub authorize URLs both carry `prompt=select_account` (set by the server), so both show their account chooser on every sign-in (#321). Apple has no such parameter. No behaviour change in the SDK.

## [3.88.0-staging] — 2026-09-25

### Changed

- Features calls now prove the signed-in user with the Onelo access token (#519). Resolve, batch-ping, module-token and the Event Stream send `Authorization: Bearer <access token>`, read fresh for every call and every reconnect. A refused token (`401 invalid_user_token`) is refreshed and retried once; if it is refused again, that call is made without a user and a warning is logged. A refused module-token request fails as not authenticated instead.
- A refused token triggers at most one session refresh until a token is accepted again or the user changes, so a server that keeps refusing cannot cause a refresh loop.
- `userIdHash` is no longer sent. `identify()` and its `userIdHash` argument still compile but are deprecated: the signed-in Onelo user is used automatically.
- `OneloFeaturesError.secureModeRequired` and `.invalidUserHash` are deprecated and never thrown: the server no longer returns them. `refreshSession()` is now single-flight, so overlapping refreshes share one request.
## [3.98.1-staging] — 2026-09-29

- Keep the shared registry status palette and safe font-stack parser aligned with the other SDKs.
- The previous minor release intentionally made `OneloAuthConfig` colour and radius overrides optional; callers that relied on concrete stored properties must pass explicit overrides or use the resolved token style.
