# OpenRing

A local iOS app for your Oura ring data. It keeps a full copy of your data on your phone and
**computes Sleep, Readiness and Activity scores on-device**, so the numbers keep working
whether or not Oura's cloud is still scoring your account.

Not affiliated with, endorsed by, or supported by Ōura Health Oy.

---

## Read this first: what a local app can and cannot do

Being honest about the boundaries, because they shape what this app is:

- **The ring itself is not readable directly.** Oura's Bluetooth protocol is undocumented and
  the payloads are encrypted. There is no supported way for a third-party app to pull raw
  samples off the ring. Every open-source Oura project, including this one, goes through
  Oura's cloud API.
- **So this app needs a personal access token.** The ring syncs to Oura's servers via the
  official Oura app on your phone; OpenRing then downloads your data from the Oura API with a
  token you generate yourself, and stores it locally forever.
- **What this replaces is the paywalled analysis, not the ring's cloud.** If your membership
  lapses, the cloud may stop returning computed scores. OpenRing does not depend on those:
  it derives its own scores from the raw signals (sleep staging, heart rate, HRV, temperature
  deviation, MET minutes), which are what you actually paid a subscription to have
  interpreted. Where Oura still returns a score, it is shown alongside as a comparison.
- **Keep the official Oura app installed.** It is what carries data from the ring to the
  cloud over Bluetooth. OpenRing replaces the app you *look* at, not the sync path.

Whether a lapsed membership still returns full data on your account is something only your
account can tell you — connect a token and see. Everything the API does return is stored and
scored locally.

## What you get

| | |
|---|---|
| **Today** | Three score rings, the contributor breakdown behind each one, and the night's highlights |
| **Sleep** | Hypnogram, stage split, nightly heart-rate and HRV curves, 14-night history |
| **Activity** | Steps, calories against target, intensity split, MET curve, workouts |
| **Trends** | Nine metrics over 7/30/90/180 days with period average |
| **Settings** | Token management, full re-sync, JSON export, local erase, scoring explainer |

Everything renders from the local database, so the app works with no network. A background
refresh keeps last night ready before you open it.

## Build and install

Requirements: a Mac with **Xcode 16 or newer**, and an iPhone on **iOS 17+**.

1. `open OpenRing.xcodeproj`
2. Select the **OpenRing** target → **Signing & Capabilities** → pick your Apple ID under
   *Team*. A free Apple ID works.
3. Change the bundle identifier from `com.example.openring` to something unique to you
   (e.g. `com.yourname.openring`) — free provisioning rejects duplicates.
4. Plug in your iPhone, select it as the run destination, press ⌘R.
5. On the phone: **Settings → General → VPN & Device Management** → trust your developer
   certificate.

> With a **free** Apple ID the signature expires after 7 days and the app must be re-run from
> Xcode. A paid Apple Developer account ($99/year) extends this to a year. That is Apple's
> limitation, not the app's — worth weighing against the subscription you are replacing.

If the checked-in project file ever goes stale, regenerate it:
`brew install xcodegen && xcodegen generate`.

## Connecting your data

1. Sign in at [cloud.ouraring.com/personal-access-tokens](https://cloud.ouraring.com/personal-access-tokens)
2. Create a personal access token and copy it.
3. Paste it into OpenRing on first launch.

The token is stored in the iOS Keychain. It is sent to exactly one place: `api.ouraring.com`.
There is no OpenRing server, no account, and no analytics. The first sync downloads 180 days;
later syncs refresh the last 14 days (Oura revises recent nights) and run at most every 30
minutes in the foreground, plus a background refresh.

## How the scores work

Oura publishes *which* contributors feed each score but not the formulas. OpenRing implements
its own, as transparent piecewise-linear curves — the tables in
[`ScoreEngine.swift`](OpenRing/Scoring/ScoreEngine.swift) are the whole algorithm, and the app
shows every contributor with its weight in Settings → *How the scores are calculated*.

- **Sleep (7 contributors)** — total sleep 22%, REM 14%, deep 14%, restfulness 14%, timing 14%,
  efficiency 12%, latency 10%.
- **Readiness (8)** — HRV balance 20%, resting heart rate 18%, previous night 18%,
  body temperature 14%, sleep balance 12%, activity balance 8%, previous day activity 5%,
  recovery index 5%.
- **Activity (6)** — daily targets 28%, stay active 18%, training volume 18%,
  training frequency 16%, move every hour 12%, recovery time 8%.

Two design rules matter:

- **Everything is relative to you.** Resting heart rate, HRV and training load are scored
  against your own trailing 14- and 28-day baselines, not population norms. Expect the first
  two weeks of data to produce softer readiness numbers while baselines fill in.
- **Missing signals are skipped, not zeroed.** The remaining contributors are re-weighted, so
  a night without a temperature reading does not quietly cost you points.

Absolute numbers will differ from Oura's by a few points. Day-to-day *direction* is what the
scores are for, and that tracks closely because it comes from the same measurements.

## Layout

```
OpenRing/
  App/         App entry, AppModel (single source of truth), background refresh
  Models/      Day, Series, SleepPeriod, ActivityDay, …
  Networking/  Oura v2 client and wire types
  Scoring/     Curves and ScoreEngine — the local replacement for cloud scoring
  Storage/     Keychain, JSON database, sync engine
  Views/       SwiftUI screens and components
OpenRingTests/ Scoring behaviour and JSON key-mapping tests
```

Data lives in one JSON file in Application Support, written atomically. Export it any time
from Settings; erasing local data never touches your Oura account.

## Ideas if you want to extend it

- Write the computed scores into HealthKit so other apps can read them.
- Notifications when readiness drops sharply against your baseline.
- A widget or Watch complication for today's readiness.
- Tune the curves in `ScoreEngine.swift` to your own body — that is the point of owning them.

## Licence

Personal project, no warranty. Your Oura data remains subject to your agreement with Oura.
