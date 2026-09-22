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
# body is a single paragraph; CI on that PR is the gate, so a bump the gate
# refuses stays visible as a red PR for a human rather than being hidden.

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

if [ "$pinned" != "$latest" ]; then
  branch="chore/toolchain-$latest"
  if $dry_run; then
    echo "toolchain: $pinned -> $latest (would open $branch)"
  elif ! gh pr list --state open --head "$branch" | grep -q .; then
    git checkout -b "$branch" main
    sed -i "s/MOONBIT_INSTALL_VERSION: \"$pinned\"/MOONBIT_INSTALL_VERSION: \"$latest\"/" \
      .github/workflows/ci.yml .github/workflows/docs.yml
    git add .github/workflows/ci.yml .github/workflows/docs.yml
    git commit -m "chore: bump the MoonBit toolchain to $latest"
    git push origin "$branch"
    gh pr create --title "chore: bump the MoonBit toolchain to $latest" \
      --body "Automated bump: the MoonBit toolchain moves from $pinned to $latest in both workflow pins. Opened by the scheduled updates workflow; the checks on this PR are the gate — a red one means the toolchain needs a human pass before it lands."
    git checkout -
  fi
fi

# ── the mooncakes dependencies ────────────────────────────────────────
# One PR per dependency: each is one focused commit, like a hand-written bump.
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
    git checkout -b "$branch" main
    sed -i "s|\"$pkg@$pinned\"|\"$pkg@$latest\"|" moon.mod
    git add moon.mod
    git commit -m "chore: bump $pkg to $latest"
    git push origin "$branch"
    gh pr create --title "chore: bump $pkg to $latest" \
      --body "Automated bump: $pkg moves from $pinned to $latest. Opened by the scheduled updates workflow; the checks on this PR are the gate — a red one means the bump needs a human pass (typically a deprecation the minor release introduced)."
    git checkout -
  fi
done

if $dry_run; then
  echo "updates: dry run complete"
fi
