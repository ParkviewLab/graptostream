# Changelog

All notable changes to this project are recorded here.

## [Unreleased]

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
