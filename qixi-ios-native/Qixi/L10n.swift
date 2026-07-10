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
    case treeMoveNumber
    case onboardingTitle
    case onboardingSubtitle
    case onboardingLanguageTitle
    case onboardingICloudTitle
    case onboardingICloudSubtitle
    case onboardingEnableICloud
    case onboardingSkipICloud
    case onboardingContinue
    case sheetDone
    case cameraSheetTitle
    case cameraSheetIdle
    case cameraChoosePhoto
    case cameraImageLoaded
    case cameraSelectionHint
    case cameraAutoSelection
    case cameraCancelSelection
    case cameraRecognizeSelection
    case cameraRecognizedStones
    case cameraHistoryWarning
    case cameraRecognitionFailed
    case importSheetTitle
    case importSheetIdle
    case importChooseFile
    case importChooseSGF
    case importChooseMCTSState
    case exportMCTSState
    case importLoadedMoves
    case importFailed
    case mctsStateImporting
    case mctsStateImported
    case mctsStateImportFailed
    case mctsStateExporting
    case mctsStateExportReady
    case mctsStateExportFailed
    case backendRestoringState
    case backendLoadingEngine
    case backendInstallingModel
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
      .utilityImport: "导入",
      .utilitySync: "同步",
      .treeMoveNumber: "第%d手",
      .onboardingTitle: "棋析",
      .onboardingSubtitle: "选择语言，并决定是否开启 iCloud 多端同步。",
      .onboardingLanguageTitle: "语言",
      .onboardingICloudTitle: "iCloud 同步",
      .onboardingICloudSubtitle: "同步棋谱、当前进度和分析缓存；也可以稍后再开启。",
      .onboardingEnableICloud: "开启同步",
      .onboardingSkipICloud: "跳过",
      .onboardingContinue: "开始使用",
      .sheetDone: "完成",
      .cameraSheetTitle: "拍照识别",
      .cameraSheetIdle: "选择棋盘照片",
      .cameraChoosePhoto: "选择照片",
      .cameraImageLoaded: "照片已载入",
      .cameraSelectionHint: "框住棋盘网格四角",
      .cameraAutoSelection: "自动定位",
      .cameraCancelSelection: "取消",
      .cameraRecognizeSelection: "识别",
      .cameraRecognizedStones: "识别到 %d 颗棋子（黑 %d / 白 %d）",
      .cameraHistoryWarning: "识别结果仅作可见棋子预览，不会改变当前手顺或分析根；相同棋子但不同手顺不是同一局面。",
      .cameraRecognitionFailed: "识别失败",
      .importSheetTitle: "导入与导出",
      .importSheetIdle: "选择 SGF 或搜索状态文件",
      .importChooseFile: "选择文件",
      .importChooseSGF: "导入棋谱",
      .importChooseMCTSState: "导入搜索状态",
      .exportMCTSState: "导出搜索状态",
      .importLoadedMoves: "已导入 %d 手",
      .importFailed: "导入失败",
      .mctsStateImporting: "正在导入搜索状态",
      .mctsStateImported: "已导入搜索状态",
      .mctsStateImportFailed: "搜索状态导入失败",
      .mctsStateExporting: "正在准备搜索状态",
      .mctsStateExportReady: "搜索状态已交给系统保存",
      .mctsStateExportFailed: "搜索状态导出失败",
      .backendRestoringState: "正在恢复上次状态",
      .backendLoadingEngine: "正在切换分析引擎",
      .backendInstallingModel: "正在安装分析模型",
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
      .utilityImport: "匯入",
      .utilitySync: "同步",
      .treeMoveNumber: "第%d手",
      .onboardingTitle: "棋析",
      .onboardingSubtitle: "選擇語言，並決定是否開啟 iCloud 多端同步。",
      .onboardingLanguageTitle: "語言",
      .onboardingICloudTitle: "iCloud 同步",
      .onboardingICloudSubtitle: "同步棋譜、目前進度和分析快取；也可以稍後再開啟。",
      .onboardingEnableICloud: "開啟同步",
      .onboardingSkipICloud: "跳過",
      .onboardingContinue: "開始使用",
      .sheetDone: "完成",
      .cameraSheetTitle: "拍照識別",
      .cameraSheetIdle: "選擇棋盤照片",
      .cameraChoosePhoto: "選擇照片",
      .cameraImageLoaded: "照片已載入",
      .cameraSelectionHint: "框住棋盤網格四角",
      .cameraAutoSelection: "自動定位",
      .cameraCancelSelection: "取消",
      .cameraRecognizeSelection: "識別",
      .cameraRecognizedStones: "識別到 %d 顆棋子（黑 %d / 白 %d）",
      .cameraHistoryWarning: "識別結果僅作可見棋子預覽，不會改變目前手順或分析根；相同棋子但不同手順不是同一局面。",
      .cameraRecognitionFailed: "識別失敗",
      .importSheetTitle: "匯入與匯出",
      .importSheetIdle: "選擇 SGF 或搜尋狀態檔案",
      .importChooseFile: "選擇檔案",
      .importChooseSGF: "匯入棋譜",
      .importChooseMCTSState: "匯入搜尋狀態",
      .exportMCTSState: "匯出搜尋狀態",
      .importLoadedMoves: "已匯入 %d 手",
      .importFailed: "匯入失敗",
      .mctsStateImporting: "正在匯入搜尋狀態",
      .mctsStateImported: "已匯入搜尋狀態",
      .mctsStateImportFailed: "搜尋狀態匯入失敗",
      .mctsStateExporting: "正在準備搜尋狀態",
      .mctsStateExportReady: "搜尋狀態已交給系統儲存",
      .mctsStateExportFailed: "搜尋狀態匯出失敗",
      .backendRestoringState: "正在恢復上次狀態",
      .backendLoadingEngine: "正在切換分析引擎",
      .backendInstallingModel: "正在安裝分析模型",
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
      .utilityImport: "Import",
      .utilitySync: "Sync",
      .treeMoveNumber: "Move %d",
      .onboardingTitle: "Qixi",
      .onboardingSubtitle: "Choose a language and decide whether to enable iCloud sync.",
      .onboardingLanguageTitle: "Language",
      .onboardingICloudTitle: "iCloud Sync",
      .onboardingICloudSubtitle: "Sync games, progress, and analysis cache. You can turn it on later.",
      .onboardingEnableICloud: "Enable Sync",
      .onboardingSkipICloud: "Skip",
      .onboardingContinue: "Start",
      .sheetDone: "Done",
      .cameraSheetTitle: "Photo Scan",
      .cameraSheetIdle: "Choose a board photo",
      .cameraChoosePhoto: "Choose Photo",
      .cameraImageLoaded: "Photo Loaded",
      .cameraSelectionHint: "Frame the four grid corners",
      .cameraAutoSelection: "Auto",
      .cameraCancelSelection: "Cancel",
      .cameraRecognizeSelection: "Scan",
      .cameraRecognizedStones: "Recognized %d stones (B %d / W %d)",
      .cameraHistoryWarning: "Scan results preview visible stones only. They do not change the move history or analysis root; same stones with different history are not the same position.",
      .cameraRecognitionFailed: "Recognition Failed",
      .importSheetTitle: "Import and Export",
      .importSheetIdle: "Choose an SGF or search state file",
      .importChooseFile: "Choose File",
      .importChooseSGF: "Import Game",
      .importChooseMCTSState: "Import Search State",
      .exportMCTSState: "Export Search State",
      .importLoadedMoves: "Imported %d moves",
      .importFailed: "Import Failed",
      .mctsStateImporting: "Importing Search State",
      .mctsStateImported: "Search State Imported",
      .mctsStateImportFailed: "Search State Import Failed",
      .mctsStateExporting: "Preparing Search State",
      .mctsStateExportReady: "Search State Sent to Files",
      .mctsStateExportFailed: "Search State Export Failed",
      .backendRestoringState: "Restoring Previous State",
      .backendLoadingEngine: "Switching Analysis Engine",
      .backendInstallingModel: "Installing Analysis Model",
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
