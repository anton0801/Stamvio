import Foundation
import Observation
import Security

/// How much of the Free plan has been used, for the whole life of the app on this device.
/// Deleting or archiving photos and projects does not give the quota back (owner decision,
/// see Docs/TZ-Changelog.md). Holds two numbers only — no user content, no identifiers.
struct FreeUsage: Codable, Equatable {
    var photosAdded = 0
    var projectsCreated = 0
}

protocol UsageStore: AnyObject {
    func load() -> FreeUsage?
    func save(_ usage: FreeUsage)
    func clear()
}

/// Keychain item of this app (not synchronized). It survives "Delete all data" and reinstalling,
/// so the Free quota cannot be restarted by deleting data.
final class KeychainUsageStore: UsageStore {
    private let service = "workphotos.free-usage"
    private let account = "usage.v1"

    private var query: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }

    func load() -> FreeUsage? {
        var request = query
        request[kSecReturnData] = true
        request[kSecMatchLimit] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(FreeUsage.self, from: data)
    }

    func save(_ usage: FreeUsage) {
        guard let data = try? JSONEncoder().encode(usage) else { return }
        let attributes: [CFString: Any] = [kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            var item = query
            item.merge(attributes) { _, new in new }
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    func clear() {
        SecItemDelete(query as CFDictionary)
    }
}

/// Store for tests and previews.
final class MemoryUsageStore: UsageStore {
    private var value: FreeUsage?

    init(_ value: FreeUsage? = nil) { self.value = value }

    func load() -> FreeUsage? { value }
    func save(_ usage: FreeUsage) { value = usage }
    func clear() { value = nil }
}

@MainActor
@Observable
final class UsageLedger {
    private(set) var usage: FreeUsage
    private let store: UsageStore
    #if DEBUG
    /// UI tests only (`-uitest-free-photo-quota N`): a larger Free photo quota so import fixtures can be checked.
    var debugPhotoQuota: Int?
    #endif

    init(store: UsageStore = KeychainUsageStore()) {
        self.store = store
        usage = store.load() ?? FreeUsage()
    }

    var photoQuota: Int {
        #if DEBUG
        if let debugPhotoQuota { return debugPhotoQuota }
        #endif
        return AccessPolicy.freeLifetimePhotoLimit
    }

    func recordPhotosAdded(_ count: Int = 1) {
        guard count > 0 else { return }
        usage.photosAdded += count
        store.save(usage)
    }

    func recordProjectCreated() {
        usage.projectsCreated += 1
        store.save(usage)
    }

    /// Never lower than what exists on the device (e.g. data from before this ledger, restored
    /// backups or recovered files). Only ever increases.
    func reconcile(existingPhotos: Int, existingProjects: Int) {
        let reconciled = FreeUsage(photosAdded: max(usage.photosAdded, existingPhotos),
                                   projectsCreated: max(usage.projectsCreated, existingProjects))
        guard reconciled != usage else { return }
        usage = reconciled
        store.save(usage)
    }

    #if DEBUG
    func resetForUITests() {
        store.clear()
        usage = FreeUsage()
    }
    #endif
}
