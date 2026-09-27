import Foundation
import Security

/// Lists contain names only. Secret values are read only when editing or copying.
public struct CredentialEntry: Identifiable, Equatable {
    public let id: String
    public let title: String
}

public struct CredentialStore {
    private let service: String

    public init(service: String = "com.clipflow.mac.credentials") {
        self.service = service
    }

    public func loadEntries() throws -> [CredentialEntry] {
        var query = baseQuery
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        try check(status)
        guard let attributes = result as? [[String: Any]] else {
            throw StoreError(status: errSecDecode)
        }
        return try attributes.map { item in
            guard let id = item[kSecAttrAccount as String] as? String,
                  let title = item[kSecAttrLabel as String] as? String else {
                throw StoreError(status: errSecDecode)
            }
            return CredentialEntry(id: id, title: title)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    public func secret(id: String) throws -> String {
        var query = itemQuery(id)
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        try check(SecItemCopyMatching(query as CFDictionary, &result))
        guard let data = result as? Data, let secret = String(data: data, encoding: .utf8) else {
            throw StoreError(status: errSecDecode)
        }
        return secret
    }

    @discardableResult
    public func save(id: String? = nil, title: String, secret: String) throws -> String {
        let attributes: [String: Any] = [
            kSecAttrLabel as String: title,
            kSecValueData as String: Data(secret.utf8)
        ]
        if let id {
            try check(SecItemUpdate(itemQuery(id) as CFDictionary, attributes as CFDictionary))
            return id
        }
        let id = UUID().uuidString
        var query = itemQuery(id)
        query.merge(attributes) { _, new in new }
        try check(SecItemAdd(query as CFDictionary, nil))
        return id
    }

    public func delete(id: String) throws {
        let status = SecItemDelete(itemQuery(id) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false
        ]
    }

    private func itemQuery(_ id: String) -> [String: Any] {
        var query = baseQuery
        query[kSecAttrAccount as String] = id
        return query
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw StoreError(status: status) }
    }

    private struct StoreError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            (SecCopyErrorMessageString(status, nil) as String?) ?? "钥匙串操作失败（\(status)）"
        }
    }
}
