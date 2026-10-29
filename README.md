<!--
SPDX-FileCopyrightText: 2026 Gary Frattarola <garyf@parkviewlab.ai>
SPDX-License-Identifier: CC-BY-4.0
-->

# graptostream

A macOS app that listens to the microphones you select, while an app has asked it to or always, as you choose, and publishes what is said as a live text stream, which other apps on the Mac, or across the LAN, can read. An utterance that begins with a spoken name ("Fred, open today's note") is addressed to the app that answers to that name.

It uses only Apple's own frameworks: Core Audio and AVFoundation to capture, Apple's on-device speech recognition (SpeechAnalyzer) to transcribe, and the Network framework to serve. Speech is transcribed on this Mac; audio is never sent anywhere, and text leaves this Mac only to LAN clients holding a token, when you switch that on.

## Status

Version 0.1.1. Tested live with a MacBook Air's built-in microphone; not yet with the RØDE Wireless GO II receiver or with several microphones at once.

It is the macOS-only companion of indigo-noting, a proposed design, not yet public, for the same idea on macOS and Linux.

## Requirements and install

macOS 26 or later on Apple silicon.

1. Download `graptostream-<version>-macos.dmg` from the [Releases](https://github.com/ParkviewLab/graptostream/releases) page, open it, and drag graptostream onto the Applications shortcut. The app is signed with a Developer ID and notarised, so macOS opens it after a one-time confirmation that it came from the internet.
2. Open it. The first time it listens, macOS asks for microphone access. The first time it starts, macOS may download its English speech model.

## Using it

The window shows:

- **the state line:** whether it is listening and why, with the listening mode: **When asked** (it listens while some app has asked it to), **Always**, or **Off**;
- **microphones:** every input, each with a checkbox and a level meter. Several can be selected; they are combined, and the one currently carrying speech is used. Microphones stay shared with every other app. A Bluetooth microphone listens only while an app has asked, because recording from a Bluetooth headset lowers its playback quality for everything;
- **clients:** the apps reading the stream, and those that have asked it to listen, until when;
- **recent text,** with the app each utterance was addressed to.

Closing the window keeps it listening; the menu-bar icon shows whether it is, and **Quit** stops it.

In **Settings**:

- **Spoken names** map a name to an app, for example "Fred" to `scrinotia`. Ordinary, distinct words work best: the speech engine mishears invented names. A name counts only at the start of an utterance. A possessive counts, and so does a near spelling of a word of six letters or more; shorter words must be heard exactly. A name spoken on its own addresses the next utterance, if it begins within 4 s.
- **Network** sets the port, switches on serving the stream to other machines, and issues a token for each such client.
- **General** sets how long the transcript is kept (30 days by default), the longest segment without a pause, and starting at login.

## The stream

graptostream serves HTTP/1.1 on three addresses:

- the Unix socket `~/Library/Application Support/graptostream/stream.sock`, for your own processes (mode 0600: only your account can connect to it);
- `http://127.0.0.1:35860` (the port is set in Settings › Network), for programs on this Mac. Requests must name `localhost` or `127.0.0.1` as their host, and requests from web pages on other sites are refused (by their `Origin` or `Sec-Fetch-Site` header). Any account on this Mac can reach this address; on a Mac shared with others, use the socket;
- when switched on, the same port on the LAN, where every request carries `Authorization: Bearer <token>`. It is advertised by Bonjour as `_graptostream._tcp`.

| Endpoint | What it does |
|---|---|
| `GET /events` | The live stream, as Server-Sent Events. `?final=true` gives only settled text; `?to=<app>` only the final text addressed to that app (case-insensitive); `?client=<name>` names you in the window (on the LAN the token's name is used). A reconnecting client sends `Last-Event-ID` (or `?last_id=`) and receives the final text it missed, and the provisional text too if it is recent. A comment line every 15 s keeps the connection alive. |
| `GET /transcript?since=…&until=…&to=…` | The stored final segments that overlap `since` to `until` (ISO 8601 timestamps with a zone, each optional), and with `to` only those addressed to that app, as `{"events": [...]}` holding the same objects as the stream's `data`. |
| `POST /listen` with `{"client": "…", "minutes": 5}` | Asks it to listen; returns the request's `id` and `expires`. |
| `PUT /listen/<id>` with `{"minutes": 5}` | Renews the request before it expires. |
| `DELETE /listen/<id>` | Withdraws it. |
| `GET /status`, `GET /health` | The listening state, microphones, readers and requests; whether it is up. |

`POST /listen` returns 201 with `id`, `client`, `created` and `expires`; `minutes` defaults to 5 and is held between 0.1 and 1440; on the LAN the client's name is its token's name. `PUT` and `DELETE` return 404 for a request that is unknown or has lapsed, and `DELETE` returns 204.

An event:

```
id: 1042
event: segment
data: {"end":"2026-10-28T10:14:08.400Z","full":"Fred, open today's note.","heard":"Fred","id":1042,"seg":"000087","source":"Wireless GO II RX ch 1","start":"2026-10-28T10:14:03.200Z","state":"final","text":"open today's note.","to":"scrinotia"}
```

`state` is `provisional` while you are still speaking and `final` once you pause, about a second later; a final replaces the provisional versions that share its `seg`. A provisional segment's `start` is approximate, up to about two seconds after the speech began, because Apple's engine does not time words reliably until they are final; a final's `start` and `end` are exact. A final also arrives when a segment reaches the longest length set in Settings without a pause. For an addressed utterance, `text` is the words after the name and `full` is everything heard. A final's `text` may be empty; skip it. `to`, `heard` and `source` are present only when they have a value. `id` is unique across restarts; `seg` is unique only within one run of the app.

From a shell:

```bash
curl -N --unix-socket "$HOME/Library/Application Support/graptostream/stream.sock" "http://localhost/events?final=true"
```

From Python, with `httpx`. It reads what is addressed to `notes`, so map a spoken name to `notes` in Settings first; it renews its listening request once a minute:

```python
import json, os, threading, httpx

sock = os.path.expanduser("~/Library/Application Support/graptostream/stream.sock")
with httpx.Client(transport=httpx.HTTPTransport(uds=sock), base_url="http://localhost", timeout=None) as c:
    req = c.post("/listen", json={"client": "notes", "minutes": 5}).json()
    stop = threading.Event()

    def renew():
        while not stop.wait(60):
            c.put(f"/listen/{req['id']}", json={"minutes": 5})

    threading.Thread(target=renew, daemon=True).start()
    try:
        with c.stream("GET", "/events", params={"to": "notes", "client": "notes"}) as r:
            for line in r.iter_lines():
                if line.startswith("data: "):
                    text = json.loads(line[6:])["text"]
                    if text:
                        print(text)
    finally:
        stop.set()
        c.delete(f"/listen/{req['id']}")
```

From Swift, over loopback:

```swift
var request = URLRequest(url: URL(string: "http://127.0.0.1:35860/events?final=true")!)
request.timeoutInterval = .infinity
let (bytes, _) = try await URLSession.shared.bytes(for: request)
for try await line in bytes.lines where line.hasPrefix("data: ") {
    print(line.dropFirst(6))
}
```

A client that needs listening renews its request about once a minute while it wants it, and withdraws it when done; a request it forgets lapses on its own.

## Privacy

Audio is never stored. Final text is kept on this Mac as one JSON Lines file per day in `~/Library/Application Support/graptostream/transcript/`, and deleted after the retention period. The stream reaches other machines only when you switch the network listener on, and then only clients holding a token you issued; revoking a token closes that client's open stream, while listening requests it made stay until they expire (at most 24 hours). The LAN traffic, tokens included, is plain HTTP, which suits a private home network and not an open one.

## Build from source

Requirements: Xcode with the macOS 26 SDK or later, on Apple silicon.

```bash
./build.sh
open Graptostream.app
```

`build.sh` builds the Swift package and assembles and signs `Graptostream.app`: with `SIGN_IDENTITY` when it is set (CI sets it to the Developer ID identity), otherwise with your Apple Development identity when one is in your keychain (so that microphone permission survives rebuilds), otherwise ad hoc. `swift test` runs the tests. `Graptostream.app/Contents/MacOS/Graptostream --feed <recording>` reads a recording, looped, in place of the microphones; it is read whenever the app would listen, so set the mode to Always or make a listening request.

## Releasing

Releases are tag-driven and follow the ParkviewLab [release flow](https://github.com/ParkviewLab/handbook/blob/main/docs/releases.md); the release workflow builds the app, signs it with the Developer ID, notarises and staples the disk image, and attaches it to the GitHub Release.

## Contributing and licensing

See [`docs/CONTRIBUTING.md`](docs/CONTRIBUTING.md). The code is licensed under AGPL-3.0-or-later, and a commercial licence is available; see [`LICENSING.md`](LICENSING.md). The icon is all rights reserved.

---
<sub>© 2026 Gary Frattarola · Licensed under [CC-BY-4.0](LICENSES/CC-BY-4.0.txt)</sub>
