# pi-gate

Harness-owned deterministic verification layer for **Pi agent** output. The agent can
*request* evaluation but cannot choose or modify the trusted evaluator commands,
policies, baselines, or allowlists.

Built on [cli-foundation](../../claude/cli-foundation/) — JSON output by default,
`-H/--human` for tables. Zero runtime dependencies.

## Why

An agent that can edit the very checks that gate its output isn't being checked. pi-gate
puts the evaluator **outside** the agent's writable root, evaluates agent output as a
**patch applied to a throwaway clone** of the real repo, runs checks with **network off**
and **hard timeouts**, and only lets changes reach the real repo on a passing report or an
**explicit human override**.

## Trust model (non-negotiables, all enforced)

| Invariant | How |
|---|---|
| Evaluator config + state live outside the agent tree | trusted manifests in `~/.config/pi-gate/manifests/`, state in `~/.local/state/pi-gate/` — never in the repo |
| Agent working tree is read-only to the evaluator | patch built via a throwaway `GIT_INDEX_FILE`; the real index is never touched |
| Eval runs on a disposable copy, not the agent tree | fresh `git clone --local --no-hardlinks` of committed `HEAD` |
| Network disabled by default | every check runs under a rootless **pid+net namespace** (`unshare -rnpf`); only `network:true` checks get out — verified against real outbound TCP |
| Hard timeouts, fixed env | coreutils `timeout -s KILL` inside the pid-ns + spawn backstop; minimal deterministic env, no agent env leakage |
| Real repo changes only on pass / override | apply gate; stale-report tripwire (staged patch id must match report) |

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
- `--staging` — the **agent's** working tree (a clone of `--repo` it edited). Default: `--repo`.

The patch = `--staging`'s uncommitted work vs `HEAD`. Unknown repos start in **detect-only**
mode: checks run, but `apply` requires `eval trust` (human review) or an override.

## Manifest

Versioned JSON, owned by the harness (`~/.config/pi-gate/manifests/<repoId>.json`).
Built-in profiles: `node`, `python`, `go`, `rust`, `generic` (see `src/profiles.js`).

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

## Report schema (`eval report --json`)

`status` (`pass|fail|error`), `patchId`, `repo{id,head,path}`, `manifest{source,trusted,profile}`,
`isolation`, `patchApplied`, `checks[]` (`id, command, cwd, exitCode, status, durationMs,
isolation, outputTail, fullLogPath`), `changedFilesBefore/After`, `unexpectedChanges`,
`evaluatorSensitiveChanges`, `applyDecision` (`allowed|blocked|override-required`).

## Tests

```
npm test    # or: bash test/run.sh
```

17 checks: benign pass → trust → apply, failing patch blocked, `--override`, tamper
detection (agent edits tests/package.json), evaluator-config-not-in-tree, and a real
network-isolation proof (outbound TCP blocked by default, allowed only on opt-in).

## Status

**Implementation slice 1** complete (manifest format + loader; clean-copy eval workspace;
patch apply + checks with timeouts; JSON report + full logs; apply blocked on failure;
destructive/tamper tests).

Next: YAML manifest support, per-check expected-artifact assertions, lockfile/manifest
drift check as a first-class check, and review-gated promotion of detected checks
(individual check trust rather than whole-manifest trust).
