import Foundation

/// A vault as the database holds it: its public code, its key sealed under the
/// key made from its private key, and (on the owner's row) the owner's account
/// key sealed under their recovery phrase. Nothing here opens without one of
/// those two secrets.
struct VaultRow: Decodable, Identifiable, Equatable {
    let id: String
    let code: String
    let ownerEmail: String
    let keyID: String?
    let kdfSalt: String?
    let kdfRounds: Int?
    let sealedKey: String?
    let pendingKeyID: String?
    let pendingKdfSalt: String?
    let pendingKdfRounds: Int?
    let pendingSealedKey: String?
    let recoverySalt: String?
    let recoveryRounds: Int?
    let sealedAccountKey: String?

    enum CodingKeys: String, CodingKey {
        case id, code
        case ownerEmail = "owner_email"
        case keyID = "key_id"
        case kdfSalt = "kdf_salt"
        case kdfRounds = "kdf_rounds"
        case sealedKey = "sealed_key"
        case pendingKeyID = "pending_key_id"
        case pendingKdfSalt = "pending_kdf_salt"
        case pendingKdfRounds = "pending_kdf_rounds"
        case pendingSealedKey = "pending_sealed_key"
        case recoverySalt = "recovery_salt"
        case recoveryRounds = "recovery_rounds"
        case sealedAccountKey = "sealed_account_key"
    }

    /// False for a vault made for its owner ahead of time (AURORA), until they
    /// choose its private key.
    var hasKey: Bool { keyID != nil && sealedKey != nil && kdfSalt != nil }
}

/// One account's way into a vault: the vault's key sealed under the account key.
struct VaultGrant: Decodable, Equatable {
    let vaultID: String
    let keyID: String
    let sealedKey: String

    enum CodingKeys: String, CodingKey {
        case vaultID = "vault_id"
        case keyID = "key_id"
        case sealedKey = "sealed_key"
    }
}

enum VaultError: LocalizedError {
    case codeTaken
    case noSuchCode
    case wrongPrivateKey
    case wrongRecoveryPhrase
    case ownCode
    case notOwner
    case othersContacts
    case notSetUp
    case tableMissing

    var errorDescription: String? {
        switch self {
        case .codeTaken: "That code is taken. Choose another."
        case .noSuchCode: "No one has that code. Check it and try again."
        case .wrongPrivateKey: "That private key doesn't open this code."
        case .wrongRecoveryPhrase: "That recovery phrase doesn't match this account."
        case .ownCode: "That's your own code — your contacts are already here."
        case .notOwner: "Only the person who added this contact can change it."
        case .othersContacts: "Other people have contacts filed under this company, so it can't be deleted. Remove your own contacts from it instead."
        case .notSetUp: "This account's keys aren't set up yet."
        case .tableMissing: "The database needs a one-time update for private contacts. Run scripts/vault_migration.sql in the Supabase SQL editor."
        }
    }
}

/// The vault tables, and the bulk writes that seal rows in place.
enum VaultAPI {
    // MARK: Vaults

    static func vault(ownerEmail: String) async throws -> VaultRow? {
        try await vaults([URLQueryItem(name: "owner_email", value: "eq.\(ownerEmail.lowercased())")]).first
    }

    static func vault(code: String) async throws -> VaultRow? {
        try await vaults([URLQueryItem(name: "code", value: "eq.\(VaultCode.normalized(code))")]).first
    }

    static func vaults(ids: [String]) async throws -> [VaultRow] {
        guard !ids.isEmpty else { return [] }
        return try await vaults([URLQueryItem(name: "id", value: "in.(\(ids.joined(separator: ",")))")])
    }

    private static func vaults(_ filters: [URLQueryItem]) async throws -> [VaultRow] {
        let request = SupabaseAPI.makeRequest(path: "vaults", query: [URLQueryItem(name: "select", value: "*")] + filters)
        do {
            return try SupabaseAPI.decoder.decode([VaultRow].self, from: try await SupabaseAPI.send(request))
        } catch SupabaseError.schemaOutOfDate {
            throw VaultError.tableMissing
        }
    }

    static func createVault(_ body: [String: Any]) async throws {
        do {
            _ = try await SupabaseAPI.insertReturningID(path: "vaults", body: body)
        } catch SupabaseError.duplicateCompany {
            // A unique violation: the code (or this account's one vault) exists.
            throw VaultError.codeTaken
        }
    }

    /// Change a vault's row. `onlyIf` narrows it further — the first private
    /// key is only ever set on a vault that has none, so two phones can't both
    /// set one.
    static func updateVault(id: String, _ body: [String: Any], onlyIf: [URLQueryItem] = []) async throws {
        var body = body
        body["updated_at"] = SupabaseAPI.iso(Date())
        do {
            try await SupabaseAPI.write(method: "PATCH", path: "vaults",
                                        query: [URLQueryItem(name: "id", value: "eq.\(id)")] + onlyIf, body: body)
        } catch SupabaseError.duplicateCompany {
            throw VaultError.codeTaken
        }
    }

    // MARK: Grants

    static func grants(email: String) async throws -> [VaultGrant] {
        let request = SupabaseAPI.makeRequest(path: "vault_grants", query: [
            URLQueryItem(name: "select", value: "vault_id,key_id,sealed_key"),
            URLQueryItem(name: "account_email", value: "eq.\(email.lowercased())")
        ])
        do {
            return try SupabaseAPI.decoder.decode([VaultGrant].self, from: try await SupabaseAPI.send(request))
        } catch SupabaseError.schemaOutOfDate {
            throw VaultError.tableMissing
        }
    }

    static func addGrant(email: String, vaultID: String, keyID: String, sealedKey: String) async throws {
        try await SupabaseAPI.write(method: "POST", path: "vault_grants", body: [
            "account_email": email.lowercased(), "vault_id": vaultID, "key_id": keyID, "sealed_key": sealedKey
        ], prefer: "return=minimal,resolution=merge-duplicates", onConflict: "account_email,vault_id,key_id")
    }

    /// Remove this account's grants into a vault — all of them, or all but `keeping`.
    static func deleteGrants(email: String, vaultID: String, keeping keyID: String? = nil) async throws {
        var query = [URLQueryItem(name: "account_email", value: "eq.\(email.lowercased())"),
                     URLQueryItem(name: "vault_id", value: "eq.\(vaultID)")]
        if let keyID { query.append(URLQueryItem(name: "key_id", value: "neq.\(keyID)")) }
        try await SupabaseAPI.write(method: "DELETE", path: "vault_grants", query: query)
    }

    // MARK: Counting

    /// How many contacts a vault owns.
    static func contactCount(vaultID: String) async throws -> Int {
        try await count("recruiters", [URLQueryItem(name: "vault_id", value: "eq.\(vaultID)")])
    }

    static func count(_ path: String, _ filters: [URLQueryItem], column: String = "id") async throws -> Int {
        try await SupabaseAPI.count(path, filters, column: column)
    }

    // MARK: Sealing rows in place

    /// Raw rows, `limit` at a time.
    static func rows(_ path: String, select: String, _ filters: [URLQueryItem], limit: Int) async throws -> [[String: Any]] {
        let request = SupabaseAPI.makeRequest(path: path, query: [
            URLQueryItem(name: "select", value: select),
            URLQueryItem(name: "order", value: "id"),
            URLQueryItem(name: "limit", value: String(limit))
        ] + filters)
        guard let rows = try JSONSerialization.jsonObject(with: try await SupabaseAPI.send(request)) as? [[String: Any]] else {
            throw SupabaseError.badResponse
        }
        return rows
    }

    /// Write rows back over themselves by id, in one request. Every row carries
    /// the columns the table requires, since an upsert is checked as an insert
    /// first.
    static func overwrite(_ path: String, rows: [[String: Any]], onConflict: String = "id") async throws {
        guard !rows.isEmpty else { return }
        var request = SupabaseAPI.makeRequest(path: path, query: [URLQueryItem(name: "on_conflict", value: onConflict)])
        request.httpMethod = "POST"
        request.setValue("return=minimal,resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: rows)
        try await SupabaseAPI.send(request)
    }
}
