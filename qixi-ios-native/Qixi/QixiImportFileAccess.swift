import Foundation
import UIKit

enum QixiImportedFileAccess {
  static func makeTemporaryLocalCopy(from pickedURL: URL) throws -> URL {
    let scoped = pickedURL.startAccessingSecurityScopedResource()
    defer {
      if scoped {
        pickedURL.stopAccessingSecurityScopedResource()
      }
    }

    requestUbiquitousDownloadIfNeeded(for: pickedURL)

    var coordinatedResult: Result<URL, Error>?
    var coordinationError: NSError?
    let coordinator = NSFileCoordinator(filePresenter: nil)
    coordinator.coordinate(readingItemAt: pickedURL, options: [], error: &coordinationError) { readableURL in
      coordinatedResult = Result {
        let temporaryURL = temporaryCopyURL(for: readableURL)
        if FileManager.default.fileExists(atPath: temporaryURL.path) {
          try FileManager.default.removeItem(at: temporaryURL)
        }
        try FileManager.default.copyItem(at: readableURL, to: temporaryURL)
        return temporaryURL
      }
    }

    if let coordinatedResult {
      return try coordinatedResult.get()
    }
    throw coordinationError ?? CocoaError(.fileReadUnknown)
  }

  static func removeTemporaryCopy(_ url: URL?) {
    guard let url else { return }
    try? FileManager.default.removeItem(at: url)
  }

  private static func requestUbiquitousDownloadIfNeeded(for url: URL) {
    let values = try? url.resourceValues(forKeys: [
      .isUbiquitousItemKey,
      .ubiquitousItemDownloadingStatusKey
    ])
    guard values?.isUbiquitousItem == true else { return }
    if values?.ubiquitousItemDownloadingStatus != .current {
      try? FileManager.default.startDownloadingUbiquitousItem(at: url)
    }
  }

  private static func temporaryCopyURL(for readableURL: URL) -> URL {
    let filename = readableURL.lastPathComponent.isEmpty ? "imported-file" : readableURL.lastPathComponent
    return FileManager.default.temporaryDirectory
      .appendingPathComponent("qixi-import-\(UUID().uuidString)-\(filename)", isDirectory: isDirectory(readableURL))
  }

  private static func isDirectory(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
  }
}
