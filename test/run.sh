#!/usr/bin/env bash
# pi-evaluator slice-1 end-to-end + tamper tests.
# Builds a throwaway "real repo" and a separate "agent staging tree", then drives
# pi-evaluator through the gate for benign, failing, and tampering patches.
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
PISAFE="$HERE/pi-evaluator"
PASS=0; FAIL=0
ok()   { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL - $1"; FAIL=$((FAIL+1)); }

# Isolate state so tests never touch a real user's trusted manifests / reports.
WORK="$(mktemp -d)"
export XDG_STATE_HOME="$WORK/state"
export XDG_CONFIG_HOME="$WORK/config"
trap 'rm -rf "$WORK"' EXIT

mkrepo() { # $1=dir : a node repo whose "test" passes only if foo.js is unchanged
  local d="$1"; mkdir -p "$d"; ( cd "$d"
    git init -q; git config user.email t@t; git config user.name t
    cat > package.json <<'JSON'
{ "name": "demo", "version": "1.0.0", "scripts": { "test": "node verify.js" } }
JSON
    echo 'module.exports = 42;' > foo.js
    cat > verify.js <<'JS'
const v = require('./foo.js');
if (v !== 42) { console.error('foo changed value!'); process.exit(1); }
console.log('ok');
JS
    echo "real test file" > foo.test.js
    git add -A; git commit -qm init )
}

REAL="$WORK/real"; mkrepo "$REAL"

clone_staging() { rm -rf "$WORK/stg"; git clone -q "$REAL" "$WORK/stg"; echo "$WORK/stg"; }
run() { node "$PISAFE" "$@" --repo "$REAL" --staging "$STG"; }
decision() { node "$PISAFE" eval report --repo "$REAL" --staging "$STG" --json | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).applyDecision))'; }
status()   { node "$PISAFE" eval report --repo "$REAL" --staging "$STG" --json | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).status))'; }

echo "== T1: benign passing patch (detect-only -> override-required) =="
STG="$(clone_staging)"; echo 'module.exports = 42; // touched comment' > "$STG/foo.js"
# add a NEW non-sensitive file so the test still passes (foo.js value unchanged)
echo 'export const x = 1;' > "$STG/util.js"
run eval run >/dev/null 2>&1
[ "$(status)" = "pass" ] && ok "checks pass on benign patch" || bad "benign patch should pass (got $(status))"
[ "$(decision)" = "override-required" ] && ok "detect-only blocks apply until trusted" || bad "detect-only should require override (got $(decision))"
run apply >/dev/null 2>&1 && bad "apply must block while untrusted" || ok "apply blocked while untrusted"

echo "== T2: trust manifest, then benign patch applies =="
run eval trust >/dev/null 2>&1 && ok "eval trust promoted manifest" || bad "eval trust failed"
run eval run >/dev/null 2>&1
[ "$(decision)" = "allowed" ] && ok "trusted+pass => allowed" || bad "trusted pass should be allowed (got $(decision))"
run apply >/dev/null 2>&1 && ok "apply landed verified patch" || bad "apply should succeed"
grep -q 'touched comment' "$REAL/foo.js" && ok "real repo received the patch" || bad "real repo not updated"

echo "== T3: failing patch is blocked =="
git -C "$REAL" checkout -q -- . ; git -C "$REAL" clean -qfd   # reset real repo
STG="$(clone_staging)"; echo 'module.exports = 99;' > "$STG/foo.js"   # breaks verify.js
run eval run >/dev/null 2>&1
[ "$(status)" = "fail" ] && ok "broken patch fails checks" || bad "broken patch should fail (got $(status))"
run apply >/dev/null 2>&1 && bad "failing patch must not apply" || ok "failing patch blocked"
grep -q 'module.exports = 42' "$REAL/foo.js" && ok "real repo untouched after failed eval" || bad "real repo was mutated on failure!"

echo "== T4: --override lands a failing patch with a reason =="
run apply --override "hotfix, manually reviewed" >/dev/null 2>&1 && ok "override applied failing patch" || bad "override should apply"
grep -q 'module.exports = 99' "$REAL/foo.js" && ok "override landed the patch" || bad "override did not land"

echo "== T5: tamper — agent edits evaluator-sensitive files (tests/pkg) =="
git -C "$REAL" checkout -q -- . ; git -C "$REAL" clean -qfd
STG="$(clone_staging)"
echo 'module.exports = 42; // safe' > "$STG/foo.js"
echo 'HACKED TEST' > "$STG/foo.test.js"                 # test file
node -e 'const f="'"$STG"'/package.json";const j=require(f);j.scripts.test="true";require("fs").writeFileSync(f,JSON.stringify(j))'  # neuter test script
run eval run >/dev/null 2>&1
SENS=$(node "$PISAFE" eval report --repo "$REAL" --staging "$STG" --json | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const r=JSON.parse(s);console.log(r.evaluatorSensitiveChanges.join(","))})')
echo "$SENS" | grep -q 'foo.test.js' && echo "$SENS" | grep -q 'package.json' && ok "tampered test + package.json flagged evaluator-sensitive" || bad "tamper not flagged (got: $SENS)"

echo "== T6: evaluator config is NOT inside the agent tree =="
# The trusted manifest lives under XDG_CONFIG_HOME, never in the repo/staging tree.
[ -f "$XDG_CONFIG_HOME/pi-evaluator/manifests"/*.json ] 2>/dev/null && ok "trusted manifest stored in harness-owned config dir" || bad "trusted manifest not in harness dir"
ls "$REAL"/.pi-evaluator* >/dev/null 2>&1 && bad "evaluator config leaked into real repo" || ok "no evaluator config in agent-writable repo"

echo "== T7: network is a real OS boundary (off by default, opt-in only) =="
if unshare -rnpf --mount-proc true 2>/dev/null; then
  git -C "$REAL" checkout -q -- . ; git -C "$REAL" clean -qfd
  STG="$(clone_staging)"; echo 'module.exports = 42; // net-test' > "$STG/foo.js"
  RID=$(git -C "$REAL" rev-list --max-parents=0 HEAD)
  MAN="$XDG_CONFIG_HOME/pi-evaluator/manifests/$RID.json"; mkdir -p "$(dirname "$MAN")"
  netcheck() { cat > "$MAN" <<JSON
{"version":1,"profile":"generic","checks":[{"id":"tcp",$1"command":"timeout 4 bash -c 'cat </dev/null >/dev/tcp/1.1.1.1/53' 2>&1 && echo REACHED || (echo NO_NET; exit 7)","timeoutMs":10000}],"allowlistChanged":["**"],"sensitivePatterns":[]}
JSON
  }
  netcheck ""            ; run eval run >/dev/null 2>&1
  [ "$(status)" = "fail" ] && ok "outbound TCP blocked by default" || bad "network not blocked by default (got $(status))"
  netcheck '"network":true,'; run eval run >/dev/null 2>&1
  [ "$(status)" = "pass" ] && ok "outbound TCP allowed on network:true" || bad "network opt-in failed (got $(status))"
else
  echo "  skip - no rootless netns on this host"
fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
