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

### Device install = product package (mandatory)

**After EACH file modification that affects the app, you MUST rebuild and install
the newest NativeRelease binary on the physical iPad.** Do not stop at Simulator
install. Simulator-only is never a substitute for shipping to the user’s iPad.

Default physical device (when available / paired):

- Name: **曾逸轩的iPad**
- CoreDevice id: `21ABE4B1-1509-5D45-9645-75A52D050D68`
- Hardware UDID: `00008142-000E25660120401C`
- Bundle id: `com.zyx.qixi.local-device`
- Team: `Q795QF39Y5`
- Config: **`NativeRelease`** for `iphoneos` (not `iphonesimulator`)
- KataGo libs (device): prefer
  `/private/tmp/qixi-ios-katago-cmake-preflight-iphoneos-katago_core-product/`
  (`libkatago_core.a` + `libKataGoSwift.a`)

Typical flow after product source edits:

```sh
# 1) Build for device
xcodebuild -scheme Qixi -configuration NativeRelease \
  -destination "platform=iOS,id=00008142-000E25660120401C" \
  DEVELOPMENT_TEAM=Q795QF39Y5 \
  QIXI_KATAGO_IOS_LIBRARY_DIR=.../iphoneos-... \
  QIXI_KATAGO_IOS_LIBRARY=.../libkatago_core.a \
  build

# 2) Install + launch on the physical iPad
xcrun devicectl device install app --device 21ABE4B1-1509-5D45-9645-75A52D050D68 path/to/Qixi.app
xcrun devicectl device process launch --device 21ABE4B1-1509-5D45-9645-75A52D050D68 com.zyx.qixi.local-device
```

When asked to **install the app on a device** (iPad/iPhone), that means:

1. **Product build**, not Debug. Prefer **`NativeRelease`**:
   `QIXI_ENABLE_NATIVE_KATAGO=1`, `QIXI_NATIVE_RELEASE`, `nativeInProcess`,
   no HTTP bridge, linked iOS KataGo NN + current `core/` sources.
2. **Newest project state**: build from the current working tree so every
   product surface (Swift UI, native bridge, `core::MCTSStore`, models config)
   matches the latest project changes—no stale DerivedData-only reinstall of
   an older Debug binary.
3. **In-sync package**: do not ship a Debug/placeholder engine while claiming
   a product install. Rebuild NativeRelease (and required
   `libkatago_core.a` / `libKataGoSwift.a` for **iphoneos**) when product
   sources changed, then install that app.
4. **Physical iPad, not Simulator**, unless the user explicitly asks for sim only.

Debug device installs are only for explicitly requested diagnostics (e.g.
“Debug build” / bridge smoke), never as the default meaning of “install the app.”
