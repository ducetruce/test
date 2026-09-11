# OpenRing

[![Build and test](https://github.com/ducetruce/test/actions/workflows/ci.yml/badge.svg?branch=claude/ios-oura-app-clone-xafabh)](https://github.com/ducetruce/test/actions/workflows/ci.yml)

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

## Three ways to get your data in

**1. Oura cloud API (default).** Paste a personal access token; the app downloads 180 days on
first sync and keeps a permanent local copy. Works from an unmodified iPhone.

**2. Data export import.** Request your export at
[membership.ouraring.com/data-export](https://membership.ouraring.com/data-export) and import
the `.zip`, `.csv` or `.json` from Settings → Import. No token, no membership — this is your
data-portability export. Exported days only fill gaps the API has not already covered, so
importing can never clobber synced data.

The export format has changed over the years, so the importer canonicalises column names
through a synonym table, infers whether durations are seconds/minutes/hours per row, and
**reports every column it did not recognise**. If your export has columns it does not know,
that list is the thing to send along — adding them is a one-line change in `Field.synonyms`.

**3. Direct BLE from the ring (Settings → Advanced → Sync directly from ring).** Reads the
ring's own history-event stream with no cloud involved.

### What the BLE path needs, and how far it goes

It needs the ring's **16-byte auth key**, and there are two ways to have one.

**Use Oura's key.** It is generated when the official app first pairs with the ring and lives
in that app's encrypted database. There is no master key and it cannot be derived, so getting
it means ADB on a rooted Android device, jailbreak tooling on iOS, or sniffing the pairing
exchange. The payoff is coexistence: one key, and both the official app and this one work.

**Or install your own** (Settings → Advanced → *Claim a factory-reset ring*). A factory-reset
ring accepts a key from whoever asks first — `24 10 <16 bytes>`, answered with `25 01 00` —
and the reset itself can be done with the dock alone: flip it 180° repeatedly until the LED
runs blue → red → magenta → yellow, then blinks blue. No root, no jailbreak, no sniffer.

The catch is that a ring is **single-owner**. Claiming it takes it away from the official app,
and with it cloud sync, the API, data export and Oura's own scores; re-onboarding with the
official app installs Oura's key and locks this app out until you factory reset again.
Resetting also wipes the ring's event buffer, so sync before you reset.

**Do not claim your ring yet.** Only three event bodies are decoded so far (below), and
mapping the rest is much easier while the official app still works, because the cloud gives
you ground truth for the same night. Self-pairing destroys exactly the reference data that
finishes the job.

The app generates the key with the system CSPRNG, makes you confirm you have saved it before
it will write it to the ring, and stores it in the Keychain *before* sending — a key that
reaches the ring but not your phone is a ring you have locked yourself out of. The factory
reset command itself is deliberately **not** implemented: the dock does it safely, and a
health app should not carry a one-tap button that wipes your ring.

Implemented in full, from the published protocol notes:

- GATT service/characteristic discovery and frame reassembly across notifications
  (`tag | length | payload`)
- The nonce challenge: request nonce → AES-128-ECB encrypt with your key → authenticate
- Stream setup, time sync, data flush
- The paged drain: `GetEvent(cursor)` → collect frames → acknowledge with a zero-event
  request → advance the cursor → repeat until the `0x11` summary reports zero bytes left
  (silence is explicitly *not* treated as completion)
- Batches of 64 events so a dropped connection costs one batch, not the whole drain

Deliberately **not** implemented: most per-tag event body layouts, which are not publicly
documented. Rather than guess at byte offsets, the app decodes only what has published
scaling rules — skin temperature (`int16 / 100` °C), activity MET (the 0.1/0.2 split at 128)
and green-LED inter-beat intervals — classifies every other tag into a family, and keeps all
of them byte-for-byte in a capture you can export. Pair a capture with the same day's cloud
data and the unknown bodies become mappable; that is the intended next step, not a gap I have
papered over.

There is also a packet log on that screen showing every frame in and out, because untested
hardware code is only worth shipping if you can see what it is doing.

Protocol facts came from [`Th0rgal/open_oura`](https://github.com/Th0rgal/open_oura)'s `docs/`.
That repository ships **no LICENSE file**, so its code is all-rights-reserved by default:
this is an independent Swift implementation of the documented format, not a port.

## Build and install

Every push builds and runs the test suite on a macOS runner — currently green on
Xcode 26.6 with 53 passing tests — so you do not need a Mac to know the project compiles.
You do still need one to install it on a phone; see *Getting it onto a phone* below.

Requirements to build locally: a Mac with **Xcode 16 or newer**, and an iPhone on **iOS 17+**.

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

## Getting it onto a phone

Building is solved; installing is a separate wall, because iOS requires a signed build.
Three routes, none of which need you to own a Mac:

| Route | Cost | Catch |
|---|---|---|
| **AltStore / SideStore** with a free Apple ID | free | CI produces an unsigned `.ipa`, you sideload it. AltStore needs a Windows PC; SideStore refreshes on-device. Signature expires every 7 days either way. |
| **Apple Developer Program** + TestFlight | $99/yr | CI signs and uploads, install is over the air, builds last 90 days. Weigh the $99 against the subscription being replaced. |
| Borrow a Mac | free | Still only 7 days before it needs re-signing. |

The unsigned-IPA CI job is not written yet — it is the obvious next step once a route is chosen.

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
  Scoring/     Curves and ScoreEngine — scoring that needs no proprietary models
  Storage/     Keychain, JSON database, sync engine
  Import/      Dependency-free ZIP reader, CSV parser, export importer
  Ring/        BLE protocol, CoreBluetooth transport, drain orchestration, event decoding
  Views/       SwiftUI screens and components
OpenRingTests/ Scoring, JSON key mapping, BLE framing, ZIP/CSV import
```

Data lives in one JSON file in Application Support, written atomically. Export it any time
from Settings; erasing local data never touches your Oura account.

## Ideas if you want to extend it

- **Map the remaining event tags.** Drain a day over BLE, export the capture, and line the
  unknown bodies up against the same day from the API. Each one solved is a field that no
  longer needs the cloud at all.
- Write the computed scores into HealthKit so other apps can read them.
- Notifications when readiness drops sharply against your baseline.
- A widget or Watch complication for today's readiness.
- Tune the curves in `ScoreEngine.swift` to your own body — that is the point of owning them.

## Licence

Personal project, no warranty. Your Oura data remains subject to your agreement with Oura.
