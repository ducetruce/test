# OpenRing

A local iOS app for your Oura ring data. It keeps a full copy of your data on your phone and
**computes Sleep, Readiness and Activity scores on-device**, so you get scored metrics without
depending on the official app's proprietary scoring models.

Not affiliated with, endorsed by, or supported by Ōura Health Oy.

---

## Read this first: how the data gets here

- **This app reads from Oura's cloud API, using a personal access token you generate.** The
  ring syncs to Oura's servers via the official Oura app; OpenRing downloads from the API and
  keeps a permanent local copy. That is the path that works from an unmodified iPhone today.
- **Talking to the ring directly over BLE is possible, but not from an iPhone alone.** The
  Gen 3/4/5 protocol has been reverse-engineered — see
  [`Th0rgal/open_oura`](https://github.com/Th0rgal/open_oura) (Rust) and
  [`LogosIsLife/open_ring`](https://github.com/LogosIsLife/open_ring) (Python). The blocker is
  authentication: reading battery, live heart rate or the history-event stream needs the
  ring's 16-byte app-auth key, there is no master key, and the key is generated during
  first pairing with the official app and stored in its encrypted database. Getting it out
  means ADB/root on Android, jailbreak tooling on iOS, or sniffing the pairing exchange.
  See *Going further: direct BLE* below.
- **The 0-100 scores are not on the ring.** Per open_oura's reversing, Readiness / Sleep /
  Activity / Stress are computed by the official app's own engine and a set of proprietary
  on-device PyTorch models — which are not published, and are not something a third-party app
  can obtain. So there is no version of this project, cloud or BLE, that gets Oura's exact
  scores. Any local app has to score the raw signals itself, which is what
  [`ScoreEngine.swift`](OpenRing/Scoring/ScoreEngine.swift) does. Where the API still returns
  Oura's number, it is shown next to ours for comparison.
- **Keep the official Oura app installed.** It carries data from ring to cloud over Bluetooth,
  and it holds the auth key if you later go the BLE route. OpenRing replaces the app you
  *look* at, not the sync path.

## Going further: direct BLE

If you want to cut the cloud out entirely, the sequence is:

1. Pair the ring with the official app (this is what generates the auth key).
2. Extract the 16-byte key from the app's Realm database — `open_oura` ships
   `tools/android_oura_key_extract.py` for a rooted Android device. From an iPhone this needs
   jailbreak tooling or a BLE sniffer, which is why it is not the default path here.
3. Reimplement the GATT layout and packet framing against CoreBluetooth in Swift, using
   `open_oura`'s `docs/` as the protocol reference.

Note that `open_oura` currently ships **no LICENSE file**, so its Rust code is all-rights-
reserved by default. Read it as a specification, don't paste it.

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
