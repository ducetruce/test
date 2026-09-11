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
  with a chronological train/test split. Activity agreement with Oura is **71.3% of days
  within 5 points**, measured by rolling origin over six chronological splits of the 142
  usable paired days in the September 2026 export.

  The older figures in this file (sleep 88%, readiness 59%, activity 61%) could not be
  reproduced from that export — the same measurement puts activity at 66.4% before the
  September 2026 refit, not 61%. Either the original fit used a differently filtered set or
  the numbers went stale. Quote the method with the number from now on: a bare percentage
  here turned out not to be checkable.
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

- **Sleep is a validated ~20% MAE win away, but nothing has shipped for it yet.** Fitting
  `a*mine + b` against `sleep_oura` (using only the exported score columns, unaffected by the
  bug above) took mean absolute error from 3.16 to 2.54, holding at every one of six
  chronological splits tested — a real, robust, general overestimate of a few points, not
  noise. `a` lands near 1.0 and `b` near −4 to −7, i.e. the app is consistently ~5 points too
  generous. The same affine test on readiness and activity found nothing robust — readiness
  got slightly worse, activity was unstable across splits — so this is specific to sleep.

  Not shipped: the likely cause is exactly the contributor whose export was just fixed
  (`timing`, weight 0.10, directionally consistent with the size of the bias), but that can't
  be *proven* from data collected under the old bug. Applying a global affine correction now,
  then later fixing the `timing` curve itself once clean data exists, would double-correct.
  Get a fresh export first — one build carries this fix, the earlier `trainingFrequency`
  columns, and the `recoveryIndex` column below, so one `[ipa]` round trip unblocks all three —
  then fit `timing` directly. If it doesn't close the gap on its own, the affine correction is
  still there as a fallback, now checkable against clean data.

- `trainingFrequency` (activity) and `recoveryIndex` (readiness) still cannot be fitted from
  any export taken so far. Both curves have only ever been guesses: `trainingFrequency`
  counts days whose high+medium activity minutes clear a threshold, and `recoveryIndex` reads
  where in the night the heart rate bottomed out, and neither input was ever in
  `CalibrationExport`. The columns are now (`high_activity_min`, `medium_activity_min`,
  `hr_minimum_position`), but only a build carrying them can produce a CSV that includes them
  — waits on the same `[ipa]` round trip as the `timing` fix above.

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
