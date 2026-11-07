#!/bin/sh
# The scheduled updates bot: probe the two pinned version surfaces this
# repository carries — the MoonBit toolchain (`MOONBIT_INSTALL_VERSION` in the
# ci and docs workflows) and the mooncakes dependencies (`moon.mod`'s import
# block) — and, for each pin the world has moved past, open a focused PR.
#
# Discovery is official-tool only, so there is no third-party version list to
# drift: the toolchain answer comes from installing `latest` and asking the
# compiler its own version (`moonc vX+hash` reconstructs the pin spelling —
# the CDN serves the `latest` alias but 403s any directory listing, so the
# compiler is the only place the resolved string exists), and the dependency
# answer from `moon update`'s refreshed registry index. A pin that already
# matches, or a bump an open PR from a previous run already proposes, is left
# alone — the run is idempotent.
#
# Usage: .github/scripts/open_update_prs.sh [--dry-run]
#   --dry-run   report what would be proposed and exit; nothing is pushed,
#               committed, or opened. Exit 0 always.
# Without it, each proposal is a branch + one conventional commit + a PR whose
# body is a single paragraph.
#
# No CI runs on these PRs, and none can: they are opened with the workflow's
# own `github.token`, and GitHub deliberately fires no `pull_request` (or
# `push`) event for anything the default token creates — a bot reviewing its
# own work. A PAT or App token would change that, and the repository has
# neither, so the PR bodies say the truth instead: a human verifies the bump
# locally before merging, with the recipe they carry. (Widening ci.yml to run
# on pushes to the bot branches cannot work either, for the same reason: the
# bot's *pushes* are as token-authored as its PRs.)
#
# Each proposal is isolated: one failing `git`/`gh` call must not strand the
# run on a half-built branch or silently cancel every bump after it, so every
# step is chained and a failure returns to `main` and moves on. The branches
# are the bot's alone — re-pushing uses `--force-with-lease` after a fetch of
# the remote branch, so a closed PR's leftover branch is replaced (idempotent
# re-runs) while a concurrent human push to the same branch is still refused.

set -eu

root="${1:-.}"
dry_run=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=true ;;
    *) root="$arg" ;;
  esac
done
cd "$root"

# A runner has no git identity; the commits and PRs are the github-actions
# bot's, so they carry its name and noreply address rather than failing on a
# missing user.email.
if ! $dry_run; then
  git config user.name "github-actions[bot]"
  git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
fi

# `|| true`: greps that find nothing exit 1, which `set -e` would turn into a
# silent failure of the whole script.

# Each proposal runs as one `&&` chain inside isolate(), so the first failing
# step abandons that proposal alone; the recovery returns to a clean `main`
# and the run continues with the next bump. (`set -e` is no substitute inside
# an `||`-guarded block — errexit is suspended there — which is why the chain
# is explicit.)
isolate() {
  # isolate <label> <command…> — run, and on failure say so and survive.
  label=$1
  shift
  if "$@"; then
    return 0
  fi
  echo "updates: the $label proposal failed; recovering and continuing with the rest" >&2
  git checkout -f -q main >/dev/null 2>&1 || true
  git reset -q --hard main >/dev/null 2>&1 || true
  return 1
}

# The local verification recipe a human runs before merging one of these PRs
# — the same recipe each PR body carries, since no CI runs on them (see the
# header): check with warnings denied, formatting, interface drift, tests.
#
#   git fetch origin <branch> && git checkout <branch>
#   moon check --deny-warn && moon fmt --check
#   moon info && git diff --exit-code && moon test

# Every PR body says the same two things a reviewer needs: why the PR exists,
# and that nothing has checked it — the bot opened it with the repository's
# default token, GitHub runs no workflow events for work that token creates,
# so the local recipe above is the gate. Writing "CI will catch it" here would
# be the drift; there is no CI to catch it.
verify_note() {
  # verify_note <branch>
  printf 'Opened by the scheduled updates workflow with the repository'"'"'s default token, and GitHub runs no checks on work that token creates - this PR is not gated by CI. Verify locally before merging: git fetch origin %s && git checkout %s, then moon check --deny-warn && moon fmt --check && moon info && git diff --exit-code && moon test.' \
    "$1" "$1"
}

# ── the toolchain pin ─────────────────────────────────────────────────
# The pin lives in two workflows and must move in both (they describe one
# toolchain). `moonc v0.10.14+7d59c7ec9 (...)` → `0.10.14+7d59c7ec9`.
pinned="$(grep -h -o 'MOONBIT_INSTALL_VERSION: "[^"]*"' \
  .github/workflows/ci.yml .github/workflows/docs.yml |
  sed 's/.*"\(.*\)"/\1/' | sort -u)"
if [ "$(printf '%s\n' "$pinned" | wc -l)" -ne 1 ]; then
  echo "updates: the two workflows pin different toolchains:" >&2
  printf '%s\n' "$pinned" >&2
  exit 1
fi
pinned="$(printf '%s\n' "$pinned")"
latest="$(moon version --all | grep -o 'moonc v[^ ]*' | sed 's/moonc v//')"

# One proposal, end to end: branch off `main` (`-B`, so a leftover local
# branch from a failed earlier attempt is rebuilt, not fatal), one focused
# commit, push the bot-owned branch — a fetch first, so `--force-with-lease`
# replaces a closed PR's leftover remote branch while still refusing a
# concurrent human push — open the PR, return to `main`. Every step is
# `&&`-chained; see isolate() for why the chain is explicit.
propose_toolchain() {
  branch=$1; pinned=$2; latest=$3
  git checkout -B "$branch" main &&
    sed -i "s/MOONBIT_INSTALL_VERSION: \"$pinned\"/MOONBIT_INSTALL_VERSION: \"$latest\"/" \
      .github/workflows/ci.yml .github/workflows/docs.yml &&
    git add .github/workflows/ci.yml .github/workflows/docs.yml &&
    git commit -m "chore: bump the MoonBit toolchain to $latest" &&
    { git fetch -q origin "$branch" 2>/dev/null || true; } &&
    git push --force-with-lease="refs/heads/$branch" origin "$branch" &&
    gh pr create --title "chore: bump the MoonBit toolchain to $latest" \
      --body "Automated bump: the MoonBit toolchain moves from $pinned to $latest in both workflow pins. $(verify_note "$branch")" &&
    git checkout -
}

if [ "$pinned" != "$latest" ]; then
  branch="chore/toolchain-$latest"
  if $dry_run; then
    echo "toolchain: $pinned -> $latest (would open $branch)"
  elif ! gh pr list --state open --head "$branch" | grep -q .; then
    isolate toolchain propose_toolchain "$branch" "$pinned" "$latest" || true
  fi
fi

# ── the mooncakes dependencies ────────────────────────────────────────
# One PR per dependency: each is one focused commit, like a hand-written bump,
# and each is isolated — one failing dependency must not cancel the bumps
# after it.
propose_dep() {
  branch=$1; pkg=$2; pinned=$3; latest=$4
  git checkout -B "$branch" main &&
    sed -i "s|\"$pkg@$pinned\"|\"$pkg@$latest\"|" moon.mod &&
    git add moon.mod &&
    git commit -m "chore: bump $pkg to $latest" &&
    { git fetch -q origin "$branch" 2>/dev/null || true; } &&
    git push --force-with-lease="refs/heads/$branch" origin "$branch" &&
    gh pr create --title "chore: bump $pkg to $latest" \
      --body "Automated bump: $pkg moves from $pinned to $latest. $(verify_note "$branch") What to look for by hand: a deprecation the minor release introduced." &&
    git checkout -
}

moon update >/dev/null 2>&1 || moon update
grep -o '"[^"]*@[0-9][^"]*"' moon.mod | tr -d '",' | while IFS='@' read -r pkg pinned; do
  org="${pkg%/*}"
  name="${pkg#*/}"
  index="$HOME/.moon/registry/index/user/$org/$name.index"
  if [ ! -f "$index" ]; then
    echo "updates: no registry index for $pkg, skipping" >&2
    continue
  fi
  latest="$(grep -o '"version": *"[^"]*"' "$index" | tail -1 |
    sed 's/.*"\([0-9][^"]*\)"/\1/')"
  [ -n "$latest" ] || continue
  if [ "$pinned" = "$latest" ]; then
    continue
  fi
  branch="chore/bump-$name-$latest"
  if $dry_run; then
    echo "dependency: $pkg $pinned -> $latest (would open $branch)"
  elif ! gh pr list --state open --head "$branch" | grep -q .; then
    isolate "$pkg" propose_dep "$branch" "$pkg" "$pinned" "$latest" || true
  fi
done

if $dry_run; then
  echo "updates: dry run complete"
fi
