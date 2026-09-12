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
- `Scoring/` — the actual value. Piecewise-linear contributor curves fitted against real days
  with a chronological train/test split. Held-out agreement with Oura, measured by rolling
  origin over six chronological splits of the September 2026 export (152 sleep, 152 readiness,
  148 activity paired days): **sleep 93.0% of days within 5 points, readiness 67.7%, activity
  66.0%.** Sleep's number moved from 86.8% the same week, when `timing`'s curve was refitted —
  see the hard-won specifics below before touching any of these again; two different curves
  fitted from the same export in the same sitting landed on opposite verdicts.

  Older figures in this file (88%/59%/61%, then briefly 71.3% for activity alone) could not be
  reproduced and are gone. Quote the method with the number from now on — a bare percentage
  here turned out not to be checkable, twice.
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

**Nothing this project builds itself can use the Keychain on a simulator — not even with a
real signing team, and there is no command-line fix.** CI builds unsigned
(`CODE_SIGNING_ALLOWED=NO`) and releases are signed by a third party, so no CI or release build
carries an `application-identifier` entitlement — every Keychain write returns -34018, and
since credentials can't be stored, `isConnected` stays false and `RootView` shows onboarding
forever. A locally-added personal team (Xcode → Settings → Accounts) does not fix this for a
*simulator* destination: Xcode 27 hard-forces ad-hoc "Sign to Run Locally" signing for every
`iphonesimulator` build, and nothing on the `xcodebuild` command line overrides it —
`DEVELOPMENT_TEAM=<id>`, `CODE_SIGN_IDENTITY="Apple Development"`, and even the most specific
form, `CODE_SIGN_IDENTITY[sdk=iphonesimulator*]=...`, were all tried and all still produced
`Signing Identity: "Sign to Run Locally"` with an empty entitlements dictionary. Manually
re-signing an already-built simulator `.app` afterwards doesn't work around it either: it
breaks launch outright ("Launchd job spawn failed", POSIX 163) — confirmed with *both* an
ad-hoc identity *and* a real one, so it isn't about which identity signs it, and confirmed even
when the entitlement was verified present in the resulting binary. Three structurally distinct
approaches, three hard failures — this is being recorded as settled, not as "still worth
retrying differently."

**A real *device* destination does not have this problem.** `xcodebuild build -destination
'id=<udid>' -allowProvisioningUpdates DEVELOPMENT_TEAM=<id>` against a connected iPhone mints a
genuine `Apple Development` certificate and a real provisioning profile from Apple's own
servers — no manual entitlements file needed, and `xcodebuild install` onto that device works
normally. If the five tabs need to be reached outside of the signed release, that's the way in:
a debug install to a connected phone, not the simulator.

Also worth knowing: the release build's *actual* bundle identifier on-device is
`com.openring.local`, not `com.example.openring` as checked in here — third-party signing
services typically can't use the original developer's identifier under their own certificate,
so Signulous rewrites it. The two are unrelated apps to iOS: installing a locally-signed debug
build (`com.example.openring`) alongside the Signulous release is safe and does not touch or
overwrite the release's data.

**There is now a way to see the five tabs on the simulator too, despite all of the above** —
`OpenRing/App/PreviewFixtures.swift`. Launch with the `--preview-fixtures` argument
(`xcrun simctl launch booted com.example.openring --preview-fixtures`) and `OpenRingApp` skips
onboarding entirely, loading two weeks of synthetic data instead of touching the Keychain or
network. `#if DEBUG`-only, so it cannot exist in a release build, and gated on the explicit
argument on top of that, so an ordinary debug run still goes through real onboarding. One day
in the fixture is deliberately left empty, to see the real empty states without a real account.

Getting this working surfaced a second bug worth remembering: setting `isConnected` and
`hasCompletedOnboarding` in the fixture loader was not enough on its own —
`.onChange(of: scenePhase)` fires the instant the scene activates and unconditionally calls
`refreshConnection()`/`loadFromDisk()`, silently overwriting both back within milliseconds.
That handler needed the same `--preview-fixtures` guard. The symptom was exactly this class of
bug's usual tell: internal state visibly correct in the logs the instant after it was set, UI
still wrong moments later — something else was still running.

For the same reason no test can round-trip the Keychain in CI. `KeychainFailureTests` asserts
on the status-to-message mapping instead, which is the part that runs unsigned.

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

Of those six, only the BLE-durability one had no regression test — a real, previously-fixed
defect that a refactor could have silently reopened. `RingConnectionType`
(`Ring/RingConnection.swift`) extracts exactly what `RingSyncService.sync` needs from a
connection, since `RingConnection` is `final` and wired directly to `CBCentralManager` with no
seam a test could use otherwise. `RingSyncDurabilityTests` uses it to prove two things without
real Bluetooth: a batch is durable before it's acknowledged, and — the case that actually
discriminates a broken ordering from a correct one — a batch that fails to save is never
acknowledged at all. Confirmed by deliberately reordering the two lines in `sync` and watching
the second test fail, then reverting; the first test alone would not have caught it, since it
doesn't force a save failure.

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
- **`CalibrationExport` had its own copy of the sleep-timing calculation, and it had drifted
  from the real one.** `midpointDeviationHours` compared each night against a hard-coded 3am
  reference instead of `ScoreEngine.habitualMidpointHour` — the personal rolling baseline the
  live `timing` contributor actually reads once 5 nights of history exist. On the September
  2026 export the two disagreed by up to ~46 points of implied contributor score, one-sided,
  not a symmetric wobble. Every row exported before this fix has a `midpoint_dev_hr` that does
  not describe what the app's own score was computed from — reconstructing or fitting `timing`
  against an export taken before this fix will be fitting the wrong input. Fixed by having the
  export call the engine's own method instead of a second copy of the formula; watch for this
  *class* of bug elsewhere before trusting a reconstruction — a private helper that reimplements
  something the engine already computes is a fork waiting to diverge silently.

- **`timing`'s curve was refitted in September 2026, against the first export its real input
  could be reconstructed from, and it closed almost the entire sleep bias.** The suspicion
  from the affine test below was right: the old curve was far too generous near zero
  deviation. Held-out MAE 3.25 → 2.19, within-5 86.8% → 93.4%, bias +2.32 → +0.07 — robust at
  every one of six chronological splits, by a substantial margin each time (+0.78 to +1.07),
  not the noise-level deltas that sank `trainingFrequency` and `recoveryIndex` in the same
  round. With bias landing almost exactly at zero, the affine correction below is superseded —
  there's nothing left for a global shift to buy.

  Earlier evidence (kept for the reasoning trail): fitting `a*mine + b` against `sleep_oura`
  on the pre-fix export — using only the exported score columns, so unaffected by the
  `midpointDeviationHours` bug above — took MAE from 3.16 to 2.54, holding at every split. The
  same affine test on readiness and activity found nothing robust, which is why the bias was
  suspected to be sleep-specific and contributor-specific rather than a general modelling gap.

- `trainingFrequency` (activity) and `recoveryIndex` (readiness) were fitted from the same
  September 2026 export as `timing` and **did not show a robust improvement** — held-out MAE
  moved by ±0.03 to ±0.18 depending on the split, sign flipping rather than holding, unlike
  `timing`'s substantial one-directional gain. Left unchanged. Both curves are still only
  guesses (`trainingFrequency` counts days whose high+medium activity minutes clear a
  threshold; `recoveryIndex` reads where in the night the heart rate bottomed out), so this
  isn't "confirmed fine" — it's "not yet distinguishable from noise at ~150 days." More history
  is the only lever left for either.

  `recoveryTime` (activity) was fitted once, in September 2026, against 142 paired days: the
  well-recovered level moved from 100 to 88. It was backed out again the same day — it raised
  the share of days within 5 points of Oura (66.4% → 71.3% held-out) but left mean error
  unchanged at ~4.9 and made bias slightly worse, so days were crossing a threshold without
  the score getting more accurate. Fitting all 29 activity parameters at once looked better on
  average (+3.5pt within-5) but its spread crossed below baseline — ~100 training days will
  not support that many free parameters. Separately, its `lastNightScore ?? 80` fallback —
  a fabricated "fine" entering the score whenever there was no sleep record — is fixed: the
  contributor now drops out and lets `weightedScore` renormalise around it, rather than assume.
  Whatever is fitted next here, judge it on mean error,
  not the within-5 count; the two disagreed once already.
- Subscription-gated for real, confirmed against the account: cardiovascular age, resilience,
  VO₂ max.
