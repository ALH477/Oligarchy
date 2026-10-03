# Contributing to Oligarchy

## Copyright and outside contributions

DeMoD LLC holds the copyright in Oligarchy. The distribution is published under
the BSD-3-Clause licence in [LICENSE](LICENSE). Several sub-flakes under
`modules/` carry their own licence (MIT, MPL-2.0 or LGPL-3.0-only, each with a
`LICENSE` file), and third-party material keeps its own holders and licences.
[REUSE.toml](REUSE.toml) records the holder and licence of every file; the
licence texts are in [LICENSES/](LICENSES/).

Outside contributions will require a contributor licence agreement (CLA) with
DeMoD LLC. That agreement is being prepared. Until it is published, pull
requests from outside contributors are not merged.

## Before a change

- Read [CLAUDE.md](CLAUDE.md) and [docs/architecture.md](docs/architecture.md)
  for the rules and the gates each subsystem has.
- `reuse lint` must pass. A file that cannot carry a header (generated output,
  fixtures, media, lock files) is annotated in REUSE.toml instead.
- Media in `assets/` must be work DeMoD LLC made or has a licence to
  distribute: the ISO copies the whole tree.
