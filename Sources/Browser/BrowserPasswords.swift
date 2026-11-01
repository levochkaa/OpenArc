// BrowserPasswords.swift

import Foundation
import Security

// MARK: - BrowserSavedLogin

/// A saved sign-in, without its password.
struct BrowserSavedLogin: Hashable, Identifiable {
    let origin: String
    let username: String

    var id: String { origin + "\n" + username }
    var host: String { URLComponents(string: origin)?.host ?? origin }
}

// MARK: - BrowserPasswordStoring

protocol BrowserPasswordStoring {
    func allLogins() -> [BrowserSavedLogin]
    func password(for login: BrowserSavedLogin) -> String?
    func save(_ password: String, for login: BrowserSavedLogin) -> Bool
    func delete(_ login: BrowserSavedLogin)
}

extension BrowserPasswordStoring {
    func logins(origin: String) -> [BrowserSavedLogin] {
        allLogins().filter { $0.origin == origin }
    }
}

// MARK: - BrowserKeychainPasswordStore

/// Passwords stay in the login keychain, one item per origin and username, per profile.
struct BrowserKeychainPasswordStore: BrowserPasswordStoring {
    let service: String

    init(profileID: String) {
        self.service = "com.levochkaa.OpenArc.passwords." + profileID
    }

    func allLogins() -> [BrowserSavedLogin] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]]
        else { return [] }
        return items.compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String else { return nil }
            let parts = account.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            return BrowserSavedLogin(origin: String(parts[0]), username: String(parts[1]))
        }
        .sorted { ($0.host, $0.username) < ($1.host, $1.username) }
    }

    func password(for login: BrowserSavedLogin) -> String? {
        var query = query(login)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ password: String, for login: BrowserSavedLogin) -> Bool {
        let data = Data(password.utf8)
        let status = SecItemUpdate(query(login) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess {
            return true
        }
        guard status == errSecItemNotFound else { return false }
        var item = query(login)
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "OpenArc: " + login.host
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    func delete(_ login: BrowserSavedLogin) {
        SecItemDelete(query(login) as CFDictionary)
    }

    private func query(_ login: BrowserSavedLogin) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: login.id,
        ]
    }
}

// MARK: - BrowserPasswordPrompt

enum BrowserPasswordPrompt: Equatable {
    /// After a sign-in: keep what was typed? The password stays in memory until answered.
    case save(tabID: String, login: BrowserSavedLogin, password: String, isUpdate: Bool)
    /// A page with a password field and saved sign-ins. Nothing fills until a click.
    case fill(tabID: String, frameID: String, urlString: String, logins: [BrowserSavedLogin])

    var tabID: String {
        switch self {
        case .fill(let tabID, _, _, _), .save(let tabID, _, _, _): tabID
        }
    }
}

// MARK: - BrowserChromeModel + passwords

extension BrowserChromeModel {
    /// The scheme, host and any port: what a saved password belongs to.
    static func passwordOrigin(ofURLString urlString: String) -> String? {
        guard let components = URLComponents(string: urlString),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = components.host?.lowercased(), !host.isEmpty
        else { return nil }
        return scheme + "://" + host + (components.port.map { ":\($0)" } ?? "")
    }

    /// Incognito windows and web apps neither keep nor offer passwords.
    private var offersPasswords: Bool {
        (windowMode == .normal || windowMode == .blank) && passwordStore != nil
    }

    func handlePasswordSubmitted(tabID: String, urlString: String, username: String, password: String) {
        guard offersPasswords, let store = passwordStore, !password.isEmpty,
              let origin = Self.passwordOrigin(ofURLString: urlString),
              !userPreferencesStore.passwordNeverOrigins.contains(origin)
        else { return }
        let login = BrowserSavedLogin(origin: origin, username: username)
        let exists = store.logins(origin: origin).contains(login)
        if exists, store.password(for: login) == password {
            return
        }
        passwordPrompt = .save(tabID: tabID, login: login, password: password, isUpdate: exists)
    }

    func handlePasswordFormFound(tabID: String, frameID: String, urlString: String) {
        guard offersPasswords, let store = passwordStore, passwordPrompt == nil,
              let origin = Self.passwordOrigin(ofURLString: urlString)
        else { return }
        let logins = store.logins(origin: origin)
        guard !logins.isEmpty else { return }
        passwordPrompt = .fill(tabID: tabID, frameID: frameID, urlString: urlString, logins: logins)
    }

    func isTabVisibleForPasswordPrompt(_ tabID: String) -> Bool {
        selectedTabID.map { splitPaneTabIDs(forTabID: $0).contains(tabID) || $0 == tabID } ?? false
    }

    /// A question about a closed tab, or a fill offer the tab has navigated away from, is over.
    func dropStalePasswordPrompt() {
        guard let prompt = passwordPrompt else { return }
        guard let tab = tabs.first(where: { $0.id == prompt.tabID }) else {
            passwordPrompt = nil
            return
        }
        if case .fill(_, _, let urlString, _) = prompt,
           Self.passwordOrigin(ofURLString: tab.urlString) != Self.passwordOrigin(ofURLString: urlString)
        {
            passwordPrompt = nil
        }
    }

    func answerPasswordPrompt(save: Bool) {
        if save, case .save(_, let login, let password, _) = passwordPrompt {
            _ = passwordStore?.save(password, for: login)
        }
        passwordPrompt = nil
    }

    /// Never for this site: no more save questions from it.
    func neverSavePasswordsFromPromptSite() {
        if case .save(_, let login, _, _) = passwordPrompt {
            userPreferencesStore.passwordNeverOrigins.insert(login.origin)
        }
        passwordPrompt = nil
    }

    func fillPassword(_ login: BrowserSavedLogin) {
        guard case .fill(let tabID, let frameID, let urlString, _) = passwordPrompt,
              Self.passwordOrigin(ofURLString: urlString) == login.origin,
              let password = passwordStore?.password(for: login)
        else { return }
        passwordPrompt = nil
        fillPasswordInEngine(
            username: login.username,
            password: password,
            frameID: frameID,
            origin: login.origin,
            tabID: tabID,
        )
    }
}
