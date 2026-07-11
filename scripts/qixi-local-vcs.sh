#!/usr/bin/env bash
# Local version-control helpers for Qixi.
#
# Goal: both humans and agents can inspect and restore any tracked file at any
# recorded revision without relying on GitHub. History lives in the worktree
# git database and is also mirrored to the bare local remote "local".
#
# Usage: scripts/qixi-local-vcs.sh <command> [args...]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

LOCAL_REMOTE_NAME="${QIXI_LOCAL_REMOTE_NAME:-local}"
LOCAL_MIRROR_PATH="${QIXI_LOCAL_MIRROR_PATH:-/Users/zyx/Desktop/projects/Qixi-local-mirror.git}"

die() {
  echo "error: $*" >&2
  exit 1
}

require_git() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a git repository: $ROOT"
}

ensure_local_remote() {
  if ! git remote get-url "$LOCAL_REMOTE_NAME" >/dev/null 2>&1; then
    if [[ ! -d "$LOCAL_MIRROR_PATH" ]]; then
      echo "Creating local bare mirror at $LOCAL_MIRROR_PATH"
      git clone --mirror "$ROOT" "$LOCAL_MIRROR_PATH"
    fi
    git remote add "$LOCAL_REMOTE_NAME" "$LOCAL_MIRROR_PATH"
  fi
}

cmd_status() {
  require_git
  echo "repo:     $ROOT"
  echo "branch:   $(git branch --show-current 2>/dev/null || echo '(detached)')"
  echo "head:     $(git rev-parse --short HEAD) $(git log -1 --pretty=%s)"
  echo "dirty:    $(if [[ -n "$(git status --porcelain)" ]]; then echo yes; else echo no; fi)"
  echo "remote:   $(git remote get-url origin 2>/dev/null || echo '(none)')"
  echo "local:    $(git remote get-url "$LOCAL_REMOTE_NAME" 2>/dev/null || echo "(not configured; expected $LOCAL_MIRROR_PATH)")"
  echo
  echo "checkpoints (tags):"
  if git tag -l 'checkpoint/*' | grep -q .; then
    git tag -l 'checkpoint/*' --sort=creatordate | while read -r tag; do
      printf '  %-40s %s  %s\n' \
        "$tag" \
        "$(git rev-list -n1 --abbrev-commit "$tag")" \
        "$(git log -1 --pretty=%s "$tag")"
    done
  else
    echo "  (none)"
  fi
  echo
  echo "recent commits:"
  git log --oneline -12
}

cmd_list() {
  require_git
  echo "== checkpoints =="
  git for-each-ref --sort=creatordate \
    --format='%(refname:short)  %(objectname:short)  %(creatordate:short)  %(subject)' \
    'refs/tags/checkpoint/*'
  echo
  echo "== branches =="
  git branch -v
  echo
  echo "== recent commits =="
  git log --oneline --decorate -20
}

# Show the history of one path (file or directory).
cmd_history() {
  require_git
  local path="${1:-}"
  [[ -n "$path" ]] || die "usage: history <path> [limit]"
  local limit="${2:-30}"
  git log --oneline --decorate -n "$limit" -- "$path"
}

# Show a file (or path) as it existed at a revision. Default revision: HEAD.
cmd_show() {
  require_git
  local path="${1:-}"
  [[ -n "$path" ]] || die "usage: show <path> [revision]"
  local rev="${2:-HEAD}"
  git show "${rev}:${path}"
}

# Diff a path against a revision (default: previous commit for that path).
cmd_diff() {
  require_git
  local path="${1:-}"
  [[ -n "$path" ]] || die "usage: diff <path> [revision]"
  local rev="${2:-}"
  if [[ -z "$rev" ]]; then
    git log -1 --pretty=%H -- "$path" >/dev/null
    git diff "HEAD" -- "$path" || true
    if [[ -z "$(git status --porcelain -- "$path")" ]]; then
      # Working tree matches HEAD; show last change to the path.
      local prev
      prev="$(git log -2 --pretty=%H -- "$path" | tail -1 || true)"
      if [[ -n "$prev" ]]; then
        echo "# working tree clean; showing last committed change for $path"
        git diff "$prev" HEAD -- "$path"
      fi
    fi
  else
    git diff "$rev" -- "$path"
  fi
}

# Restore one path from a revision into the working tree (does not auto-commit).
cmd_restore() {
  require_git
  local path="${1:-}"
  local rev="${2:-}"
  [[ -n "$path" && -n "$rev" ]] || die "usage: restore <path> <revision-or-tag>"
  git rev-parse --verify "$rev^{commit}" >/dev/null
  # Refuse to clobber without a clean path if uncommitted edits exist on that path.
  if [[ -n "$(git status --porcelain -- "$path")" ]]; then
    die "path has uncommitted changes: $path (commit or stash first, or use restore-force)"
  fi
  git checkout "$rev" -- "$path"
  echo "restored $path from $rev ($(git rev-parse --short "$rev"))"
  echo "staged in index; review with: git diff --cached -- $path"
  echo "commit when satisfied, or discard with: git restore --staged --worktree -- $path"
}

cmd_restore_force() {
  require_git
  local path="${1:-}"
  local rev="${2:-}"
  [[ -n "$path" && -n "$rev" ]] || die "usage: restore-force <path> <revision-or-tag>"
  git rev-parse --verify "$rev^{commit}" >/dev/null
  git checkout "$rev" -- "$path"
  echo "force-restored $path from $rev ($(git rev-parse --short "$rev"))"
}

# Create an annotated checkpoint tag on HEAD and push it to the local mirror.
cmd_tag() {
  require_git
  local name="${1:-}"
  local message="${2:-}"
  [[ -n "$name" ]] || die "usage: tag <name> [message]"
  # Accept bare names or checkpoint/ prefix.
  if [[ "$name" != checkpoint/* ]]; then
    name="checkpoint/${name}"
  fi
  if git rev-parse -q --verify "refs/tags/$name" >/dev/null; then
    die "tag already exists: $name"
  fi
  if [[ -z "$message" ]]; then
    message="Checkpoint: ${name#checkpoint/} at $(git rev-parse --short HEAD)"
  fi
  git tag -a "$name" -m "$message"
  ensure_local_remote
  git push "$LOCAL_REMOTE_NAME" "refs/tags/$name"
  echo "created and mirrored tag $name -> $(git rev-parse --short HEAD)"
}

# Commit all current tracked+untracked source changes (respecting .gitignore),
# then tag and mirror. Use for deliberate snapshots either of us can roll back to.
cmd_snapshot() {
  require_git
  local message="${1:-}"
  [[ -n "$message" ]] || die "usage: snapshot <commit-message> [tag-name]"
  local tag_name="${2:-}"

  if [[ -z "$(git status --porcelain)" ]]; then
    echo "working tree clean; nothing to commit"
    if [[ -n "$tag_name" ]]; then
      cmd_tag "$tag_name" "$message"
    fi
    cmd_mirror
    return 0
  fi

  # Stage everything except ignored paths. Never force-add ignored model binaries.
  git add -A
  # Safety: refuse if a tracked .bin or credential-like file was staged.
  if git diff --cached --name-only | grep -E '(^|/)(\.env|credentials|id_rsa|\.pem)$|\.bin$' >/dev/null; then
    git reset HEAD >/dev/null
    die "refusing to snapshot: staged path looks like a secret or model binary"
  fi

  git commit -m "$message"
  if [[ -n "$tag_name" ]]; then
    cmd_tag "$tag_name" "$message"
  fi
  cmd_mirror
  echo "snapshot commit $(git rev-parse --short HEAD)"
}

# Push all branches and tags to the local bare mirror.
cmd_mirror() {
  require_git
  ensure_local_remote
  git push "$LOCAL_REMOTE_NAME" --all
  git push "$LOCAL_REMOTE_NAME" --tags
  echo "mirrored branches+tags to $(git remote get-url "$LOCAL_REMOTE_NAME")"
}

cmd_help() {
  cat <<'EOF'
qixi-local-vcs.sh — local version control for Qixi

Commands:
  status                         Branch, dirtiness, checkpoints, recent commits
  list                           Checkpoints, branches, recent history
  history <path> [limit]         Commits that touched a path (default limit 30)
  show <path> [revision]         Print file contents at revision (default HEAD)
  diff <path> [revision]         Diff path vs revision (default: working tree / last change)
  restore <path> <revision>      Restore one path from a commit/tag into the index+worktree
  restore-force <path> <revision>
                                 Same as restore, overwriting uncommitted edits on that path
  tag <name> [message]           Annotated checkpoint/* tag on HEAD + local mirror push
  snapshot <message> [tag-name]  Commit current work, optional tag, mirror to local
  mirror                         Push all branches and tags to the local bare mirror
  help                           This help

Revisions may be commit SHAs, branch names, or tags such as:
  checkpoint/oracle-scaffold
  checkpoint/mcts-core-integration
  HEAD~1
  main

Examples:
  scripts/qixi-local-vcs.sh history core/src/mcts.cpp
  scripts/qixi-local-vcs.sh show core/src/mcts.cpp checkpoint/mcts-core-integration
  scripts/qixi-local-vcs.sh restore core/src/mcts.cpp checkpoint/mcts-core-integration
  scripts/qixi-local-vcs.sh snapshot "wip: tuning puct" puct-tuning
  scripts/qixi-local-vcs.sh mirror

Local mirror path (override with QIXI_LOCAL_MIRROR_PATH):
  /Users/zyx/Desktop/projects/Qixi-local-mirror.git
EOF
}

main() {
  local cmd="${1:-help}"
  shift || true
  case "$cmd" in
    status) cmd_status "$@" ;;
    list) cmd_list "$@" ;;
    history) cmd_history "$@" ;;
    show) cmd_show "$@" ;;
    diff) cmd_diff "$@" ;;
    restore) cmd_restore "$@" ;;
    restore-force) cmd_restore_force "$@" ;;
    tag) cmd_tag "$@" ;;
    snapshot) cmd_snapshot "$@" ;;
    mirror) cmd_mirror "$@" ;;
    help|-h|--help) cmd_help ;;
    *) die "unknown command: $cmd (try: help)" ;;
  esac
}

main "$@"
