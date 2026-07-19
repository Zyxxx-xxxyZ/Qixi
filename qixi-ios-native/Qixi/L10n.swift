import Foundation

enum QixiPreferences {
  static let languageKey = "qixi.language"
  static let onboardingCompletedKey = "qixi.onboardingCompleted"
  static let iCloudSyncEnabledKey = "qixi.iCloudSyncEnabled"

  static var shouldSkipOnboardingForAutomation: Bool {
    ProcessInfo.processInfo.environment["QIXI_SKIP_ONBOARDING"] == "1"
  }

  static var iCloudSyncEnabledAutomationOverride: Bool? {
    guard let value = ProcessInfo.processInfo.environment["QIXI_ICLOUD_SYNC_ENABLED"] else { return nil }
    switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "1", "true", "yes", "enabled":
      return true
    case "0", "false", "no", "disabled":
      return false
    default:
      return nil
    }
  }
}

enum AppLanguage: String, CaseIterable {
  case zhHans = "zh-Hans"
  case zhHant = "zh-Hant"
  case en = "en"

  static var current: AppLanguage {
    let environment = ProcessInfo.processInfo.environment["QIXI_APP_LANGUAGE"]
    if let environment, let language = AppLanguage(rawValue: environment) {
      return language
    }
    if let saved = UserDefaults.standard.string(forKey: QixiPreferences.languageKey),
       let language = AppLanguage(rawValue: saved) {
      return language
    }
    let preferred = Locale.preferredLanguages.first ?? "zh-Hans"
    if preferred.hasPrefix("zh-Hant") || preferred.hasPrefix("zh-HK") || preferred.hasPrefix("zh-TW") {
      return .zhHant
    }
    if preferred.hasPrefix("en") {
      return .en
    }
    return .zhHans
  }
}

enum L10n {
  static func text(_ key: Key) -> String {
    table[AppLanguage.current]?[key] ?? table[.zhHans]?[key] ?? key.rawValue
  }

  static func moveNumber(_ ply: Int) -> String {
    String(format: text(.treeMoveNumber), ply)
  }

  static func languageName(_ language: AppLanguage) -> String {
    switch language {
    case .zhHans: return text(.languageZhHans)
    case .zhHant: return text(.languageZhHant)
    case .en: return text(.languageEn)
    }
  }

  enum Key: String, CaseIterable {
    case languageZhHans
    case languageZhHant
    case languageEn
    case engineNone
    /// Shown on the former “No Engine” control after any engine has been enabled (pauses analysis).
    case enginePause
    case engineB6
    case engineB18
    case engineB28
    case hermesReady
    case hermesLoading
    case hermesOffline
    case engineErrorTitle
    case engineErrorLibraryNotLinked
    case engineErrorModelMissing
    case engineErrorInsufficientMemory
    case engineErrorLocalNetworkDenied
    case engineErrorUnloadFailed
    case engineErrorAnalysisFailed
    case engineErrorModelInstallFailed
    case boardPass
    case boardTerritory
    case settingsKomi
    case settingsWideRootNoise
    case utilityNew
    case utilityCamera
    case utilityImport
    case utilitySync
    case utilityExportShare
    case treeMoveNumber
    case onboardingTitle
    case onboardingSubtitle
    case onboardingLanguageTitle
    case onboardingContinue
    case sheetDone
    case cameraSheetTitle
    case cameraSheetIdle
    case cameraChoosePhoto
    case cameraImageLoaded
    case cameraSelectionHint
    case cameraCancelSelection
    case cameraRecognizeSelection
    case cameraRecognizedStones
    case cameraHistoryWarning
    case cameraRecognitionFailed
    case cameraNextPlayerLabel
    case cameraNextPlayerBlack
    case cameraNextPlayerWhite
    case cameraApplyRecognition
    /// Re-open four-corner crop for the same photo (not retake / re-pick).
    case cameraRetryCorners
    /// Abandon recognition result and return to camera sheet (no apply).
    case cameraDiscardRecognition
    case importSheetTitle
    case importSheetIdle
    case importChooseFile
    case importChooseSGF
    case importChooseMCTSState
    case exportSGF
    case exportMCTSState
    case importLoadedMoves
    case importFailed
    case mctsStateImporting
    case mctsStateImported
    case mctsStateImportFailed
    case mctsStateExporting
    case mctsStateExportReady
    case mctsStateExportFailed
    case sgfExporting
    case sgfExportReady
    case sgfExportFailed
    case openSheetTitle
    case openSheetIdle
    case openChooseSGF
    case openChooseMCTSState
    case openChooseFile
    case openEmptyList
    case openICloudBadge
    case openHint
    case openBusyHint
    case openLoading
    case openFailed
    case archiveSheetTitle
    case archiveFileNameLabel
    case archiveFileNamePlaceholder
    case archiveContentsLabel
    case archiveIncludeSGF
    case archiveIncludeSearchState
    case archiveSaveTo
    case archiveSaveSync
    case archiveAlwaysBothHint
    case archiveHint
    case archiveHintExisting
    case archiveThumbnailLabel
    case archiveExporting
    case archiveExportReady
    case archiveSyncReady
    case archiveSyncReadyExisting
    case archiveExportFailed
    case exportShareSheetTitle
    case exportShareHint
    case exportSaveToFiles
    case exportShareAction
    case exportSharePreparing
    case exportShareReady
    case exportShareFailed
    case unsavedChangesTitle
    case unsavedChangesMessage
    case unsavedChangesSave
    case unsavedChangesDiscard
    case unsavedChangesCancel
    case backendRestoringState
    case backendLoadingEngine
    case backendInstallingModel
    case memoryPressureUnloading
    case memoryPressureReloading
    case memoryPressureUnloadingEngine
    case memoryPressureSavingAndFreeing
    case memoryPressureStoreUnloaded
    case syncSheetTitle
    case syncEnabled
    case syncDisabled
    case syncLastSynced
    case syncErrorTitle
    case syncErrorMessage
    case syncConflictMessage
    case syncNow
  }

  static let table: [AppLanguage: [Key: String]] = [
    .zhHans: [
      .languageZhHans: "简体中文",
      .languageZhHant: "繁體中文",
      .languageEn: "English",
      .engineNone: "无引擎",
      .enginePause: "暂停",
      .engineB6: "b6",
      .engineB18: "b18nbt",
      .engineB28: "b28nbt",
      .hermesReady: "已就绪",
      .hermesLoading: "加载中",
      .hermesOffline: "引擎离线",
      .engineErrorTitle: "引擎需要处理",
      .engineErrorLibraryNotLinked: "当前构建尚未链接 iPad 原生 KataGo 库。",
      .engineErrorModelMissing: "未安装模型：%@。",
      .engineErrorInsufficientMemory: "%@ 至少需要 %d MB 可用内存；当前约为 %d MB。",
      .engineErrorLocalNetworkDenied: "本地网络权限被拒绝。请在 iPad 设置中允许棋析访问本地网络。",
      .engineErrorUnloadFailed: "卸载引擎失败：%@",
      .engineErrorAnalysisFailed: "分析失败：%@",
      .engineErrorModelInstallFailed: "模型安装失败：%@",
      .boardPass: "停一手",
      .boardTerritory: "领地",
      .settingsKomi: "贴目",
      .settingsWideRootNoise: "宽根噪声",
      .utilityNew: "新建",
      .utilityCamera: "拍照",
      .utilityImport: "打开",
      .utilitySync: "存档",
      .utilityExportShare: "导出/分享",
      .treeMoveNumber: "第%d手",
      .onboardingTitle: "棋析",
      .onboardingSubtitle: "选择界面语言后开始使用。",
      .onboardingLanguageTitle: "语言",
      .onboardingContinue: "开始使用",
      .sheetDone: "完成",
      .cameraSheetTitle: "拍照识别",
      .cameraSheetIdle: "选择棋盘照片",
      .cameraChoosePhoto: "选择照片",
      .cameraImageLoaded: "照片已载入",
      .cameraSelectionHint: "框住棋盘网格四角",
      .cameraCancelSelection: "取消",
      .cameraRecognizeSelection: "识别",
      .cameraRecognizedStones: "识别到 %d 颗棋子（黑 %d / 白 %d）",
      .cameraHistoryWarning: "识别会把当前棋谱替换为照片中的局面（仅可见棋子，无手数历史）。确认后再扫描。",
      .cameraRecognitionFailed: "识别失败",
      .cameraNextPlayerLabel: "轮到谁下？",
      .cameraNextPlayerBlack: "黑方",
      .cameraNextPlayerWhite: "白方",
      .cameraApplyRecognition: "确认",
      .cameraRetryCorners: "重调四角",
      .cameraDiscardRecognition: "放弃",
      .importSheetTitle: "打开",
      .importSheetIdle: "打开 .sgf 棋谱或 .qixi.png 搜索状态",
      .importChooseFile: "选择文件",
      .importChooseSGF: "打开棋谱 (.sgf)",
      .importChooseMCTSState: "打开搜索状态 (.qixi.png)",
      .exportSGF: "导出棋谱 (.sgf)",
      .exportMCTSState: "导出搜索状态 (.qixi.png)",
      .importLoadedMoves: "已打开 %d 手",
      .importFailed: "打开失败",
      .mctsStateImporting: "正在打开搜索状态",
      .mctsStateImported: "已打开搜索状态",
      .mctsStateImportFailed: "搜索状态打开失败",
      .mctsStateExporting: "正在准备搜索状态",
      .mctsStateExportReady: "搜索状态已交给系统保存",
      .mctsStateExportFailed: "搜索状态导出失败",
      .sgfExporting: "正在准备棋谱",
      .sgfExportReady: "棋谱已交给系统保存",
      .sgfExportFailed: "棋谱导出失败",
      .openSheetTitle: "打开",
      .openSheetIdle: "从列表打开存档，或浏览其他文件",
      .openChooseSGF: "打开棋谱 (.sgf)",
      .openChooseMCTSState: "打开搜索状态 (.qixi.png)",
      .openChooseFile: "打开文件",
      .openEmptyList: "暂无存档。使用「存档」保存后会出现在此列表。",
      .openICloudBadge: "iCloud",
      .openHint: "列表为本地与 iCloud 中的 .qixi.png 存档；也可浏览其他位置。",
      .openBusyHint: "引擎正在处理，请稍后再打开文件。",
      .openLoading: "正在打开…",
      .openFailed: "打开失败",
      .archiveSheetTitle: "存档",
      .archiveFileNameLabel: "文件名",
      .archiveFileNamePlaceholder: "输入存档名称",
      .archiveContentsLabel: "存档内容",
      .archiveIncludeSGF: "棋谱 (.sgf)",
      .archiveIncludeSearchState: "搜索状态 (.qixi.png)",
      .archiveSaveTo: "保存到…",
      .archiveSaveSync: "保存",
      .archiveAlwaysBothHint: "始终同时保存棋谱 (.sgf) 与搜索状态 (.qixi.png)",
      .archiveHint: "首次保存时请输入文件名。保存到本机「Qixi Game Analysis Archives」；iCloud 可用时写入同名文件夹。",
      .archiveHintExisting: "将直接覆盖当前文件（与 WPS 相同）。",
      .archiveThumbnailLabel: "盘面缩略图",
      .archiveExporting: "正在保存…",
      .archiveExportReady: "存档已交给系统保存",
      .archiveSyncReady: "已创建并保存",
      .archiveSyncReadyExisting: "已覆盖保存",
      .archiveExportFailed: "存档失败",
      .exportShareSheetTitle: "导出/分享",
      .exportShareHint: "可将 .sgf 与 .qixi.png 保存到其他位置，或通过微信、QQ 等分享。",
      .exportSaveToFiles: "保存到其他位置…",
      .exportShareAction: "分享…",
      .exportSharePreparing: "正在准备文件…",
      .exportShareReady: "已完成",
      .exportShareFailed: "导出失败",
      .unsavedChangesTitle: "未保存的更改",
      .unsavedChangesMessage: "当前局面有未保存的更改，是否先存档？",
      .unsavedChangesSave: "保存",
      .unsavedChangesDiscard: "不保存",
      .unsavedChangesCancel: "取消",
      .backendRestoringState: "正在恢复上次状态",
      .backendLoadingEngine: "正在切换分析引擎",
      .backendInstallingModel: "正在安装分析模型",
      .memoryPressureUnloading: "正在释放内存",
      .memoryPressureReloading: "正在恢复分析数据",
      .memoryPressureUnloadingEngine: "正在卸载引擎以释放内存",
      .memoryPressureSavingAndFreeing: "正在保存分析并释放内存",
      .memoryPressureStoreUnloaded: "搜索树已写入磁盘并从内存卸载",
      .syncSheetTitle: "同步",
      .syncEnabled: "iCloud 已开启",
      .syncDisabled: "iCloud 未开启",
      .syncLastSynced: "最近同步：%@",
      .syncErrorTitle: "同步需要处理",
      .syncErrorMessage: "同步失败，请检查 iCloud 状态后重试。",
      .syncConflictMessage: "本地和 iCloud 存档冲突，当前不会覆盖任一版本。",
      .syncNow: "立即同步"
    ],
    .zhHant: [
      .languageZhHans: "简体中文",
      .languageZhHant: "繁體中文",
      .languageEn: "English",
      .engineNone: "無引擎",
      .enginePause: "暫停",
      .engineB6: "b6",
      .engineB18: "b18nbt",
      .engineB28: "b28nbt",
      .hermesReady: "已就緒",
      .hermesLoading: "載入中",
      .hermesOffline: "引擎離線",
      .engineErrorTitle: "引擎需要處理",
      .engineErrorLibraryNotLinked: "目前建置尚未連結 iPad 原生 KataGo 函式庫。",
      .engineErrorModelMissing: "未安裝模型：%@。",
      .engineErrorInsufficientMemory: "%@ 至少需要 %d MB 可用記憶體；目前約為 %d MB。",
      .engineErrorLocalNetworkDenied: "本地網路權限被拒絕。請在 iPad 設定中允許棋析取用本地網路。",
      .engineErrorUnloadFailed: "卸載引擎失敗：%@",
      .engineErrorAnalysisFailed: "分析失敗：%@",
      .engineErrorModelInstallFailed: "模型安裝失敗：%@",
      .boardPass: "停一手",
      .boardTerritory: "領地",
      .settingsKomi: "貼目",
      .settingsWideRootNoise: "寬根噪聲",
      .utilityNew: "新建",
      .utilityCamera: "拍照",
      .utilityImport: "打開",
      .utilitySync: "存檔",
      .utilityExportShare: "匯出/分享",
      .treeMoveNumber: "第%d手",
      .onboardingTitle: "棋析",
      .onboardingSubtitle: "選擇介面語言後開始使用。",
      .onboardingLanguageTitle: "語言",
      .onboardingContinue: "開始使用",
      .sheetDone: "完成",
      .cameraSheetTitle: "拍照識別",
      .cameraSheetIdle: "選擇棋盤照片",
      .cameraChoosePhoto: "選擇照片",
      .cameraImageLoaded: "照片已載入",
      .cameraSelectionHint: "框住棋盤網格四角",
      .cameraCancelSelection: "取消",
      .cameraRecognizeSelection: "識別",
      .cameraRecognizedStones: "識別到 %d 顆棋子（黑 %d / 白 %d）",
      .cameraHistoryWarning: "識別會把目前棋譜替換為照片中的局面（僅可見棋子，無手数歷史）。確認後再掃描。",
      .cameraRecognitionFailed: "識別失敗",
      .cameraNextPlayerLabel: "輪到誰下？",
      .cameraNextPlayerBlack: "黑方",
      .cameraNextPlayerWhite: "白方",
      .cameraApplyRecognition: "確認",
      .cameraRetryCorners: "重調四角",
      .cameraDiscardRecognition: "放棄",
      .importSheetTitle: "打開",
      .importSheetIdle: "打開 .sgf 棋譜或 .qixi.png 搜尋狀態",
      .importChooseFile: "選擇檔案",
      .importChooseSGF: "打開棋譜 (.sgf)",
      .importChooseMCTSState: "打開搜尋狀態 (.qixi.png)",
      .exportSGF: "匯出棋譜 (.sgf)",
      .exportMCTSState: "匯出搜尋狀態 (.qixi.png)",
      .importLoadedMoves: "已打開 %d 手",
      .importFailed: "打開失敗",
      .mctsStateImporting: "正在打開搜尋狀態",
      .mctsStateImported: "已打開搜尋狀態",
      .mctsStateImportFailed: "搜尋狀態打開失敗",
      .mctsStateExporting: "正在準備搜尋狀態",
      .mctsStateExportReady: "搜尋狀態已交給系統儲存",
      .mctsStateExportFailed: "搜尋狀態匯出失敗",
      .sgfExporting: "正在準備棋譜",
      .sgfExportReady: "棋譜已交給系統儲存",
      .sgfExportFailed: "棋譜匯出失敗",
      .openSheetTitle: "打開",
      .openSheetIdle: "從列表打開存檔，或瀏覽其他檔案",
      .openChooseSGF: "打開棋譜 (.sgf)",
      .openChooseMCTSState: "打開搜尋狀態 (.qixi.png)",
      .openChooseFile: "打開檔案",
      .openEmptyList: "暫無存檔。使用「存檔」儲存後會出現在此列表。",
      .openICloudBadge: "iCloud",
      .openHint: "列表為本機與 iCloud 中的 .qixi.png 存檔；也可瀏覽其他位置。",
      .openBusyHint: "引擎正在處理，請稍後再打開檔案。",
      .openLoading: "正在打開…",
      .openFailed: "打開失敗",
      .archiveSheetTitle: "存檔",
      .archiveFileNameLabel: "檔名",
      .archiveFileNamePlaceholder: "輸入存檔名稱",
      .archiveContentsLabel: "存檔內容",
      .archiveIncludeSGF: "棋譜 (.sgf)",
      .archiveIncludeSearchState: "搜尋狀態 (.qixi.png)",
      .archiveSaveTo: "儲存到…",
      .archiveSaveSync: "儲存",
      .archiveAlwaysBothHint: "始終同時儲存棋譜 (.sgf) 與搜尋狀態 (.qixi.png)",
      .archiveHint: "首次儲存時請輸入檔名。儲存到本機「Qixi Game Analysis Archives」；iCloud 可用時寫入同名資料夾。",
      .archiveHintExisting: "將直接覆蓋目前檔案（與 WPS 相同）。",
      .archiveThumbnailLabel: "盤面縮圖",
      .archiveExporting: "正在儲存…",
      .archiveExportReady: "存檔已交給系統儲存",
      .archiveSyncReady: "已建立並儲存",
      .archiveSyncReadyExisting: "已覆蓋儲存",
      .archiveExportFailed: "存檔失敗",
      .exportShareSheetTitle: "匯出/分享",
      .exportShareHint: "可將 .sgf 與 .qixi.png 儲存到其他位置，或透過微信、QQ 等分享。",
      .exportSaveToFiles: "儲存到其他位置…",
      .exportShareAction: "分享…",
      .exportSharePreparing: "正在準備檔案…",
      .exportShareReady: "已完成",
      .exportShareFailed: "匯出失敗",
      .unsavedChangesTitle: "未儲存的變更",
      .unsavedChangesMessage: "目前局面有未儲存的變更，是否先存檔？",
      .unsavedChangesSave: "儲存",
      .unsavedChangesDiscard: "不儲存",
      .unsavedChangesCancel: "取消",
      .backendRestoringState: "正在恢復上次狀態",
      .backendLoadingEngine: "正在切換分析引擎",
      .backendInstallingModel: "正在安裝分析模型",
      .memoryPressureUnloading: "正在釋放記憶體",
      .memoryPressureReloading: "正在恢復分析資料",
      .memoryPressureUnloadingEngine: "正在卸載引擎以釋放記憶體",
      .memoryPressureSavingAndFreeing: "正在儲存分析並釋放記憶體",
      .memoryPressureStoreUnloaded: "搜尋樹已寫入磁碟並從記憶體卸載",
      .syncSheetTitle: "同步",
      .syncEnabled: "iCloud 已開啟",
      .syncDisabled: "iCloud 未開啟",
      .syncLastSynced: "最近同步：%@",
      .syncErrorTitle: "同步需要處理",
      .syncErrorMessage: "同步失敗，請檢查 iCloud 狀態後重試。",
      .syncConflictMessage: "本機和 iCloud 存檔衝突，目前不會覆蓋任一版本。",
      .syncNow: "立即同步"
    ],
    .en: [
      .languageZhHans: "简体中文",
      .languageZhHant: "繁體中文",
      .languageEn: "English",
      .engineNone: "No Engine",
      .enginePause: "Pause",
      .engineB6: "b6",
      .engineB18: "b18nbt",
      .engineB28: "b28nbt",
      .hermesReady: "Ready",
      .hermesLoading: "Loading",
      .hermesOffline: "Engine Offline",
      .engineErrorTitle: "Engine Needs Attention",
      .engineErrorLibraryNotLinked: "This build has not linked the iPad-native KataGo library yet.",
      .engineErrorModelMissing: "Model not installed: %@.",
      .engineErrorInsufficientMemory: "%@ needs at least %d MB available memory; this device has about %d MB.",
      .engineErrorLocalNetworkDenied: "Local Network access is denied. Allow Qixi to access Local Network in iPad Settings.",
      .engineErrorUnloadFailed: "Engine unload failed: %@",
      .engineErrorAnalysisFailed: "Analysis failed: %@",
      .engineErrorModelInstallFailed: "Model install failed: %@",
      .boardPass: "Pass",
      .boardTerritory: "Territory",
      .settingsKomi: "Komi",
      .settingsWideRootNoise: "Root Noise",
      .utilityNew: "New",
      .utilityCamera: "Camera",
      .utilityImport: "Open",
      .utilitySync: "Archive",
      .utilityExportShare: "Export/Share",
      .treeMoveNumber: "Move %d",
      .onboardingTitle: "Qixi",
      .onboardingSubtitle: "Choose an interface language to get started.",
      .onboardingLanguageTitle: "Language",
      .onboardingContinue: "Start",
      .sheetDone: "Done",
      .cameraSheetTitle: "Photo Scan",
      .cameraSheetIdle: "Choose a board photo",
      .cameraChoosePhoto: "Choose Photo",
      .cameraImageLoaded: "Photo Loaded",
      .cameraSelectionHint: "Frame the four grid corners",
      .cameraCancelSelection: "Cancel",
      .cameraRecognizeSelection: "Scan",
      .cameraRecognizedStones: "Recognized %d stones (B %d / W %d)",
      .cameraHistoryWarning: "Scanning replaces the current game with the stones in the photo (visible stones only; no move history). Confirm before scanning.",
      .cameraRecognitionFailed: "Recognition Failed",
      .cameraNextPlayerLabel: "Who moves next?",
      .cameraNextPlayerBlack: "Black",
      .cameraNextPlayerWhite: "White",
      .cameraApplyRecognition: "Apply",
      .cameraRetryCorners: "Adjust corners",
      .cameraDiscardRecognition: "Discard",
      .importSheetTitle: "Open",
      .importSheetIdle: "Open a .sgf game or .qixi.png search state",
      .importChooseFile: "Choose File",
      .importChooseSGF: "Open Game (.sgf)",
      .importChooseMCTSState: "Open Search State (.qixi.png)",
      .exportSGF: "Export Game (.sgf)",
      .exportMCTSState: "Export Search State (.qixi.png)",
      .importLoadedMoves: "Opened %d moves",
      .importFailed: "Open Failed",
      .mctsStateImporting: "Opening Search State",
      .mctsStateImported: "Search State Opened",
      .mctsStateImportFailed: "Search State Open Failed",
      .mctsStateExporting: "Preparing Search State",
      .mctsStateExportReady: "Search State Sent to Files",
      .mctsStateExportFailed: "Search State Export Failed",
      .sgfExporting: "Preparing Game Record",
      .sgfExportReady: "Game Record Sent to Files",
      .sgfExportFailed: "Game Record Export Failed",
      .openSheetTitle: "Open",
      .openSheetIdle: "Open from the list, or browse other files",
      .openChooseSGF: "Open Game (.sgf)",
      .openChooseMCTSState: "Open Search State (.qixi.png)",
      .openChooseFile: "Open File",
      .openEmptyList: "No archives yet. Use Archive to save one.",
      .openICloudBadge: "iCloud",
      .openHint: "Lists local and iCloud .qixi.png archives; browse for other locations.",
      .openBusyHint: "The engine is busy. Wait a moment, then open a file.",
      .openLoading: "Opening…",
      .openFailed: "Open Failed",
      .archiveSheetTitle: "Archive",
      .archiveFileNameLabel: "File name",
      .archiveFileNamePlaceholder: "Archive name",
      .archiveContentsLabel: "Contents",
      .archiveIncludeSGF: "Game record (.sgf)",
      .archiveIncludeSearchState: "Search state (.qixi.png)",
      .archiveSaveTo: "Save To…",
      .archiveSaveSync: "Save",
      .archiveAlwaysBothHint: "Always saves both game record (.sgf) and search state (.qixi.png)",
      .archiveHint: "Choose a file name on first save. Writes to local “Qixi Game Analysis Archives” and the same iCloud folder when available.",
      .archiveHintExisting: "Replaces the current file in place (like WPS).",
      .archiveThumbnailLabel: "Board thumbnail",
      .archiveExporting: "Saving…",
      .archiveExportReady: "Archive sent to Files",
      .archiveSyncReady: "Created and saved",
      .archiveSyncReadyExisting: "Replaced existing file",
      .archiveExportFailed: "Archive failed",
      .exportShareSheetTitle: "Export/Share",
      .exportShareHint: "Save .sgf and .qixi.png elsewhere, or share via apps such as WeChat and QQ.",
      .exportSaveToFiles: "Save to another location…",
      .exportShareAction: "Share…",
      .exportSharePreparing: "Preparing files…",
      .exportShareReady: "Done",
      .exportShareFailed: "Export failed",
      .unsavedChangesTitle: "Unsaved Changes",
      .unsavedChangesMessage: "Save your current game before continuing?",
      .unsavedChangesSave: "Save",
      .unsavedChangesDiscard: "Don’t Save",
      .unsavedChangesCancel: "Cancel",
      .backendRestoringState: "Restoring Previous State",
      .backendLoadingEngine: "Switching Analysis Engine",
      .backendInstallingModel: "Installing Analysis Model",
      .memoryPressureUnloading: "Freeing Memory",
      .memoryPressureReloading: "Reloading Analysis",
      .memoryPressureUnloadingEngine: "Unloading engine to free memory",
      .memoryPressureSavingAndFreeing: "Saving analysis and freeing memory",
      .memoryPressureStoreUnloaded: "Search tree saved to disk and unloaded from memory",
      .syncSheetTitle: "Sync",
      .syncEnabled: "iCloud Enabled",
      .syncDisabled: "iCloud Disabled",
      .syncLastSynced: "Last synced: %@",
      .syncErrorTitle: "Sync Needs Attention",
      .syncErrorMessage: "Sync failed. Check iCloud status and try again.",
      .syncConflictMessage: "Local and iCloud saves conflict. Neither version was overwritten.",
      .syncNow: "Sync Now"
    ]
  ]
}
