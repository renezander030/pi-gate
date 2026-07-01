// workspace.js — patch computation + disposable eval workspace.
//
// Trust invariants enforced here:
//  - The agent's working tree is READ-ONLY to us: we never run `git add` against
//    its real index. The patch is built through a throwaway GIT_INDEX_FILE.
//  - The eval workspace is a fresh local clone of the real repo's COMMITTED state
//    (HEAD), created under harness state — never the agent's writable tree.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { git } from './git.js';
import { stateDir } from './paths.js';

function isGitWorktree(root) {
  try { return !!git(['rev-parse', '--show-toplevel'], { cwd: root }).trim(); }
  catch { return false; }
}

function clearWorktreeExceptGit(root) {
  for (const entry of fs.readdirSync(root)) {
    if (entry === '.git') continue;
    fs.rmSync(path.join(root, entry), { recursive: true, force: true });
  }
}

function copyTreeContents(src, dest) {
  for (const entry of fs.readdirSync(src, { withFileTypes: true })) {
    if (entry.name === '.git') continue;
    fs.cpSync(path.join(src, entry.name), path.join(dest, entry.name), {
      recursive: true,
      preserveTimestamps: true,
      verbatimSymlinks: true,
    });
  }
}

function createPatchWorkspace(baseRepo, stagingCopy, repoId) {
  const sd = stateDir(repoId);
  const ws = path.join(sd, 'patch-workspace');
  fs.rmSync(ws, { recursive: true, force: true });
  git(['clone', '--local', '--no-hardlinks', '--quiet', baseRepo, ws]);
  const head = git(['rev-parse', 'HEAD'], { cwd: baseRepo }).trim();
  git(['checkout', '--quiet', '--detach', head], { cwd: ws });
  clearWorktreeExceptGit(ws);
  copyTreeContents(stagingCopy, ws);
  return ws;
}

// Compute a binary-safe patch of the agent's uncommitted work (tracked + staged +
// untracked, respecting .gitignore) relative to HEAD, WITHOUT mutating the agent
// tree. `stagingRoot` may be either a Git worktree or a plain pi-safe staging copy
// without `.git`; in the latter case we mirror it onto a disposable clone first.
export function computePatch(stagingRoot, repoId, baseRepo = null) {
  const gitWorktree = isGitWorktree(stagingRoot);
  if (!gitWorktree && !baseRepo) {
    throw new Error('plain staging copies require the real repo path as baseRepo');
  }
  const patchRoot = gitWorktree
    ? stagingRoot
    : createPatchWorkspace(baseRepo, stagingRoot, repoId);
  const sd = stateDir(repoId);
  const tmpIndex = path.join(sd, '.tmp-index');
  try { fs.rmSync(tmpIndex, { force: true }); } catch {}
  // Seed throwaway index from HEAD, stage the whole working tree into it, diff.
  git(['read-tree', 'HEAD'], { cwd: patchRoot, indexFile: tmpIndex });
  git(['add', '-A'], { cwd: patchRoot, indexFile: tmpIndex });
  const patch = git(['diff', '--cached', '--binary', 'HEAD'], { cwd: patchRoot, indexFile: tmpIndex });
  try { fs.rmSync(tmpIndex, { force: true }); } catch {}
  const patchPath = path.join(sd, 'agent.patch');
  fs.writeFileSync(patchPath, patch);
  const patchId = crypto.createHash('sha256').update(patch).digest('hex').slice(0, 16);
  return { patch, patchPath, patchId, empty: patch.trim() === '' };
}

// List the files a patch touches (path => changeKind). Parses --numstat + --summary
// so renames/creations/deletions are all captured.
export function patchChangedFiles(repoRoot, patchPath, repoId) {
  if (!fs.existsSync(patchPath)) return [];
  const out = git(['apply', '--numstat', '-z', patchPath], { cwd: repoRoot, allowFail: true });
  // --numstat -z is awkward to parse for renames; fall back to plain numstat.
  const plain = git(['apply', '--numstat', patchPath], { cwd: repoRoot, allowFail: true });
  const files = [];
  for (const line of plain.split('\n')) {
    const m = line.match(/^[-\d]+\t[-\d]+\t(.+)$/);
    if (m) files.push(m[1].replace(/^.*=> (.+)}?$/, '$1').trim());
  }
  return [...new Set(files)].sort();
}

// Create a fresh, disposable eval workspace = local clone of committed HEAD.
// --no-hardlinks keeps it fully independent (safe to delete; cannot corrupt source).
export function createEvalWorkspace(repoRoot, repoId) {
  const sd = stateDir(repoId);
  const ws = path.join(sd, 'eval-workspace');
  fs.rmSync(ws, { recursive: true, force: true });
  git(['clone', '--local', '--no-hardlinks', '--quiet', repoRoot, ws]);
  // Match the exact HEAD of the source (detached) so eval reflects real repo state.
  const head = git(['rev-parse', 'HEAD'], { cwd: repoRoot }).trim();
  git(['checkout', '--quiet', '--detach', head], { cwd: ws });
  return ws;
}

// Apply the agent patch into the eval workspace. Returns {ok, error}.
export function applyPatchTo(ws, patchPath) {
  try {
    git(['apply', '--whitespace=nowarn', patchPath], { cwd: ws });
    return { ok: true };
  } catch (e) {
    return { ok: false, error: e.message };
  }
}

// Snapshot of working-tree changes vs the clone's clean HEAD (porcelain v1).
// Returns sorted list of changed paths.
export function workingTreeChanges(ws) {
  const out = git(['status', '--porcelain', '--untracked-files=all'], { cwd: ws });
  const files = [];
  for (const line of out.split('\n')) {
    if (!line.trim()) continue;
    const p = line.slice(3).trim();
    // Handle "old -> new" rename form.
    files.push(p.includes(' -> ') ? p.split(' -> ')[1] : p);
  }
  return [...new Set(files)].sort();
}

// Apply the verified patch to the REAL repo (only ever called by the apply gate).
export function applyPatchToReal(repoRoot, patchPath) {
  git(['apply', '--whitespace=nowarn', patchPath], { cwd: repoRoot });
}
