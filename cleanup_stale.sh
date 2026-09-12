#!/usr/bin/env bash
# Cleanup of stale agent worktrees + branches + dependabot PRs.
# Generated after the dep-upgrade landed on master (2026-09-07).
#
# KEEPS: master, cowork, agent/dep-upgrade, agent/dedupe + agent/dedupe-merge
#        (active merge), agent/token-stats (feature to be merged next).
#
# Run from the main checkout:  cd /home/user/git/chuk_chat && bash cleanup_stale.sh
# Review first. Nothing here is undoable once the remote branches are gone.
set -u
cd /home/user/git/chuk_chat || exit 1

echo "### 1) Remove stale worktrees whose work is already in master (merged) or obsolete"
STALE_WT=(
  ../chuk_chat-coingecko
  ../chuk_chat-integrate
  ../chuk_chat-mcp-aware
  ../chuk_chat-icons
  ../chuk_chat-icons2
  ../chuk_chat-mcp-sync
  ../chuk_chat-mode-config
  ../chuk_chat-nogfonts
  ../chuk_chat-nomaplibre
  ../chuk_chat-pre4
  ../chuk_chat-rm-spotify-whoop
  ../chuk_chat-sizeanalyze
  ../chuk_chat-sizeanalyze2
  ../chuk_chat-chatsplit
  ../chuk_chat-pkgupdate
  ../chuk_chat-main
  .claude/worktrees/agent-a5961c89dfbda243d
  .claude/worktrees/agent-aa91e69845686d651
)
for wt in "${STALE_WT[@]}"; do
  echo "  remove worktree $wt"
  git worktree remove "$wt" 2>&1 | sed 's/^/    /' \
    || echo "    (dirty/locked — inspect, then: git worktree remove --force $wt)"
done
git worktree prune

echo "### 2) Delete the local branches (work is in master or superseded)"
LOCAL_BR=(
  agent/coingecko-mcp agent/cowork-demo agent/integrate agent/mcp-aware
  agent/mcp-icons agent/mcp-icons-hires agent/mcp-sync agent/mode-config
  agent/no-google-fonts agent/no-maplibre agent/pre4 agent/remove-spotify-whoop
  agent/size-analyze agent/size-analyze2 agent/chat-ui-split agent/pkg-update
  agent/artifact-hosting chore/rm-spotify-whoop
  worktree-agent-a5961c89dfbda243d worktree-agent-aa91e69845686d651
)
for b in "${LOCAL_BR[@]}"; do
  git branch -D "$b" 2>&1 | sed 's/^/    /'
done

echo "### 3) Delete the obsolete REMOTE branches"
REMOTE_BR=(
  agent/cowork-demo
  claude/chat-ui-performance-rc7ivd
  chore/rm-spotify-whoop
  agent/artifact-hosting
)
for b in "${REMOTE_BR[@]}"; do
  echo "  delete origin/$b"
  NO_CR=1 git push origin --delete "$b" 2>&1 | sed 's/^/    /'
done

echo "### 4) Close the 5 dependabot PRs (CI/Actions/Docker bumps) + delete their branches"
for n in 17 19 20 21 22; do
  echo "  close PR #$n"
  gh pr close "$n" --delete-branch 2>&1 | sed 's/^/    /'
done

echo "### done. Remaining branches:"
git branch
echo "### remaining worktrees:"
git worktree list
