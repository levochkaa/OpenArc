// BrowserPasswordUpdateTests.swift

import Testing

// MARK: - BrowserPasswordUpdateTests

struct BrowserPasswordUpdateTests {
    @Test func changesThePasswordInPlace() {
        let store = DictionaryPasswordStore()
        let login = BrowserSavedLogin(origin: "https://x.com", username: "lev")
        _ = store.save("old", for: login)

        let saved = store.update(login, username: "lev", password: "new")

        #expect(saved == login)
        #expect(store.items == [login: "new"])
    }

    @Test func movesThePasswordToANewUsername() {
        let store = DictionaryPasswordStore()
        let login = BrowserSavedLogin(origin: "https://x.com", username: "lev")
        _ = store.save("secret", for: login)

        let saved = store.update(login, username: "levochka", password: "secret")

        let renamed = BrowserSavedLogin(origin: "https://x.com", username: "levochka")
        #expect(saved == renamed)
        #expect(store.items == [renamed: "secret"])
    }

    @Test func keepsBothWhenTheNewUsernameIsTaken() {
        let store = DictionaryPasswordStore()
        let first = BrowserSavedLogin(origin: "https://x.com", username: "a")
        let second = BrowserSavedLogin(origin: "https://x.com", username: "b")
        _ = store.save("one", for: first)
        _ = store.save("two", for: second)

        #expect(store.update(first, username: "b", password: "one") == nil)
        #expect(store.items == [first: "one", second: "two"])
    }

    @Test func refusesAnEmptyPassword() {
        let store = DictionaryPasswordStore()
        let login = BrowserSavedLogin(origin: "https://x.com", username: "lev")
        _ = store.save("secret", for: login)

        #expect(store.update(login, username: "lev", password: "") == nil)
        #expect(store.items == [login: "secret"])
    }
}

// MARK: - DictionaryPasswordStore

private final class DictionaryPasswordStore: BrowserPasswordStoring {
    var items = [BrowserSavedLogin: String]()

    func allLogins() -> [BrowserSavedLogin] { Array(items.keys) }
    func password(for login: BrowserSavedLogin) -> String? { items[login] }
    func save(_ password: String, for login: BrowserSavedLogin) -> Bool {
        items[login] = password
        return true
    }

    func delete(_ login: BrowserSavedLogin) { items[login] = nil }
}
