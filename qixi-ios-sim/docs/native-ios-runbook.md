# Native iOS Runbook for 棋析

This simulator is intentionally Mac-hosted. It lets an iPad Safari front end
exercise the same request/response shape that a native app will use, while the
Mac runs the KataGo command-line engine.

For a real App Store-style iPad build:

1. Create an iOS app target in Xcode and enable Metal.
2. Add the board and stone assets from `qixi-ios-sim/assets`.
3. Build KataGo as an iOS static library or XCFramework with the Metal backend
   and the CoreML conversion code enabled.
4. Bundle the `b18c384nbt` model file in the app or download it into Application
   Support on first launch.
5. Create a Swift or Objective-C++ bridge that owns a long-lived KataGo analysis
   session and exposes async methods:
   - `analyze(position, maxVisits)`
   - `pause()`
   - `resume()`
   - `tombstoneToDisk(url)`
   - `restoreTombstone(url)`
6. On `UIApplication.didReceiveMemoryWarningNotification`, call the tombstone
   method, release the live search tree, and keep only the file-backed state.
7. On app foreground or user resume, restore the tombstone before continuing
   analysis.

The Metal mux config to mirror is:

```text
numNNServerThreadsPerModel = 4
metalDeviceToUseThread0 = 0
metalDeviceToUseThread1 = 0
metalDeviceToUseThread2 = 100
metalDeviceToUseThread3 = 100
metalUseFP16 = true
nnMaxBatchSize = 16
```

For the first true-device test without building the native bridge yet, run the
simulator backend on the Mac with `--host 0.0.0.0`, find the Mac's LAN IP, and
open `http://<mac-lan-ip>:8765` from iPad Safari.
