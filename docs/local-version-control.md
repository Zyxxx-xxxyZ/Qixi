# Local Version Control

Qixi uses **Git** for version control. Every deliberate change should land in a
commit so either of us can inspect or restore any tracked file at any recorded
revision without depending on GitHub availability.

## What is already set up

| Piece | Location / name | Purpose |
| --- | --- | --- |
| Working repository | `/Users/zyx/Desktop/projects/Qixi` | Day-to-day edits |
| Local bare mirror | `/Users/zyx/Desktop/projects/Qixi-local-mirror.git` | Second local copy of all branches and tags |
| Git remote `local` | points at the bare mirror | `git push local --all --tags` |
| Git remote `origin` | GitHub (optional for backup/PR) | Not required for local rollback |
| Helper script | `scripts/qixi-local-vcs.sh` | File history, restore, snapshot, mirror |
| Checkpoint tags | `checkpoint/*` | Named, human-readable restore points |

### Current checkpoints

| Tag | Meaning |
| --- | --- |
| `checkpoint/undo-baseline` | Pre-integration undo baseline |
| `checkpoint/mcts-core-integration` | Custom persistent MCTS core + Swift wiring |
| `checkpoint/oracle-scaffold` | Oracle comparison scaffold (custom baselines only) |

List them any time:

```sh
scripts/qixi-local-vcs.sh list
# or
scripts/qixi-local-vcs.sh status
```

## Rules (for human and agent)

1. **Commit often** after coherent units of work. Prefer small commits over long
   dirty trees.
2. **Tag meaningful milestones** with `checkpoint/<name>` via the helper.
3. **Mirror after commits/tags** so the bare repo has the same history.
4. **Never force-push** to `main` or rewrite published history unless explicitly
   requested. Prefer a new commit that restores a file.
5. **Do not commit** model binaries (`*.bin`), credentials, DerivedData, or
   screenshot artifacts (already covered by `.gitignore`).
6. **KataGo** is a submodule; its history is separate. Record the submodule
   commit when changing it.

## Roll back one file (most common)

See what versions exist:

```sh
scripts/qixi-local-vcs.sh history path/to/file.cpp
```

Preview an old version:

```sh
scripts/qixi-local-vcs.sh show path/to/file.cpp checkpoint/mcts-core-integration
# or a short SHA
scripts/qixi-local-vcs.sh show path/to/file.cpp e031507
```

Restore that version into the working tree (stages the path; does not commit):

```sh
scripts/qixi-local-vcs.sh restore path/to/file.cpp checkpoint/oracle-scaffold
git diff --cached -- path/to/file.cpp   # review
git commit -m "restore path/to/file.cpp from checkpoint/oracle-scaffold"
scripts/qixi-local-vcs.sh mirror
```

If the path has uncommitted edits and you still want the old version:

```sh
scripts/qixi-local-vcs.sh restore-force path/to/file.cpp HEAD~1
```

## Roll back the whole tree to a checkpoint

Safe inspection (detached HEAD, no branch move):

```sh
git switch --detach checkpoint/mcts-core-integration
# look around, run tests, then:
git switch -
```

Create a branch at an old checkpoint to continue from it:

```sh
git switch -c recover/mcts-core checkpoint/mcts-core-integration
```

Hard reset of the current branch (destructive to uncommitted work — ask first):

```sh
git reset --hard checkpoint/oracle-scaffold
```

## Snapshot current work

When either of us wants a named restore point for in-progress work:

```sh
scripts/qixi-local-vcs.sh snapshot "wip: describe the change" optional-tag-name
```

That commits (if dirty), optionally creates `checkpoint/optional-tag-name`, and
pushes branches+tags to the local mirror.

## Recover if the worktree is damaged

As long as the bare mirror is intact:

```sh
git fetch local
git log local/codex/persistent-mcts-core-integration --oneline -5
git switch -c recover local/codex/persistent-mcts-core-integration
```

Or re-clone from the mirror:

```sh
git clone /Users/zyx/Desktop/projects/Qixi-local-mirror.git /path/to/Qixi-recovered
```

## Agent convention

When changing Qixi code, agents should:

1. Leave the tree buildable or note why not.
2. Commit coherent units with clear messages (no secrets, no model binaries).
3. Run `scripts/qixi-local-vcs.sh mirror` after commits/tags on this machine.
4. Use `checkpoint/*` tags for milestones the user may want to return to.
5. Prefer file-level `restore` + new commit over history rewriting.
