#!/usr/bin/env bash
# scripts/rename_to_agents.sh — the properties that must hold, asserted.
#
# The repository has no shell test runner (host/tests/test_install_script.py
# drives scripts/install.sh from pytest, but that suite lives inside the host
# package and this tool is not part of it), so this file is its own runner:
# plain bash, no dependencies, one throwaway git repository per case.
#
#   bash scripts/tests/test_rename_to_agents.sh
#
# Exit status is 0 when every case passes.

set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
TOOL="$HERE/../rename_to_agents.sh"
WORK="$HERE/../../_scratch/rename_tool_tests"

PASSED=0
FAILED=0

pass() { PASSED=$((PASSED + 1)); printf '  ok    %s\n' "$1"; }
fail() {
    FAILED=$((FAILED + 1))
    printf '  FAIL  %s\n' "$1"
    [ $# -gt 1 ] && printf '        %s\n' "$2"
}

# assert_file <case> <file> <expected content>
assert_file() {
    local name="$1" file="$2" want="$3" got
    got="$(cat "$REPO/$file" 2>/dev/null || echo '<missing>')"
    if [ "$got" = "$want" ]; then
        pass "$name"
    else
        fail "$name" "want: $(printf '%s' "$want" | head -c 200)"
        printf '        got : %s\n' "$(printf '%s' "$got" | head -c 200)"
    fi
}

assert_contains() {
    local name="$1" file="$2" needle="$3"
    if grep -qF -- "$needle" "$REPO/$file" 2>/dev/null; then
        pass "$name"
    else
        fail "$name" "'$needle' is not in $file"
    fi
}

assert_absent() {
    local name="$1" file="$2" needle="$3"
    if grep -qF -- "$needle" "$REPO/$file" 2>/dev/null; then
        fail "$name" "'$needle' is still in $file"
    else
        pass "$name"
    fi
}

assert_path() {
    local name="$1" path="$2"
    if [ -e "$REPO/$path" ]; then pass "$name"; else fail "$name" "$path does not exist"; fi
}

assert_no_path() {
    local name="$1" path="$2"
    if [ -e "$REPO/$path" ]; then fail "$name" "$path still exists"; else pass "$name"; fi
}

# new_repo — a fresh git working tree in $REPO, with one commit.
new_repo() {
    rm -rf "$WORK"
    mkdir -p "$WORK"
    REPO="$WORK/repo"
    mkdir -p "$REPO"
    git -C "$REPO" init -q
    git -C "$REPO" config user.email t@t
    git -C "$REPO" config user.name t
}

commit_all() {
    git -C "$REPO" add -A
    git -C "$REPO" commit -qm fixture
}

run_tool() {
    ( cd "$REPO" && bash "$TOOL" --repo "$REPO" "$@" ) >"$WORK/out.txt" 2>"$WORK/err.txt"
    echo $?
}

printf '\n== the spellings that must survive ==\n'

new_repo
mkdir -p "$REPO/docs"
cat >"$REPO/docs/notes.md" <<'EOF'
Bead cowork-4z14 blocks cowork-r6jy; see cowork-sha and cowork-95i.7.
A coworker is not a CoWork. Coworkers keep their name, and so does
CoworkerNameStore and coworker_names.
The app id is dev.chuk.cowork and the scheme is cowork://pair.
The table is cowork_chats and the key is cowork_agent_roster_v1.
The label is cowork.managed and the HKDF info is cowork/pairing/sas.
EOF
commit_all
status="$(run_tool)"
[ "$status" = 0 ] || fail "tool exits 0 on a clean tree" "exit $status: $(cat "$WORK/err.txt")"
assert_contains "beads id cowork-4z14 survives"   docs/notes.md 'cowork-4z14'
assert_contains "beads id cowork-r6jy survives"   docs/notes.md 'cowork-r6jy'
assert_contains "beads id cowork-sha survives"    docs/notes.md 'cowork-sha'
assert_contains "beads sub-id cowork-95i.7 survives" docs/notes.md 'cowork-95i.7'
assert_contains "the word coworker survives"      docs/notes.md 'A coworker is not'
assert_contains "Coworkers survives"              docs/notes.md 'Coworkers keep'
assert_contains "CoworkerNameStore survives"      docs/notes.md 'CoworkerNameStore'
assert_contains "coworker_names survives"         docs/notes.md 'coworker_names'
assert_contains "the application id survives"     docs/notes.md 'dev.chuk.cowork'
assert_contains "the URL scheme survives"         docs/notes.md 'cowork://pair'
assert_contains "the supabase table survives"     docs/notes.md 'cowork_chats'
assert_contains "the storage key survives"        docs/notes.md 'cowork_agent_roster_v1'
assert_contains "the docker label survives"       docs/notes.md 'cowork.managed'
assert_contains "the HKDF label survives"         docs/notes.md 'cowork/pairing/sas'
assert_contains "the product name still moves"    docs/notes.md 'is not a Agents'

printf '\n== a rule that captures keeps what it captured ==\n'

new_repo
cat >"$REPO/keys.dart" <<'EOF'
const a = 'cowork-pairing-use-code';
const b = 'cowork-pairing-code-field';
const c = 'cowork-chat-store';
const d = '/run/cowork-vnc.pass';
const e = '[cowork-outbox] sent';
const f = 'cowork-chat-${threadKey}-0-0';
EOF
commit_all
run_tool >/dev/null
assert_file "backreferences expand against their own rule" keys.dart \
"const a = 'agents-pairing-use-code';
const b = 'agents-pairing-code-field';
const c = 'agents-chat-store';
const d = '/run/agents-vnc.pass';
const e = '[agents-outbox] sent';
const f = 'agents-chat-\${threadKey}-0-0';"

printf '\n== case is mapped, not folded ==\n'

new_repo
cat >"$REPO/cases.txt" <<'EOF'
cowork Cowork CoWork COWORK
FEATURE_COWORK COWORK_SANDBOX_IMAGE ~/.cowork
EOF
commit_all
run_tool >/dev/null
assert_file "each case maps to its own form" cases.txt \
'agents Agents Agents AGENTS
FEATURE_AGENTS AGENTS_SANDBOX_IMAGE ~/.agents'

printf '\n== the named things move ==\n'

new_repo
mkdir -p "$REPO/agent/src/cowork_agent" "$REPO/host/src/cowork_host" "$REPO/scripts"
printf 'from cowork_agent.loop import run\nimport cowork_sandbox\n' \
    >"$REPO/agent/src/cowork_agent/loop.py"
printf 'NAME = "cowork-manager.service"\nIMAGE = "cowork-base:latest"\n' \
    >"$REPO/host/src/cowork_host/service.py"
printf 'names = coworker_names\n' >"$REPO/host/src/cowork_host/coworker_names.py"
cat >"$REPO/agent/pyproject.toml" <<'EOF'
[project]
name = "cowork-agent"
dependencies = ["cowork-sandbox", "cowork-host"]
[project.scripts]
cowork-host = "cowork_host.cli:main"
EOF
printf 'unit\n' >"$REPO/scripts/cowork-manager.service"
commit_all
run_tool >/dev/null
assert_path    "the package directory moved"       agent/src/chuk_agents_runtime/loop.py
assert_no_path "the old package directory is gone" agent/src/cowork_agent
assert_path    "the host package moved"            host/src/chuk_agents_host/service.py
assert_path    "coworker_names.py keeps its name"  host/src/chuk_agents_host/coworker_names.py
assert_path    "the unit file moved"               scripts/agents-manager.service
assert_contains "imports follow the package"       agent/src/chuk_agents_runtime/loop.py 'from chuk_agents_runtime.loop'
assert_contains "the sandbox import follows"       agent/src/chuk_agents_runtime/loop.py 'import chuk_agents_sandbox'
assert_contains "the unit name is agents-manager"  host/src/chuk_agents_host/service.py 'agents-manager.service'
assert_contains "the image tag is agents-base"     host/src/chuk_agents_host/service.py 'agents-base:latest'
assert_contains "the distribution is renamed"      agent/pyproject.toml 'name = "chuk-agents-runtime"'
assert_contains "the dependency is renamed"        agent/pyproject.toml '"chuk-agents-sandbox"'
assert_contains "the console script keeps its name" agent/pyproject.toml 'cowork-host = "chuk_agents_host.cli:main"'

# git must know these are renames, not a delete plus an add.
renames="$(git -C "$REPO" status --porcelain | grep -c '^R')"
if [ "$renames" -ge 4 ]; then
    pass "the moves are staged as git renames ($renames)"
else
    fail "the moves are staged as git renames" "only $renames renames staged"
fi

printf '\n== the two migrations ==\n'

new_repo
mkdir -p "$REPO/common/cowork_config/src/cowork_config"
cat >"$REPO/common/cowork_config/src/cowork_config/loader.py" <<'PY'
from __future__ import annotations

import os
import tomllib
from collections.abc import Mapping
from pathlib import Path

__all__ = [
    "config_home",
    "default_config_path",
]

DEFAULT_HOME = "~/.cowork"


# -- where the file is ---


def config_home(environ=None):
    """The state directory: ``$COWORK_HOME``, else ``~/.cowork``."""
    env = os.environ if environ is None else environ
    raw = (env.get("COWORK_HOME") or "").strip() or DEFAULT_HOME
    return Path(raw).expanduser()


def _resolve_field(spec, env, problems):
    raw_env = env.get(spec.env)
    if raw_env is not None and raw_env.strip():
        return raw_env
    return spec.default
PY
commit_all
run_tool >/dev/null
assert_path     "the config package moved" common/chuk_agents_config/src/chuk_agents_config/loader.py
LOADER=common/chuk_agents_config/src/chuk_agents_config/loader.py
assert_contains "the default home is ~/.agents"   "$LOADER" 'DEFAULT_HOME = "~/.agents"'
assert_contains "AGENTS_HOME is read first"       "$LOADER" 'HOME_ENV = "AGENTS_HOME"'
assert_contains "COWORK_HOME is the fallback"     "$LOADER" 'LEGACY_HOME_ENV = "COWORK_HOME"'
assert_contains "the fallback warns"              "$LOADER" 'warn_legacy_env(HOME_ENV, LEGACY_HOME_ENV)'
assert_contains "the field reader has a fallback" "$LOADER" '_read_env(spec, env)'
assert_contains "the state directory migrates"    "$LOADER" 'def migrate_state_home('
assert_contains "the legacy directory is named"   "$LOADER" 'LEGACY_HOME_NAME = ".cowork"'
assert_contains "the migration is wired in"       "$LOADER" 'return migrate_state_home(Path(raw or DEFAULT_HOME).expanduser())'
assert_contains "the migration leaves a symlink"  "$LOADER" 'legacy.symlink_to(target'

# The migration itself, run for real against a throwaway home.
migration_problems="$(python3 - "$REPO/$LOADER" "$WORK/home2" <<'PY'
import sys, importlib.util, pathlib, warnings
module_path, home = sys.argv[1], pathlib.Path(sys.argv[2])
legacy = home / ".cowork"
(legacy / "secrets").mkdir(parents=True)
(legacy / "device.seed").write_text("seed")
spec = importlib.util.spec_from_file_location("loader_under_test", module_path)
module = importlib.util.module_from_spec(spec)
with warnings.catch_warnings():
    warnings.simplefilter("ignore")
    spec.loader.exec_module(module)
    target = module.migrate_state_home(home / ".agents")
    module.migrate_state_home(home / ".agents")
problems = []
if (home / ".agents" / "device.seed").read_text() != "seed":
    problems.append("the device seed did not move intact")
if not (home / ".agents" / "secrets").is_dir():
    problems.append("the vault did not move")
if not legacy.is_symlink():
    problems.append("no symlink was left behind")
elif legacy.resolve() != (home / ".agents").resolve():
    problems.append("the symlink points somewhere else")
if target != home / ".agents":
    problems.append("the return value is wrong")
print(" / ".join(problems))
PY
)"
if [ -z "$migration_problems" ] && [ -d "$WORK/home2/.agents" ]; then
    pass "the state directory really moves, with a symlink behind it"
else
    fail "the state directory really moves" "$migration_problems"
fi

printf '\n== idempotence, dry run and the dirty-tree guard ==\n'

new_repo
mkdir -p "$REPO/agent/src/cowork_agent"
printf 'import cowork_agent\nX = "COWORK_HOME"\n# bead cowork-4z14\n' \
    >"$REPO/agent/src/cowork_agent/loop.py"
commit_all

run_tool --dry-run >/dev/null
assert_contains "a dry run writes nothing" agent/src/cowork_agent/loop.py 'import cowork_agent'
assert_path     "a dry run moves nothing"  agent/src/cowork_agent/loop.py
if grep -q 'would change' "$WORK/out.txt"; then
    pass "a dry run says what it would do"
else
    fail "a dry run says what it would do" "$(head -3 "$WORK/out.txt")"
fi
if grep -qE '^ *paths would change +1$' "$WORK/out.txt"; then
    pass "a dry run counts the paths"
else
    fail "a dry run counts the paths" "$(grep -A6 '# totals' "$WORK/out.txt")"
fi

run_tool >/dev/null
commit_all
first="$(find "$REPO" -path "$REPO/.git" -prune -o -type f -print0 | sort -z | xargs -0 sha1sum)"
status="$(run_tool)"
[ "$status" = 0 ] || fail "the second run starts from a clean tree" "exit $status"
second="$(find "$REPO" -path "$REPO/.git" -prune -o -type f -print0 | sort -z | xargs -0 sha1sum)"
if [ "$first" = "$second" ]; then
    pass "a second run changes nothing"
else
    fail "a second run changes nothing" "$(diff <(echo "$first") <(echo "$second") | head -5)"
fi
if grep -qE '^ *files changed +0$' "$WORK/out.txt"; then
    pass "a second run reports zero"
else
    fail "a second run reports zero" "$(grep -A6 '# totals' "$WORK/out.txt")"
fi

new_repo
printf 'cowork\n' >"$REPO/a.txt"
commit_all
printf 'dirty\n' >"$REPO/b.txt"
status="$(run_tool)"
if [ "$status" != 0 ] && grep -q 'working tree is dirty' "$WORK/err.txt"; then
    pass "a dirty tree is refused"
else
    fail "a dirty tree is refused" "exit $status"
fi
status="$(run_tool --force)"
if [ "$status" = 0 ]; then
    pass "--force runs anyway"
else
    fail "--force runs anyway" "exit $status: $(cat "$WORK/err.txt")"
fi

printf '\n== the tracker and the applied migrations are never opened ==\n'

new_repo
mkdir -p "$REPO/.beads" "$REPO/supabase/migrations"
printf '{"id":"cowork-4z14","title":"CoWork thing"}\n' >"$REPO/.beads/issues.jsonl"
printf -- '-- CoWork chats\ncreate table cowork_chats ();\n' \
    >"$REPO/supabase/migrations/20260905000000_cowork_chats.sql"
printf 'cowork\n' >"$REPO/other.txt"
commit_all
run_tool >/dev/null
assert_file "the beads export is untouched" .beads/issues.jsonl '{"id":"cowork-4z14","title":"CoWork thing"}'
assert_path "the migration keeps its name"  supabase/migrations/20260905000000_cowork_chats.sql
assert_contains "the migration is untouched" supabase/migrations/20260905000000_cowork_chats.sql '-- CoWork chats'
assert_file "everything else still moves" other.txt 'agents'

printf '\n== summary ==\n'
rm -rf "$WORK"
printf '  %d passed, %d failed\n\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
