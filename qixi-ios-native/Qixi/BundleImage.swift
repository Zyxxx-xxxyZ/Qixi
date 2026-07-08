import Foundation
import SwiftUI
import UIKit

private final class BundleImageCache {
  static let shared = BundleImageCache()

  private let lock = NSLock()
  private var images: [String: UIImage] = [:]

  func image(named name: String) -> UIImage? {
    lock.lock()
    if let image = images[name] {
      lock.unlock()
      return image
    }
    lock.unlock()

    guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
          let loadedImage = UIImage(contentsOfFile: url.path) else {
      return nil
    }

    lock.lock()
    if let image = images[name] {
      lock.unlock()
      return image
    }
    images[name] = loadedImage
    lock.unlock()
    return loadedImage
  }
}

struct BundleImage: View {
  var name: String
  var body: some View {
    if let image = BundleImageCache.shared.image(named: name) {
      Image(uiImage: image)
        .resizable()
    } else {
      Color.red.opacity(0.18)
    }
  }
}
