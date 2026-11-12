# StubEngine — TurboRelay's M1 conformance kit

Two SwiftPM executables plus a scenario harness, backing
[docs/remote-protocol.md](../docs/remote-protocol.md) §Conformance:

- **`StubEngine`** — a deterministic stand-in for `turbo-engine serve`, the
  engine-vocabulary layer (commands on stdin, events on stdout, logs on
  stderr). Simulates the image-family event sequence (loading → encoding →
  denoising with progress and previews → decoding → saving → done), honours
  `cancel` on arrival like the real engine, writes real (tiny, deterministic)
  PNGs, and simulates a broken checkpoint for the family name `invalid`. It is
  what TurboRelay will spawn in place of the real engine for end-to-end runs
  that download no models.

  ```bash
  StubEngine serve [--staging DIR] [--step-delay-ms N]
  ```

- **`RelayLint`** — the wire linter. Reads wire commands/events on stdin and
  exits 1 on any path-hostility violation: client-resolved `model.path`,
  `params.output`, string-path input images/LoRAs, `preview.path`, or
  `done.path` (see the spec's "Path-hostility rules"). This is what keeps the
  loopback test setup from ever masking the path bugs the real two-Mac run
  would expose.

- **`conformance.py` / `run-conformance.sh`** — the scenario harness. Stub
  scenarios assert ordered event sequences with a subset matcher (`null` =
  "key present"), verify the staged result parses as a real PNG, and the lint
  scenarios assert exit codes and violation messages.

```bash
./run-conformance.sh            # build + run everything
python3 conformance.py --keep   # keep the staging dir for inspection
```

Engine-layer events intentionally still carry paths (`done.path`,
`preview.path`) — that is the pipe protocol's contract, which TurboRelay's
bridge translates into the wire form. The linter judges wire streams only.
