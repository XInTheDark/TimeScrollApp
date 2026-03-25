import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct PrivacyPane: View {
  @ObservedObject var settings: SettingsStore
  @State private var selection = Set<String>()

  var body: some View {
    SettingsPaneScrollView {
      SettingsSectionCard(
        title: "Blacklisted Apps",
        subtitle: "Windows from these apps are excluded from capture whenever they are visible."
      ) {
        Group {
          if settings.blacklistBundleIds.isEmpty {
            emptyState
          } else {
            appList
          }
        }

        HStack(spacing: 10) {
          Text(selectionSummary)
            .font(.footnote)
            .foregroundColor(.secondary)

          Spacer()

          Button(action: addApps) {
            Label("Add App…", systemImage: "plus")
          }

          Button(role: .destructive, action: removeSelected) {
            Label("Remove", systemImage: "trash")
          }
          .disabled(selection.isEmpty)
        }
      }
    }
    .onChange(of: settings.blacklistBundleIds) { newList in
      Task { @MainActor in
        await AppState.shared.captureManager.updateExclusions(with: newList)
      }
    }
  }

  private var appList: some View {
    List(selection: $selection) {
      ForEach(settings.blacklistBundleIds, id: \.self) { bid in
        PrivacyAppRow(bundleId: bid)
          .tag(bid)
      }
    }
    .frame(minHeight: 280)
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
  }

  private var emptyState: some View {
    VStack(spacing: 10) {
      Image(systemName: "checkmark.shield")
        .font(.system(size: 28, weight: .medium))
        .foregroundColor(.secondary)

      Text("No apps excluded")
        .font(.headline)

      Text("Add an app here if you never want its windows to be captured.")
        .font(.subheadline)
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
    .frame(minHeight: 220)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(Color(nsColor: .textBackgroundColor))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(Color(nsColor: .separatorColor).opacity(0.22), lineWidth: 1)
    )
  }

  private var selectionSummary: String {
    if selection.isEmpty {
      let count = settings.blacklistBundleIds.count
      return count == 1 ? "1 app excluded from capture" : "\(count) apps excluded from capture"
    }

    let count = selection.count
    return count == 1 ? "1 app selected" : "\(count) apps selected"
  }

  private func addApps() {
    let panel = NSOpenPanel()
    panel.title = "Choose Applications to Blacklist"
    panel.allowsMultipleSelection = true
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowedContentTypes = [.application]
    panel.begin { resp in
      guard resp == .OK else { return }
      var newIds = settings.blacklistBundleIds
      for url in panel.urls {
        if let bid = Bundle(url: url)?.bundleIdentifier {
          if !newIds.contains(bid) {
            newIds.append(bid)
          }
        }
      }
      settings.blacklistBundleIds = newIds
    }
  }

  private func removeSelected() {
    let toRemove = selection
    selection.removeAll()
    settings.blacklistBundleIds.removeAll { toRemove.contains($0) }
  }
}

private struct PrivacyAppRow: View {
  let bundleId: String

  @State private var displayName: String
  @State private var icon: NSImage? = nil
  @State private var requestedMetadata = false

  init(bundleId: String) {
    self.bundleId = bundleId
    _displayName = State(initialValue: bundleId)
  }

  var body: some View {
    HStack(spacing: 10) {
      iconView

      VStack(alignment: .leading, spacing: 2) {
        Text(displayName)
        Text(bundleId)
          .font(.caption)
          .foregroundColor(.secondary)
      }

      Spacer(minLength: 0)
    }
    .onAppear(perform: loadMetadataIfNeeded)
  }

  private var iconView: some View {
    Group {
      if let icon {
        Image(nsImage: icon)
          .resizable()
          .aspectRatio(contentMode: .fit)
      } else {
        Image(systemName: "app")
          .resizable()
          .aspectRatio(contentMode: .fit)
          .foregroundColor(.secondary)
      }
    }
    .frame(width: 20, height: 20)
  }

  private func loadMetadataIfNeeded() {
    if let cachedName = AppDisplayNameCache.shared.cachedName(for: bundleId) {
      displayName = cachedName
    }
    if let cachedIcon = AppIconCache.shared.cachedIcon(for: bundleId) {
      icon = cachedIcon
    }

    guard !requestedMetadata else { return }
    requestedMetadata = true

    AppDisplayNameCache.shared.loadNameAsync(for: bundleId) { resolvedName in
      displayName = resolvedName
    }
    AppIconCache.shared.loadIconAsync(for: bundleId) { resolvedIcon in
      icon = resolvedIcon
    }
  }
}

private final class AppDisplayNameCache {
  static let shared = AppDisplayNameCache()

  private let lock = NSLock()
  private let cache = NSCache<NSString, NSString>()
  private var inFlight = Set<String>()
  private var waiters: [String: [(String) -> Void]] = [:]

  private init() {
    cache.countLimit = 256
  }

  func cachedName(for bundleId: String) -> String? {
    cache.object(forKey: bundleId as NSString) as String?
  }

  func loadNameAsync(for bundleId: String, completion: ((String) -> Void)? = nil) {
    let key = bundleId as NSString
    if let cached = cache.object(forKey: key) as String? {
      completion?(cached)
      return
    }

    lock.lock()
    if let completion {
      waiters[bundleId, default: []].append(completion)
    }
    if inFlight.contains(bundleId) {
      lock.unlock()
      return
    }
    inFlight.insert(bundleId)
    lock.unlock()

    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      let resolvedName = self.resolveName(for: bundleId)
      self.cache.setObject(resolvedName as NSString, forKey: key)

      self.lock.lock()
      let callbacks = self.waiters.removeValue(forKey: bundleId) ?? []
      self.inFlight.remove(bundleId)
      self.lock.unlock()

      callbacks.forEach { $0(resolvedName) }
    }
  }

  private func resolveName(for bundleId: String) -> String {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
      return bundleId
    }
    if let name = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleName") as? String {
      return name
    }
    let displayName = FileManager.default.displayName(atPath: url.path)
    return displayName.replacingOccurrences(of: ".app", with: "")
  }
}
