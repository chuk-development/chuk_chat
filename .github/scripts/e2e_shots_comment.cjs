#!/usr/bin/env node
// Publishes the screenshots of an E2E run and writes ONE sticky pull request
// comment. Called by .github/workflows/e2e-comment.yml (workflow_run).
//
// Security model (docs/E2E_CI.md):
// - This file runs from the default branch. It never runs pull request code.
// - The artifact is untrusted data. Only files with a strict name, a size
//   limit and a PNG signature are used. Everything else is ignored.
// - The pull request is found from the workflow_run event (trusted), never
//   from a file in the artifact.
//
// Environment:
//   GITHUB_TOKEN, GITHUB_REPOSITORY, GITHUB_EVENT_PATH, GITHUB_API_URL,
//   GITHUB_SERVER_URL       set by GitHub Actions
//   SHOTS_DIR               the downloaded artifact
//   WORK_DIR                an empty directory for the e2e-shots checkout
//   ARTIFACT_OK             "true" when the download step passed
//   E2E_SHOTS_REMOTE        optional git remote URL (tests use a local repo)
'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const childProcess = require('node:child_process');

const BRANCH = 'e2e-shots';
const MARKER = '<!-- e2e-screenshots -->';
const NAME_RE = /^[0-9]{2}_[a-z0-9_]{1,60}\.png$/;
const MAX_FILE_BYTES = 5 * 1024 * 1024;
const MAX_FILES = 50;
const PNG_SIGNATURE = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
const PUSH_ATTEMPTS = 5;

// ---------------------------------------------------------------- artifact

/** Returns [{name, bytes, sha256}] for the valid PNG files in dir. */
function collectShots(dir) {
  if (!dir || !fs.existsSync(dir)) return [];
  const shots = [];
  for (const name of fs.readdirSync(dir).sort()) {
    if (!NAME_RE.test(name)) continue;
    const file = path.join(dir, name);
    const st = fs.lstatSync(file);
    if (!st.isFile() || st.size === 0 || st.size > MAX_FILE_BYTES) continue;
    const bytes = fs.readFileSync(file);
    if (!bytes.subarray(0, 8).equals(PNG_SIGNATURE)) continue;
    shots.push({ name, bytes, sha256: sha256(bytes) });
    if (shots.length >= MAX_FILES) break;
  }
  return shots;
}

function sha256(bytes) {
  return crypto.createHash('sha256').update(bytes).digest('hex');
}

/** Compares the run with the master baseline. */
function compare(shots, baseline) {
  const changed = [];
  const added = [];
  const same = [];
  for (const s of shots) {
    if (!baseline.has(s.name)) added.push(s.name);
    else if (baseline.get(s.name) !== s.sha256) changed.push(s.name);
    else same.push(s.name);
  }
  const names = new Set(shots.map((s) => s.name));
  const removed = [...baseline.keys()].filter((n) => !names.has(n)).sort();
  return { changed, added, same, removed };
}

// ---------------------------------------------------------------- git

function makeGit(workDir, remote, token) {
  const env = { ...process.env, GIT_TERMINAL_PROMPT: '0' };
  if (token) {
    // The header goes through the environment, never through argv or a file.
    const basic = Buffer.from(`x-access-token:${token}`).toString('base64');
    env.GIT_CONFIG_COUNT = '1';
    env.GIT_CONFIG_KEY_0 = 'http.https://github.com/.extraheader';
    env.GIT_CONFIG_VALUE_0 = `AUTHORIZATION: basic ${basic}`;
  }
  const git = (args, opts = {}) =>
    childProcess.execFileSync('git', args, {
      cwd: workDir,
      env,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', opts.quiet ? 'ignore' : 'inherit'],
    }).trim();
  return { git, remote };
}

/**
 * Checks out the e2e-shots branch into workDir. Returns the commit sha of
 * the remote branch, or '' when the branch does not exist yet.
 */
function checkoutShotsBranch({ git, remote }, workDir) {
  fs.rmSync(workDir, { recursive: true, force: true });
  fs.mkdirSync(workDir, { recursive: true });
  git(['init', '-q']);
  git(['config', 'user.name', 'github-actions[bot]']);
  git(['config', 'user.email', '41898282+github-actions[bot]@users.noreply.github.com']);
  git(['remote', 'add', 'origin', remote]);
  let head = '';
  try {
    git(['fetch', '-q', '--depth=1', 'origin', `refs/heads/${BRANCH}`], { quiet: true });
    head = git(['rev-parse', 'FETCH_HEAD']);
    git(['checkout', '-q', '-B', BRANCH, head]);
  } catch (_) {
    git(['checkout', '-q', '--orphan', BRANCH]);
  }
  return head;
}

function readBaseline(workDir) {
  const dir = path.join(workDir, 'master');
  const map = new Map();
  if (!fs.existsSync(dir)) return map;
  for (const name of fs.readdirSync(dir)) {
    if (NAME_RE.test(name)) map.set(name, sha256(fs.readFileSync(path.join(dir, name))));
  }
  return map;
}

function writeShots(dir, shots) {
  fs.rmSync(dir, { recursive: true, force: true });
  fs.mkdirSync(dir, { recursive: true });
  for (const s of shots) fs.writeFileSync(path.join(dir, s.name), s.bytes);
}

/** Removes pr/<n>/ for pull requests that are not open any more. */
function pruneClosed(workDir, openNumbers) {
  const prDir = path.join(workDir, 'pr');
  if (!fs.existsSync(prDir)) return;
  for (const n of fs.readdirSync(prDir)) {
    if (!openNumbers.has(Number(n))) {
      fs.rmSync(path.join(prDir, n), { recursive: true, force: true });
    }
  }
}

/**
 * One orphan commit with the whole tree, pushed with a lease on the old
 * head. A concurrent run moves the head, the lease fails, and this run
 * starts again from the new head. The branch never grows a history.
 */
function commitAndPush({ git }, oldHead, message) {
  git(['add', '-A']);
  const tree = git(['write-tree']);
  const commit = git(['commit-tree', tree, '-m', message]);
  try {
    git(['push', '-q', `--force-with-lease=refs/heads/${BRANCH}:${oldHead}`,
      'origin', `${commit}:refs/heads/${BRANCH}`]);
    return true;
  } catch (_) {
    return false;
  }
}

// ---------------------------------------------------------------- GitHub API

function makeApi(baseUrl, token, repo) {
  async function request(method, route, body) {
    const res = await fetch(`${baseUrl}/repos/${repo}${route}`, {
      method,
      headers: {
        Accept: 'application/vnd.github+json',
        Authorization: `Bearer ${token}`,
        'User-Agent': 'chuk-e2e-comment/1.0',
        'X-GitHub-Api-Version': '2022-11-28',
        ...(body ? { 'Content-Type': 'application/json' } : {}),
      },
      body: body ? JSON.stringify(body) : undefined,
    });
    if (!res.ok) throw new Error(`${method} ${route} -> HTTP ${res.status}`);
    return res.status === 204 ? null : res.json();
  }
  async function paginate(route) {
    const out = [];
    for (let page = 1; page <= 20; page++) {
      const sep = route.includes('?') ? '&' : '?';
      const items = await request('GET', `${route}${sep}per_page=100&page=${page}`);
      out.push(...items);
      if (items.length < 100) break;
    }
    return out;
  }
  return {
    openPulls: () => paginate('/pulls?state=open'),
    pullsForHead: (head) =>
      paginate(`/pulls?state=open&head=${encodeURIComponent(head)}`),
    comments: (n) => paginate(`/issues/${n}/comments`),
    createComment: (n, body) => request('POST', `/issues/${n}/comments`, { body }),
    updateComment: (id, body) => request('PATCH', `/issues/comments/${id}`, { body }),
  };
}

/** The pull request of the run, from trusted event fields only. */
async function findPull(api, run) {
  const direct = (run.pull_requests || []).find((p) => p.head && p.head.sha === run.head_sha);
  if (direct) return direct.number;
  // Fork pull requests: workflow_run.pull_requests is empty.
  const owner = run.head_repository && run.head_repository.owner && run.head_repository.owner.login;
  if (!owner || !run.head_branch) return null;
  const pulls = await api.pullsForHead(`${owner}:${run.head_branch}`);
  const match = pulls.find((p) => p.head && p.head.sha === run.head_sha);
  return match ? match.number : null;
}

// ---------------------------------------------------------------- comment

function buildComment({ run, runUrl, urlFor, shots, diff, hasBaseline, artifactOk }) {
  const lines = [MARKER, '### E2E screenshots', ''];
  const status = run.conclusion === 'success' ? 'passed' : `**${run.conclusion}**`;
  lines.push(`Run [#${run.run_number}](${runUrl}) on \`${run.head_sha.slice(0, 7)}\`: ${status}.`);
  lines.push('');
  if (!artifactOk || shots.length === 0) {
    lines.push('No screenshots in this run. See the run log.');
    return lines.join('\n');
  }
  const img = (n) => `**${n}**<br><img src="${urlFor(n)}" width="640" alt="${n}">`;
  if (!hasBaseline) {
    lines.push('No master baseline yet, so all screenshots are shown.', '');
    for (const n of shots.map((s) => s.name)) lines.push(img(n), '');
  } else {
    const shown = [...diff.changed, ...diff.added];
    if (shown.length === 0) {
      lines.push('No screenshot changed against master.', '');
    } else {
      lines.push(`${diff.changed.length} changed, ${diff.added.length} new against master.`, '');
      for (const n of diff.changed) lines.push(img(n) + ' (changed)', '');
      for (const n of diff.added) lines.push(img(n) + ' (new)', '');
    }
    if (diff.removed.length) {
      lines.push(`Not in this run: ${diff.removed.map((n) => `\`${n}\``).join(', ')}.`, '');
    }
    if (diff.same.length) {
      lines.push('<details><summary>Unchanged screenshots</summary>', '');
      for (const n of diff.same) lines.push(img(n), '');
      lines.push('</details>', '');
    }
  }
  lines.push(`Full set: artifact \`e2e-shots\` of the [run](${runUrl}).`);
  return lines.join('\n');
}

async function upsertComment(api, number, body) {
  const existing = (await api.comments(number)).find(
    (c) => c.user && c.user.type === 'Bot' && typeof c.body === 'string' && c.body.startsWith(MARKER),
  );
  if (existing) {
    await api.updateComment(existing.id, body);
    return 'updated';
  }
  await api.createComment(number, body);
  return 'created';
}

// ---------------------------------------------------------------- main

async function run({ env, event, api }) {
  const repo = env.GITHUB_REPOSITORY;
  const wr = event.workflow_run;
  const runUrl = wr.html_url;
  const artifactOk = env.ARTIFACT_OK === 'true';
  const shots = artifactOk ? collectShots(env.SHOTS_DIR) : [];
  console.log(`run ${wr.id} (${wr.event}, ${wr.conclusion}): ${shots.length} valid screenshots`);

  const isBaseline = wr.event === 'push' && wr.head_branch === 'master' &&
    wr.head_repository && wr.head_repository.full_name === repo;
  let prNumber = null;
  if (!isBaseline) {
    if (wr.event !== 'pull_request') return { action: 'ignored' };
    prNumber = await findPull(api, wr);
    if (!prNumber) {
      console.log('No open pull request has this head commit. Nothing to do.');
      return { action: 'no-pr' };
    }
  }
  if (isBaseline && (wr.conclusion !== 'success' || shots.length === 0)) {
    console.log('Master run is not green or has no screenshots. Baseline kept.');
    return { action: 'baseline-kept' };
  }

  const remote = env.E2E_SHOTS_REMOTE || `${env.GITHUB_SERVER_URL}/${repo}.git`;
  const g = makeGit(env.WORK_DIR, remote, env.E2E_SHOTS_REMOTE ? '' : env.GITHUB_TOKEN);
  const openNumbers = new Set((await api.openPulls()).map((p) => p.number));

  let baseline = new Map();
  let pushed = false;
  for (let attempt = 1; attempt <= PUSH_ATTEMPTS && !pushed; attempt++) {
    const head = checkoutShotsBranch(g, env.WORK_DIR);
    baseline = readBaseline(env.WORK_DIR);
    pruneClosed(env.WORK_DIR, openNumbers);
    if (isBaseline) {
      writeShots(path.join(env.WORK_DIR, 'master'), shots);
    } else {
      writeShots(path.join(env.WORK_DIR, 'pr', String(prNumber)), []);
      if (shots.length) {
        writeShots(path.join(env.WORK_DIR, 'pr', String(prNumber), String(wr.id)), shots);
      }
    }
    const what = isBaseline ? 'master baseline' : `PR #${prNumber}`;
    pushed = commitAndPush(g, head, `e2e screenshots: ${what}, run ${wr.id}`);
    if (!pushed) console.log(`Push attempt ${attempt} lost a race; trying again.`);
  }
  if (!pushed) throw new Error(`could not push ${BRANCH} after ${PUSH_ATTEMPTS} attempts`);
  if (isBaseline) return { action: 'baseline-updated', files: shots.length };

  const rawBase = `https://raw.githubusercontent.com/${repo}/${BRANCH}/pr/${prNumber}/${wr.id}`;
  const body = buildComment({
    run: wr,
    runUrl,
    urlFor: (n) => `${rawBase}/${n}`,
    shots,
    diff: compare(shots, baseline),
    hasBaseline: baseline.size > 0,
    artifactOk,
  });
  const action = await upsertComment(api, prNumber, body);
  console.log(`Comment ${action} on PR #${prNumber}.`);
  return { action, prNumber, body };
}

if (require.main === module) {
  const env = process.env;
  for (const k of ['GITHUB_TOKEN', 'GITHUB_REPOSITORY', 'GITHUB_EVENT_PATH', 'WORK_DIR']) {
    if (!env[k]) {
      console.error(`missing ${k}`);
      process.exit(2);
    }
  }
  const event = JSON.parse(fs.readFileSync(env.GITHUB_EVENT_PATH, 'utf8'));
  const api = makeApi(env.GITHUB_API_URL || 'https://api.github.com', env.GITHUB_TOKEN, env.GITHUB_REPOSITORY);
  run({ env, event, api }).catch((e) => {
    console.error(e.message);
    process.exit(1);
  });
}

module.exports = { run, collectShots, compare, buildComment, findPull, MARKER };
