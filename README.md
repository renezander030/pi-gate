# pi-gate

**A deterministic gate for AI-agent code changes.** It takes the patch an agent produced,
applies it to a throwaway clone of your repo, runs your checks with the network off and
hard timeouts, and only lets the change reach the real repo if those checks pass — or you
explicitly override. The agent can *request* evaluation but cannot edit the checks,
policies, baselines, or allowlists that judge it.

Zero runtime dependencies. JSON output by default, `-H/--human` for tables.

> An agent that can edit the very checks that gate its output isn't being checked. pi-gate
> keeps the evaluator, its config, and its state **outside the agent's writable root**, so
> "the tests pass" can't be made true by editing the tests.

## How it works

```
agent's staging tree ─┐
                      ├─▶ compute patch (vs HEAD, via throwaway git index)
real repo @ HEAD ─────┘            │
                                   ▼
                 fresh `git clone` of HEAD  ──▶  apply patch  ──▶  run checks
                 (disposable, network off)                            │
                                                                      ▼
                                            JSON report + apply decision
                                                                      │
                              pass & trusted ──▶ `apply` lands it in the real repo
                              fail / untrusted ─▶ blocked, or `apply --override "reason"`
```

## Install

Requires **Node ≥ 18**, **git**, and a Linux host with rootless user namespaces for the
network/pid sandbox (see [Requirements](#requirements)).

```sh
git clone https://github.com/renezander030/pi-gate
ln -s "$PWD/pi-gate/pi-gate" /usr/local/bin/pi-gate   # or add to PATH
pi-gate help
```

## Quick start

```sh
# real repo kept clean; --staging is the agent's working tree (a clone it edited)
pi-gate eval plan  --repo /path/to/repo --staging /path/to/agent-tree   # what will run
pi-gate eval run   --repo /path/to/repo --staging /path/to/agent-tree -H # evaluate
pi-gate eval trust --repo /path/to/repo                                  # bless the checks (once)
pi-gate apply      --repo /path/to/repo --staging /path/to/agent-tree    # land it if it passed
```

Unknown repos start in **detect-only** mode: checks run, but `apply` is withheld until you
review the detected manifest and `eval trust` it (or pass an override).

## CLI

```
pi-gate eval plan      [--repo PATH] [--staging PATH]   # show selected manifest + checks
pi-gate eval run       [--repo PATH] [--staging PATH]   # evaluate, write machine report
pi-gate eval report    --json                           # print last report
pi-gate eval trust                                      # promote detected manifest (after review)
pi-gate apply                                           # land patch IFF report passed
pi-gate apply --override "<reason>"                     # force-apply failing patch, with reason
```

- `--repo` — the **real** repo (canonical target, kept clean until `apply`). Default: cwd.
- `--staging` — the **agent's** working tree or a plain `pi-safe` staging copy. Default: `--repo`.

### `pi-safe` staging

`pi-safe` intentionally copies the real project into `original` and `staging`
without `.git`. `pi-gate` accepts that staging tree directly:

```sh
pi-safe diff SESSION_ID
pi-gate eval run --repo /path/to/real-repo \
  --staging ~/.pi-safe/sessions/SESSION_ID/staging -H
pi-gate apply --repo /path/to/real-repo \
  --staging ~/.pi-safe/sessions/SESSION_ID/staging
```

For a non-Git staging copy, `pi-gate` mirrors the staged files onto a disposable
clone of the real repo, computes a patch there, then evaluates and applies that
patch through the same trusted gate. The agent's staging tree is still never
used as the evaluator workspace. Do not run `pi-safe apply` again for the same
session after `pi-gate apply`; `pi-gate` has already landed the verified patch.

## Guarantees (all enforced and tested)

| Invariant | How |
|---|---|
| Evaluator config + state live outside the agent tree | trusted manifests in `~/.config/pi-gate/manifests/`, state in `~/.local/state/pi-gate/` — never in the repo |
| Agent working tree is read-only to the evaluator | patch built via a throwaway `GIT_INDEX_FILE`; the real index is never touched |
| Checks run on a disposable copy, not the agent tree | fresh `git clone --local --no-hardlinks` of committed `HEAD` |
| Network disabled by default | every check runs under a rootless **pid+net namespace** (`unshare -rnpf`); only `network:true` checks get out — verified against real outbound TCP |
| Hard timeouts, fixed env | coreutils `timeout -s KILL` inside the pid-ns + spawn backstop; minimal deterministic env, no agent env leakage |
| Real repo changes only on pass / override | apply gate + stale-report tripwire (staged patch id must match the report) |

## Manifest

Versioned JSON, owned by you, stored at `~/.config/pi-gate/manifests/<repoId>.json`.
Built-in profiles: `node`, `python`, `go`, `rust`, `generic` (see [`src/profiles.js`](src/profiles.js)).

```jsonc
{
  "version": 1,
  "profile": "node",
  "checks": [
    { "id": "test", "command": "npm test --if-present", "cwd": ".",
      "timeoutMs": 300000, "env": {}, "network": false }
  ],
  "allowlistChanged": ["node_modules/**", ".git/**", ".npm/**"],
  "sensitivePatterns": ["**/*.test.*", ".github/**", "package.json", ".pi-gate/**"]
}
```

`repoId` = the repo's root-commit sha (stable across moves), falling back to a path hash.
`sensitivePatterns` flag changes to tests, lint/CI/package config, and the manifest itself
so a patch that quietly weakens the checks is surfaced in the report.

## Report schema (`eval report --json`)

`status` (`pass|fail|error`), `patchId`, `repo{id,head,path}`, `manifest{source,trusted,profile}`,
`isolation`, `patchApplied`, `checks[]` (`id, command, cwd, exitCode, status, durationMs,
isolation, outputTail, fullLogPath`), `changedFilesBefore/After`, `unexpectedChanges`,
`evaluatorSensitiveChanges`, `applyDecision` (`allowed|blocked|override-required`).

## Requirements

- **Node ≥ 18**, **git**, **coreutils `timeout`** (standard on Linux).
- **Rootless user namespaces** (`unshare -rnpf`) for the network/pid sandbox. Where they
  aren't available, checks fall back to an `env-only` mode (proxy vars, no kernel-level
  network block) — the per-check `isolation` field in the report tells you which applied,
  so the weaker mode is never silent.

## Tests

```sh
npm test    # or: bash test/run.sh
```

17 checks: benign pass → trust → apply, failing patch blocked, `--override`, tamper
detection (agent edits tests/package.json), evaluator-config-not-in-tree, and a real
network-isolation proof (outbound TCP blocked by default, allowed only on opt-in).

## Roadmap

YAML manifests, per-check expected-artifact assertions, a first-class lockfile/package-manifest
drift check, and per-check (rather than whole-manifest) trust promotion.

## License

MIT © Rene Zander. Bundles [cli-foundation](vendor/foundation.js) (vendored, zero deps).
