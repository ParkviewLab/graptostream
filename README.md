<!--
SPDX-FileCopyrightText: 2026 Gary Frattarola <garyf@parkviewlab.ai>
SPDX-License-Identifier: CC-BY-4.0
-->

# graptostream

A macOS app that listens continuously to the microphones you select and publishes what is said as a live text stream, which other apps on the Mac, or across the LAN, can read. An utterance that begins with a spoken name ("Fred, open today's note") is addressed to the app that answers to that name, so that you can speak to apps by name from anywhere in the room.

It uses only Apple's own frameworks: Core Audio and AVFoundation to capture, Apple's on-device speech recognition (SpeechAnalyzer) to transcribe, and the Network framework to serve. Nothing leaves your network.

## Status

Version 0.1, the first release. Tested with recordings fed in place of the microphones; live use with real microphones is being tried now.

## Requirements and install

macOS 26 or later on Apple silicon.

1. Download `graptostream-<version>-macos.dmg` from the [Releases](https://github.com/ParkviewLab/graptostream/releases) page, open it, and drag graptostream onto the Applications shortcut. The app is signed and notarised, so it opens without any extra step.
2. Open it. The first time it listens, macOS asks for microphone access. The first time it starts, macOS may download its English speech model.

## Using it

The window shows:

- **the state line:** whether it is listening and why, with the listening mode: **When asked** (it listens while some app has asked it to), **Always**, or **Off**;
- **microphones:** every input, each with a checkbox and a level meter. Several can be selected; they are combined, and the one currently carrying speech is used. Microphones stay shared with every other app. A Bluetooth microphone listens only while an app has asked, because recording from a Bluetooth headset lowers its playback quality for everything;
- **clients:** the apps reading the stream, and those that have asked it to listen, until when;
- **recent text,** with the app each utterance was addressed to.

Closing the window keeps it listening; the menu-bar icon shows whether it is, and **Quit** stops it.

In **Settings**:

- **Spoken names** map a name to an app, for example "Fred" to `scrinotia`. Ordinary, distinct words work best: the speech engine mishears invented names. A name counts only at the start of an utterance, and a near spelling counts.
- **Network** switches on serving the stream to other machines, and issues a token for each such client.
- **General** sets how long the transcript is kept (30 days by default), the longest segment without a pause, and starting at login.

## The stream

graptostream serves HTTP/1.1 on three addresses:

- the Unix socket `~/Library/Application Support/graptostream/stream.sock`, for your own processes (the socket is readable only by you);
- `http://127.0.0.1:35860`, for programs and pages on this Mac (requests must name `localhost` or `127.0.0.1` as their host, and pages on other sites are refused);
- when switched on, the same port on the LAN, where every request carries `Authorization: Bearer <token>`. It is advertised by Bonjour as `_graptostream._tcp`.

| Endpoint | What it does |
|---|---|
| `GET /events` | The live stream, as Server-Sent Events. `?final=true` gives only settled text; `?to=<app>` only what is addressed to that app; `?client=<name>` names you in the window. A reconnecting client sends `Last-Event-ID` and receives what it missed. A comment line every 15 s keeps the connection alive. |
| `GET /transcript?since=…&until=…&to=…` | The stored final text between two ISO 8601 times. |
| `POST /listen` with `{"client": "…", "minutes": 5}` | Asks it to listen; returns the request's `id` and `expires`. |
| `PUT /listen/<id>` with `{"minutes": 5}` | Renews the request before it expires. |
| `DELETE /listen/<id>` | Withdraws it. |
| `GET /status`, `GET /health` | The listening state, microphones, readers and requests; whether it is up. |

An event:

```
id: 1042
event: segment
data: {"end":"2026-10-28T10:14:08.400Z","full":"Fred, open today's note.","heard":"Fred","id":1042,"seg":"000087","source":"Wireless GO II RX ch 1","start":"2026-10-28T10:14:03.200Z","state":"final","text":"open today's note.","to":"scrinotia"}
```

`state` is `provisional` while you are still speaking and `final` once you pause, about a second later; a final replaces the provisional versions that share its `seg`. For an addressed utterance, `text` is the words after the name and `full` is everything heard.

From a shell:

```bash
curl -N --unix-socket "$HOME/Library/Application Support/graptostream/stream.sock" "http://localhost/events?final=true"
```

From Python, with `httpx`:

```python
import json, os, httpx

sock = os.path.expanduser("~/Library/Application Support/graptostream/stream.sock")
with httpx.Client(transport=httpx.HTTPTransport(uds=sock), base_url="http://localhost", timeout=None) as c:
    c.post("/listen", json={"client": "notes", "minutes": 5})
    with c.stream("GET", "/events", params={"to": "notes", "client": "notes"}) as r:
        for line in r.iter_lines():
            if line.startswith("data: "):
                print(json.loads(line[6:])["text"])
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

Audio is never stored. Final text is kept on this Mac as one JSON Lines file per day in `~/Library/Application Support/graptostream/transcript/`, and deleted after the retention period. The stream reaches other machines only when you switch the network listener on, and then only clients holding a token you issued.

## Build from source

Requirements: Xcode with the macOS 26 SDK or later.

```bash
./build.sh
open Graptostream.app
```

`build.sh` builds the Swift package and assembles and signs `Graptostream.app`, with your Apple Development identity when one is in your keychain (so that microphone permission survives rebuilds), otherwise ad hoc. `swift test` runs the tests. `Graptostream.app/Contents/MacOS/Graptostream --feed <recording>` reads a recording in place of the microphones.

## Related

graptostream is the macOS-only companion of indigo-noting, a proposed design for the same idea on macOS and Linux with Rust, Tauri and whisper. What graptostream teaches goes back into that design.

## Contributing and licensing

See [`docs/CONTRIBUTING.md`](docs/CONTRIBUTING.md). The code is licensed under AGPL-3.0-or-later, and a commercial licence is available; see [`LICENSING.md`](LICENSING.md). The icon is all rights reserved.

---
<sub>© 2026 Gary Frattarola · Licensed under [CC-BY-4.0](LICENSES/CC-BY-4.0.txt)</sub>
