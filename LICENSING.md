# Licensing

Copyright © 2026 Gary Frattarola.

## How this project is licensed

This project is dual-licensed:

- **Open source:** `AGPL-3.0-or-later`. You may use, modify, and distribute it under those terms. The full text is in [`LICENSE`](LICENSE) and [`LICENSES/`](LICENSES/).
- **Commercial:** if the open-source terms don't fit your use, a commercial license is available. Inquiries: garyf@parkviewlab.ai.

## Per-bucket licensing

Different kinds of content carry different licenses (encoded in [`REUSE.toml`](REUSE.toml) and per-file SPDX headers):

| Bucket | License |
|---|---|
| Code, build scripts, configs, the version pin | `AGPL-3.0-or-later` |
| Documentation (`docs/`, `README.md`, this file) | `CC-BY-4.0` |
| Brand marks: the app icon and its sources (`brand/`) | `LicenseRef-AllRightsReserved` (all rights reserved) |

## Third-party software

graptostream uses only Apple's own frameworks (SwiftUI, AVFoundation, Core Audio, Speech, Network, ServiceManagement), which ship with macOS. It bundles no third-party code.

## REUSE compliance

This repo is [REUSE](https://reuse.software/)-compliant. Every file has a license via an SPDX header or a `REUSE.toml` annotation. Verify with:

```bash
uvx --from "reuse[charset-normalizer]" reuse lint
```

Any new file needs an SPDX header or a `REUSE.toml` entry, or the lint breaks.
