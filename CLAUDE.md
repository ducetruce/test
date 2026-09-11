# OpenRing

A local iOS replacement for the Oura app, so the ring's data is usable without a
subscription. Scores are computed on device from raw measurements; the Oura cloud is one of
three data sources, not the brain.

## Build and test

Xcode 16+ opens this (`objectVersion = 77`). Deployment target iOS 17.0, Swift 5 language
mode. Verified building clean — no errors, no warnings — under Xcode 27.0 (27A266a) on
macOS 27. **Do not accept Xcode's offer to upgrade the project format** — CI runs whatever Xcode
ships on `macos-latest`, and bumping the format can leave the runner unable to open the
project, which removes the fallback build path.

```sh
xcodebuild test -project OpenRing.xcodeproj -scheme OpenRing \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  CODE_SIGNING_ALLOWED=NO
```

CI (`.github/workflows/ci.yml`) runs the same on every push to `claude/**` and `codex/**`,
picks whatever iPhone simulator the runner image has, and puts its diagnosis in the **last**
lines of the job log — artifact downloads redirect to blob storage that is not always
reachable, so the log tail has to carry everything. Putting `[ipa]` anywhere in a commit
message also archives an unsigned IPA for third-party signing (Signulous).

`OpenRing.xcodeproj` is checked in. `project.yml` is a fallback: `xcodegen generate` rebuilds
the project if it ever goes stale.

## Layout

- `Networking/` — OAuth2 (`OuraAuth`, an actor because refresh tokens are single-use),
  the API client, DTOs. `OuraDTO.Page` decodes rows leniently: one malformed record must not
  discard an endpoint's entire history.
- `Storage/` — `Database` (in-memory model + per-endpoint sync reports), `SyncEngine`
  (orchestrates a sync, builds the warnings), `LocalStore` (disk), `Keychain`.
- `Scoring/` — the actual value. Piecewise-linear contributor curves fitted against 177 real
  days, with a chronological train/test split. Held-out agreement with Oura: sleep within 5
  points on 88% of days, readiness 59%, activity 61%.
- `Ring/` — BLE. Reverse-engineered protocol, `tag | length | payload` framing, AES-128-ECB
  nonce challenge, paged `GetEvent` drain.
- `Views/` — SwiftUI. `Components/Cards.swift` holds the shared card vocabulary.

## Conventions

Comments explain *why*, especially where the code looks wrong but isn't. Several exist
because the obvious version was tried and failed; don't delete one without understanding what
it is protecting. Same for defensive branches — check the comment before simplifying.

## Hard-won specifics

**Never guess at an external API.** Every expensive bug in this project came from inventing a
string and reasoning about the consequences instead of checking. Oura documents exactly eight
scopes: `email personal daily heartrate workout tag session spo2`. `spo2Daily` is the old
name and is silently ignored — it was requested for weeks, which made blood oxygen return 401,
which was then misdiagnosed as a plan limitation. There is no `ring` scope; it was invented
here. Settings now lists the scopes Oura reports granting, so this class of question is
answered by reading the screen.

**A 401 that survives a refresh means "this account cannot read this"** — not "the plan
excludes it". Those differ, and conflating them is what hid the scope bug.

**A failed Keychain write is not automatically a locked device.** Same lesson as the 401,
found the same way. `Keychain.set` returned a bare `Bool`, so every cause looked alike, and
the message told the user to unlock a device that was never locked — the real status was
`errSecMissingEntitlement` (-34018). `Keychain.WriteFailure` now carries the `OSStatus` and
the message names the cause. Distinct causes that share a symptom must not be collapsed: the
wrong explanation sends people to look in the wrong place, which cost an afternoon here.

**Nothing this project builds itself can use the Keychain.** CI builds unsigned
(`CODE_SIGNING_ALLOWED=NO`) and releases are signed by a third party, so no build produced
here carries an `application-identifier` entitlement — and without one every Keychain write
returns -34018. The consequence is larger than it sounds: a locally built app can never sign
in, because credentials cannot be stored, so `isConnected` stays false and `RootView` shows
onboarding forever. **The five tabs are unreachable on a simulator unless the build is signed
with a real development team.** `DEVELOPMENT_TEAM=<id>` on the `xcodebuild` command line is
enough, and keeps the project file clean. Do not try to hand-roll it: ad-hoc re-signing with a
fabricated `application-identifier` is refused at launch ("Launchd job spawn failed"), with or
without a plausible team prefix. Both were tried.

For the same reason no test can round-trip the Keychain. `KeychainFailureTests` asserts on the
status-to-message mapping instead, which is the part that runs unsigned.

**Endpoint date windows are not uniform.** `sleep` and `daily_activity` exclude the
`end_date` day; `daily_readiness` includes it. `OuraClient.WindowStyle` encodes this. Getting
it wrong silently drops today's data.

**Swift traps that have bitten here:** `Character` is a grapheme cluster, so `"\r\n"` matches
neither `"\r"` nor `"\n"` — normalise line endings up front. Key paths cannot address tuple
elements, so Swift Charts `id:` needs a real `Identifiable` struct. `Codable` throws on a
missing key rather than using the property's default, so adding a field to a persisted type
needs an explicit migration.

## State of play (September 2026)

Working end to end: OAuth sign-in, 177 days synced, local storage, on-device scoring, full
UI, installed on the owner's phone.

Recently merged from a parallel `codex/openring-audit-v2` branch — an audit that found six
real defects: non-atomic Keychain writes, a refresh coalescer that did not coalesce (actors
are re-entrant across `await`), scopes recorded from the request rather than the grant, a
missing credential migration, BLE batches acknowledged before they were durable, and a ring
key that could be lost mid-claim. Two things from that branch were reverted: a corrupt app
icon PNG (473 of 1024 scanlines; Xcode's asset compiler accepted it, so CI stayed green and
iOS rendered half of it black), and the loss of the previous-refresh-token fallback.

**Open questions:**

- `ring_configuration` returns a 401 that survives a refresh while every other endpoint
  accepts the same token, and no documented scope covers it. The Settings "Ring" section can
  therefore never populate from the cloud. Unresolved whether this is a plan boundary or an
  endpoint no OAuth grant reaches. BLE can read battery and ring details directly.
- `Views/SettingsView.swift` is the one view not converted to the card vocabulary — 18 raw
  `Section` blocks in a system `List`. This is arguably correct (settings screens should look
  like settings screens) and the seam is deliberate until someone decides otherwise.
- BLE event-body mapping is mostly undone. Only signals with published scaling rules are
  decoded; the rest are not guessed at. A protobuf schema at
  `com/ouraring/ringeventparser/Ringeventparser.java` is a better lead than empirical mapping.
- The activity curve fit omitted the `recoveryTime` contributor and should be refitted.
- Subscription-gated for real, confirmed against the account: cardiovascular age, resilience,
  VO₂ max.
