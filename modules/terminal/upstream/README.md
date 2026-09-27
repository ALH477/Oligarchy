# Upstream: valvesky/velocitty

Drafts to file against <https://github.com/valvesky/velocitty>. **Nothing here
has been filed automatically** — read each one first; these go to someone
else's project.

Repository state when these were written: 6 stars, **0 issues and 0 pull
requests ever**, and our pin `1c560e1` (v1.0.1) *is* `main` — `compare` reports
ahead 0, behind 0. Two consequences:

* Patches authored now have **zero context drift**. This is the best possible
  moment to send them.
* This is a solo project that has never received a contribution. **Do not open
  four items at once.** File the PR and the rpath issue, see whether the
  maintainer engages at all, and stage the rest behind that.

## Filing order

| order | file | kind | why this order |
|---|---|---|---|
| 1 | `PR-tests.md` | PR (2 commits) | Strongest: *upstream's own documented workflow is broken.* `AGENTS.md` documents `zig build test`; there is no such step. Additive, touches no behaviour. |
| 2 | `ISSUE-relative-rpath.md` | issue | Distro-neutral and security-shaped. Needs no opinion about anyone's distribution. |
| 3 | `ISSUE-release-font-silence.md` | issue | A bug on Arch too. Asks for exactly one thing. |
| 4 | `ISSUE-tests-do-not-compile.md` | issue, **never a PR** | Cannot be fixed from outside; it needs a decision only the maintainer can make. Framed as an offer. |

Deliberately **not** filed: a request to make `build.zig` stop hardcoding
`/usr/include` and `/usr/lib`. Upstream's `AGENTS.md` is explicitly
Linux/X11/Omarchy-first, and that request reads as "support my distro". We
carry it locally as a `substituteInPlace` instead, which costs upstream
nothing.

The two commits in PR 1 are carried verbatim in `../patches/`. See that
directory's README for the rule that keeps them from drifting.
