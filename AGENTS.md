# Agent notes for Qixi

## Version control (required)

This repo uses Git with a **local bare mirror** so work is recoverable without
GitHub. Full guide: `docs/local-version-control.md`.

Helper:

```sh
scripts/qixi-local-vcs.sh status|list|history|show|diff|restore|snapshot|tag|mirror
```

Conventions:

1. After coherent units of work, **commit** with a clear message (no force-push
   of rewritten history unless the user explicitly asks).
2. For milestones the user may return to, create
   `checkpoint/<name>` via `scripts/qixi-local-vcs.sh tag <name> "message"`.
3. After commits or tags on this machine, run
   `scripts/qixi-local-vcs.sh mirror` so
   `/Users/zyx/Desktop/projects/Qixi-local-mirror.git` stays current.
4. To roll back **one file**, prefer
   `scripts/qixi-local-vcs.sh restore <path> <rev>` then a new commit — do not
   reset shared branches casually.
5. Never commit model binaries (`*.bin`), credentials, DerivedData, or
   screenshot artifacts (see `.gitignore`).

## Product guardrails

See `docs/grok-4.5-handoff.md` when working on the persistent MCTS integration.
Do not claim official KataGo search equivalence without an oracle harness.
Do not treat iOS Simulator success as Metal mux inference evidence.
