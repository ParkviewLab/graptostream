# Changelog

All notable changes to this project are recorded here.

## [Unreleased]

## [v0.3.0] - 2026-10-31

### Highlights

Saying an app's spoken name followed by the interrupt word — "hush" by default, configurable on the Spoken names tab — now sends that app a `hush` event, detected from provisional text anywhere in a segment so it fires mid-sentence rather than at the end of an utterance. These hush segments are delivered as `event: hush` to clients subscribed with `?to=<app>` and are not written to the transcript; an utterance that begins with the name and interrupt word is published unaddressed instead of being routed as a normal request. What an interruption means is left to the receiving app.

### Features

- An interrupt word: "<name> hush" sends the app a hush event (#12)

## [v0.2.0] - 2026-10-31

### Highlights

Sentences spoken without a pause between them are now joined into a single utterance, so a name at the start of the first sentence addresses all of them rather than only the first. A new General setting, "Join sentences that follow within 0.333 s", controls the join window and can be set anywhere from 0 to 2 seconds, with 0 disabling joining entirely. Saved settings files are now read key by key with defaults applied for anything missing, so an existing file without the new key keeps its spoken names and other values instead of reverting to defaults.

### Features

- Join sentences spoken without a pause into one utterance (#10)

## [v0.1.1] - 2026-10-29

### Highlights

Provisional segments are now timed from the speech itself rather than from the silence preceding it. Apple's provisional results cover all audio since the previous segment ended, so a long pause before speaking pushed the reported start time far too early and caused the length limit (30 seconds by default) to be exceeded almost immediately, finalising a segment after a word or two. A provisional segment now starts at the end of the first provisional range that contains words, within about two seconds of the speech beginning, and the length limit is measured from that point; final segments keep their own exact ranges, and the README notes that provisional start times are approximate.

### Bug fixes

- Time provisional segments from the speech, not the silence before it (#8)

## [v0.1.0] - 2026-10-28

### Highlights

First release of graptostream, a macOS app that captures audio from one or more shared microphone inputs, transcribes it with Apple's on-device SpeechAnalyzer, and publishes the resulting segments as a Server-Sent Events stream over a Unix socket, loopback, or the LAN with bearer tokens and Bonjour discovery. Clients can filter for final or addressed segments, replay missed events via `Last-Event-ID`, and query `/health`, `/status`, `/transcript` and `/listen`; spoken names address an utterance to a particular listener, listening runs in When asked, Always or Off modes, and transcripts are stored as daily JSON Lines under a configurable retention period. The app window shows state, inputs with level meters, connected clients and recent text, with Settings for names, the LAN listener, retention, segment length and start at login, and a `--feed` option replays a recording in place of live microphones. Distribution is a signed, notarised disk image, and the README covers install, client examples in shell, Python and Swift, privacy and building from source.

### Features

- The core library: segments, stream, server, requests, addressing and transcript (#2)
- The app: shared microphone capture, Apple speech recognition and the window (#3)

### Bug fixes

- The findings of the pre-release code review (#6)

### Docs

- The README: install, use, the stream and its clients, privacy, building (#5)

### Maintenance

- Scaffold the package, licensing, CI and agent pointer files (#1)
- The app bundle, icon, signing, disk image, notarisation and release workflow (#4)

### Direct commits

- chore: initial commit (a50b451)
