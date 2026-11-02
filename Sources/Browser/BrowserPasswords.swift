// BrowserPasswords.swift

import Foundation
import LocalAuthentication
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

// MARK: - BrowserSavedAddress

/// Form fields by their `autocomplete` name.
struct BrowserSavedAddress: Codable, Equatable, Identifiable {
    var fields: [String: String]

    var id: String { summary + (fields["tel"] ?? "") + (fields["email"] ?? "") }

    var summary: String {
        let name = fields["name"] ?? [fields["given-name"], fields["family-name"]]
            .compactMap(\.self)
            .joined(separator: " ")
        let place = fields["street-address"] ?? fields["address-line1"] ?? fields["address-level2"] ?? ""
        return [name, place].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// The same place and person typed again is not a new address.
    func isCovered(by other: Self) -> Bool {
        fields.allSatisfy { other.fields[$0.key] == $0.value }
    }
}

// MARK: - BrowserSavedCard

/// Form fields by their `autocomplete` name. A security code is never among them.
struct BrowserSavedCard: Codable, Equatable, Identifiable {
    var fields: [String: String]

    var id: String { fields["cc-number"] ?? "" }

    /// What the prompt and Settings show: never the whole number.
    var summary: String {
        let expiry = fields["cc-exp"] ?? [fields["cc-exp-month"], fields["cc-exp-year"]]
            .compactMap(\.self)
            .joined(separator: "/")
        return ["•••• " + String((fields["cc-number"] ?? "").suffix(4)), expiry]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    /// A card comes from a form whose number passes the check every card number carries.
    init?(fields: [String: String]) {
        let number = (fields["cc-number"] ?? "").filter { !$0.isWhitespace && $0 != "-" }
        guard (12...19).contains(number.count), Self.isValidNumber(number) else { return nil }
        self.fields = fields
        self.fields["cc-number"] = number
    }

    private static func isValidNumber(_ number: String) -> Bool {
        var sum = 0
        for (index, character) in number.reversed().enumerated() {
            guard let digit = character.wholeNumberValue, character.isASCII else { return false }
            let value = index.isMultiple(of: 2) ? digit : digit * 2
            sum += value > 9 ? value - 9 : value
        }
        return sum.isMultiple(of: 10)
    }
}

// MARK: - BrowserCardStoring

protocol BrowserCardStoring {
    func cards() -> [BrowserSavedCard]
    func setCards(_ cards: [BrowserSavedCard])
}

// MARK: - BrowserKeychainCardStore

/// One keychain item holds a profile's cards, on this Mac only and only while it is unlocked.
struct BrowserKeychainCardStore: BrowserCardStoring {
    private let query: [String: Any]

    init(profileID: String) {
        self.query = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.levochkaa.OpenArc.cards." + profileID,
            kSecAttrAccount as String: "cards",
        ]
    }

    func cards() -> [BrowserSavedCard] {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return []
        }
        return (try? JSONDecoder().decode([BrowserSavedCard].self, from: data)) ?? []
    }

    func setCards(_ cards: [BrowserSavedCard]) {
        guard !cards.isEmpty else {
            SecItemDelete(query as CFDictionary)
            return
        }
        guard let data = try? JSONEncoder().encode(cards) else { return }
        if SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "OpenArc: cards"
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            SecItemAdd(item as CFDictionary, nil)
        }
    }
}

// MARK: - BrowserCardAuthentication

enum BrowserCardAuthentication {
    /// Touch ID or the Mac's password. No way to ask means no card.
    @MainActor static func ask(reason: String) async -> Bool {
        let context = LAContext()
        return await (try? context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}

// MARK: - BrowserAddressStoring

protocol BrowserAddressStoring {
    func addresses() -> [BrowserSavedAddress]
    func setAddresses(_ addresses: [BrowserSavedAddress])
}

// MARK: - BrowserKeychainAddressStore

/// One keychain item holds a profile's addresses: they are as personal as a password.
struct BrowserKeychainAddressStore: BrowserAddressStoring {
    private let query: [String: Any]

    init(profileID: String) {
        self.query = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.levochkaa.OpenArc.addresses." + profileID,
            kSecAttrAccount as String: "addresses",
        ]
    }

    func addresses() -> [BrowserSavedAddress] {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return []
        }
        return (try? JSONDecoder().decode([BrowserSavedAddress].self, from: data)) ?? []
    }

    func setAddresses(_ addresses: [BrowserSavedAddress]) {
        guard !addresses.isEmpty else {
            SecItemDelete(query as CFDictionary)
            return
        }
        guard let data = try? JSONEncoder().encode(addresses) else { return }
        if SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "OpenArc: addresses"
            SecItemAdd(item as CFDictionary, nil)
        }
    }
}

// MARK: - BrowserPasswordPrompt

enum BrowserPasswordPrompt: Equatable {
    /// After a sign-in: keep what was typed? The password stays in memory until answered.
    case save(tabID: String, login: BrowserSavedLogin, password: String, isUpdate: Bool)
    /// A page with a password field and saved sign-ins. Nothing fills until a click.
    case fill(tabID: String, frameID: String, urlString: String, logins: [BrowserSavedLogin])
    /// After an order: keep this address?
    case saveAddress(tabID: String, address: BrowserSavedAddress)
    /// A page with an address form and saved addresses. Empty fields fill after a click.
    case fillAddress(tabID: String, frameID: String, urlString: String, addresses: [BrowserSavedAddress])
    /// After a payment: keep this card? The number stays in memory until answered.
    case saveCard(tabID: String, card: BrowserSavedCard)
    /// A secure page with a card form and saved cards. A card fills after a click and the Mac's owner confirming.
    case fillCard(tabID: String, frameID: String, urlString: String, cards: [BrowserSavedCard])

    /// A page in a Peek or small window has this for its tab.
    var peekSessionID: Int? {
        tabID.hasPrefix("peek-") ? Int(tabID.dropFirst(5)) : nil
    }

    var tabID: String {
        switch self {
        case .fill(let tabID, _, _, _),
             .fillAddress(let tabID, _, _, _),
             .fillCard(let tabID, _, _, _),
             .save(let tabID, _, _, _),
             .saveAddress(let tabID, _),
             .saveCard(let tabID, _): tabID
        }
    }
}

// MARK: - BrowserChromeModel + passwords

extension BrowserChromeModel {
    /// The scheme, host and any port: what a saved password belongs to.
    nonisolated static func passwordOrigin(ofURLString urlString: String) -> String? {
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
        if let session = prompt.peekSessionID {
            if !isPeekSessionOpen(session) {
                passwordPrompt = nil
            }
            return
        }
        guard let tab = tabs.first(where: { $0.id == prompt.tabID }) else {
            passwordPrompt = nil
            return
        }
        let offeredURL: String? =
            switch prompt {
            case .fill(_, _, let urlString, _),
                 .fillAddress(_, _, let urlString, _),
                 .fillCard(_, _, let urlString, _): urlString
            case .save, .saveAddress, .saveCard: nil
            }
        if let offeredURL,
           Self.passwordOrigin(ofURLString: tab.urlString) != Self.passwordOrigin(ofURLString: offeredURL)
        {
            passwordPrompt = nil
        }
    }

    /// Addresses stay with the page the tab shows: a frame from elsewhere can't read or offer them.
    private func isAddressFrame(urlString: String, ofTab tabID: String) -> Bool {
        guard let origin = Self.passwordOrigin(ofURLString: urlString) else { return false }
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return true }
        return Self.passwordOrigin(ofURLString: tab.urlString) == origin
    }

    /// Cards go only through encryption, or to this Mac itself.
    private func isCardFrame(urlString: String, ofTab tabID: String) -> Bool {
        guard isAddressFrame(urlString: urlString, ofTab: tabID),
              let origin = Self.passwordOrigin(ofURLString: urlString),
              let url = URL(string: origin)
        else { return false }
        return url.scheme == "https" || url.host == "127.0.0.1" || url.host == "localhost"
    }

    func handleCardFormFound(tabID: String, frameID: String, urlString: String) {
        guard offersPasswords, let store = cardStore, passwordPrompt == nil,
              isCardFrame(urlString: urlString, ofTab: tabID)
        else { return }
        let cards = store.cards()
        guard !cards.isEmpty else { return }
        passwordPrompt = .fillCard(tabID: tabID, frameID: frameID, urlString: urlString, cards: cards)
    }

    private func handleCardSubmitted(tabID: String, urlString: String, fields: [String: String]) {
        guard let store = cardStore, isCardFrame(urlString: urlString, ofTab: tabID),
              let card = BrowserSavedCard(fields: fields),
              !store.cards().contains(where: { $0.id == card.id })
        else { return }
        passwordPrompt = .saveCard(tabID: tabID, card: card)
    }

    func fillCard(_ card: BrowserSavedCard) {
        guard case .fillCard(let tabID, let frameID, let urlString, _) = passwordPrompt,
              let origin = Self.passwordOrigin(ofURLString: urlString),
              let data = try? JSONEncoder().encode(card.fields),
              let json = String(data: data, encoding: .utf8)
        else { return }
        passwordPrompt = nil
        Task { @MainActor [weak self] in
            guard let self, await authenticateCardUse(BrowserStrings.cardFillReason) else { return }
            fillAddressInEngine(json: json, frameID: frameID, origin: origin, tabID: tabID)
        }
    }

    func handleAddressSubmitted(tabID: String, urlString: String, json: String) {
        guard offersPasswords,
              let data = json.data(using: .utf8),
              let fields = try? JSONDecoder().decode([String: String].self, from: data)
        else { return }
        if fields["cc-number"] != nil {
            handleCardSubmitted(tabID: tabID, urlString: urlString, fields: fields)
            return
        }
        guard let store = addressStore, isAddressFrame(urlString: urlString, ofTab: tabID) else { return }
        let address = BrowserSavedAddress(fields: fields)
        guard !store.addresses().contains(where: { address.isCovered(by: $0) }) else { return }
        passwordPrompt = .saveAddress(tabID: tabID, address: address)
    }

    func handleAddressFormFound(tabID: String, frameID: String, urlString: String) {
        guard offersPasswords, let store = addressStore, passwordPrompt == nil,
              isAddressFrame(urlString: urlString, ofTab: tabID)
        else { return }
        let addresses = store.addresses()
        guard !addresses.isEmpty else { return }
        passwordPrompt = .fillAddress(tabID: tabID, frameID: frameID, urlString: urlString, addresses: addresses)
    }

    func fillAddress(_ address: BrowserSavedAddress) {
        guard case .fillAddress(let tabID, let frameID, let urlString, _) = passwordPrompt,
              let origin = Self.passwordOrigin(ofURLString: urlString),
              let data = try? JSONEncoder().encode(address.fields),
              let json = String(data: data, encoding: .utf8)
        else { return }
        passwordPrompt = nil
        fillAddressInEngine(json: json, frameID: frameID, origin: origin, tabID: tabID)
    }

    func answerPasswordPrompt(save: Bool) {
        if save, case .save(_, let login, let password, _) = passwordPrompt {
            _ = passwordStore?.save(password, for: login)
        }
        if save, case .saveAddress(_, let address) = passwordPrompt, let store = addressStore {
            store.setAddresses(store.addresses() + [address])
        }
        if save, case .saveCard(_, let card) = passwordPrompt, let store = cardStore {
            store.setCards(store.cards() + [card])
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
