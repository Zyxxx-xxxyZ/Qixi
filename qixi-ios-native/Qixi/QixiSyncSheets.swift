import SwiftUI

struct SyncSettingsSheet<Host: QixiSyncFeatureHost & ObservableObject>: View {
  @ObservedObject var host: Host

  var body: some View {
    VStack(spacing: 18) {
      Image(systemName: host.iCloudSyncEnabled ? "icloud.and.arrow.up" : "icloud.slash")
        .font(.system(size: 44, weight: .semibold))
        .foregroundStyle(host.iCloudSyncEnabled ? QixiColor.hermesBlue : Color.secondary)
      Text(host.iCloudSyncEnabled ? L10n.text(.syncEnabled) : L10n.text(.syncDisabled))
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(QixiColor.ink)
      if let lastSyncAt = host.syncStatus.lastSyncAt {
        HStack(alignment: .top, spacing: 10) {
          Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(QixiColor.successGreen)
          Text(
            String(
              format: L10n.text(.syncLastSynced),
              lastSyncAt.formatted(date: .abbreviated, time: .shortened)
            )
          )
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(QixiColor.ink)
          .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 360, alignment: .leading)
        .padding(12)
        .background(QixiColor.successGreen.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(QixiColor.successGreen.opacity(0.30), lineWidth: 0.8)
        )
      }
      if let lastError = host.syncStatus.lastError {
        HStack(alignment: .top, spacing: 10) {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(QixiColor.warningRed)
          VStack(alignment: .leading, spacing: 4) {
            Text(L10n.text(.syncErrorTitle))
              .font(.system(size: 14, weight: .semibold))
              .foregroundStyle(QixiColor.warningRed)
            Text(lastError)
              .font(.system(size: 13, weight: .medium))
              .foregroundStyle(QixiColor.ink)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .frame(maxWidth: 360, alignment: .leading)
        .padding(12)
        .background(QixiColor.warningRed.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(QixiColor.warningRed.opacity(0.28), lineWidth: 0.8)
        )
      }
      Button {
        host.syncNow()
      } label: {
        Label(L10n.text(.syncNow), systemImage: "arrow.triangle.2.circlepath")
          .frame(maxWidth: 320)
      }
      .buttonStyle(QixiCapsuleButtonStyle(isSelected: true))
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(24)
  }
}
