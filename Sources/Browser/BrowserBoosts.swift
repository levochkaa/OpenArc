// BrowserBoosts.swift

import Combine
import Foundation

// MARK: - BrowserBoost

/// A site's own CSS and JavaScript, and the page elements the user hid by
/// clicking them. It applies to its host and the host's subdomains.
struct BrowserBoost: Codable, Equatable, Identifiable {
    // MARK: Private

    private enum CodingKeys: String, CodingKey {
        case host
        case isEnabled
        case css
        case javaScript
        case zappedSelectors
    }

    // MARK: Internal

    var host: String
    var isEnabled: Bool
    var css: String
    var javaScript: String
    /// CSS selectors of hidden elements, in the order they were zapped.
    var zappedSelectors: [String]

    var id: String { host }

    /// Something to add to pages, whether or not the boost is on.
    var hasContent: Bool {
        !css.isBlank || !javaScript.isBlank || !zappedSelectors.isEmpty
    }

    /// The JavaScript pages run, empty while the boost is off.
    var activeJavaScript: String {
        isEnabled && !javaScript.isBlank ? javaScript : ""
    }

    /// The rules pages get, empty while the boost is off: the user's CSS, then
    /// one rule per zapped element, so a selector the page does not accept
    /// drops only its own rule.
    var activeStylesheet: String {
        guard isEnabled else { return "" }
        var parts = [String]()
        if !css.isBlank {
            parts.append(css)
        }
        parts += zappedSelectors.map { "\($0) { display: none !important; }" }
        return parts.joined(separator: "\n")
    }

    init(
        host: String,
        isEnabled: Bool = true,
        css: String = "",
        javaScript: String = "",
        zappedSelectors: [String] = [],
    ) {
        self.host = host
        self.isEnabled = isEnabled
        self.css = css
        self.javaScript = javaScript
        self.zappedSelectors = zappedSelectors
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.host = try container.decode(String.self, forKey: .host)
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        self.css = try container.decodeIfPresent(String.self, forKey: .css) ?? ""
        self.javaScript = try container.decodeIfPresent(String.self, forKey: .javaScript) ?? ""
        self.zappedSelectors = try container.decodeIfPresent([String].self, forKey: .zappedSelectors) ?? []
    }

    /// The site of a web address: its lowercased host without a trailing dot
    /// or a leading `www.`. Nil for other schemes.
    static func host(ofURLString urlString: String) -> String? {
        guard let components = URLComponents(string: urlString),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return components.host.flatMap(normalizedHost)
    }

    /// A host as boosts store it, or nil when nothing is left.
    static func normalizedHost(_ host: String) -> String? {
        var host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while host.hasSuffix(".") {
            host.removeLast()
        }
        if host.hasPrefix("www."), host.dropFirst(4).contains(".") {
            host.removeFirst(4)
        }
        return host.isEmpty ? nil : host
    }

    /// The host, then each parent domain: `a.b.c`, `b.c`, `c`.
    static func candidateHosts(forHost host: String) -> [String] {
        var candidates = [String]()
        var rest = Substring(host)
        while !rest.isEmpty {
            candidates.append(String(rest))
            guard let dot = rest.firstIndex(of: ".") else { break }
            rest = rest[rest.index(after: dot)...]
        }
        return candidates
    }
}

// MARK: - [BrowserBoost] + matching

extension [BrowserBoost] {
    func boost(forHost host: String) -> BrowserBoost? {
        first { $0.host == host }
    }

    /// The boost of the closest domain that has one, on or off.
    func matchingBoost(forURLString urlString: String) -> BrowserBoost? {
        guard let host = BrowserBoost.host(ofURLString: urlString) else { return nil }
        for candidate in BrowserBoost.candidateHosts(forHost: host) {
            if let boost = boost(forHost: candidate) {
                return boost
            }
        }
        return nil
    }

    /// The boost a page applies: the closest domain's boost that is on and adds something.
    func applicableBoost(forURLString urlString: String) -> BrowserBoost? {
        guard let host = BrowserBoost.host(ofURLString: urlString) else { return nil }
        for candidate in BrowserBoost.candidateHosts(forHost: host) {
            if let boost = boost(forHost: candidate), boost.isEnabled, boost.hasContent {
                return boost
            }
        }
        return nil
    }

    /// The host whose boost a page edits: the closest existing one, else the page's own site.
    func editableHost(forURLString urlString: String) -> String? {
        matchingBoost(forURLString: urlString)?.host ?? BrowserBoost.host(ofURLString: urlString)
    }

    /// Changes the host's boost, creating it first. A boost left with nothing
    /// to add is removed.
    mutating func updateBoost(host: String, _ change: (inout BrowserBoost) -> Void) {
        guard let host = BrowserBoost.normalizedHost(host) else { return }
        var boost = boost(forHost: host) ?? BrowserBoost(host: host)
        change(&boost)
        boost.host = host
        boost.zappedSelectors = boost.zappedSelectors.uniqued()
        if let index = firstIndex(where: { $0.host == host }) {
            if boost.hasContent {
                self[index] = boost
            } else {
                remove(at: index)
            }
        } else if boost.hasContent {
            append(boost)
        }
    }

    mutating func removeBoost(host: String) {
        removeAll { $0.host == host }
    }
}

// MARK: - BrowserBoostRefresh

/// What an open page needs after the boosts changed.
enum BrowserBoostRefresh: Equatable {
    case none
    /// The page's stylesheet changed: this script puts the new one in place.
    case restyle(String)
    /// The page's JavaScript changed, which only a new document undoes or runs.
    case reload

    static func refresh(
        forURLString urlString: String,
        from old: [BrowserBoost],
        to new: [BrowserBoost],
    ) -> Self {
        let before = old.applicableBoost(forURLString: urlString)
        let after = new.applicableBoost(forURLString: urlString)
        guard before != after else { return .none }
        if (before?.activeJavaScript ?? "") != (after?.activeJavaScript ?? "") {
            return .reload
        }
        let stylesheet = after?.activeStylesheet ?? ""
        guard stylesheet != (before?.activeStylesheet ?? "") else { return .none }
        return .restyle(BrowserBoostScript.styleScript(stylesheet: stylesheet))
    }
}

// MARK: - BrowserBoostScript

/// The scripts that add a boost to pages. Both engines run the stylesheet and
/// the JavaScript as separate scripts, so a mistake in the user's JavaScript
/// leaves the stylesheet in place.
enum BrowserBoostScript {
    struct ZapPoll: Decodable, Equatable {
        var picked: [String]
        var done: Bool
    }

    static let styleElementID = "openarc-boost-style"

    // MARK: Zapping

    /// Starts zapping in the page: the element under the pointer is outlined,
    /// a click hides it and records its selector, Escape ends. Answers
    /// "started", or "active" when the page already zaps.
    static let zapStartScript = """
    (function () {
      if (window.__openArcZap) return 'active';
      var picked = [];
      var done = false;
      var current = null;
      var box = document.createElement('div');
      box.setAttribute('aria-hidden', 'true');
      box.style.cssText = 'position:fixed;z-index:2147483647;pointer-events:none;display:none;box-sizing:border-box;'
        + 'border:2px solid #ff453a;background:rgba(255,69,58,0.16);border-radius:4px;';
      (document.body || document.documentElement).appendChild(box);
      function stable(name) { return /^[A-Za-z_-][\\w-]*$/.test(name) && !/\\d{4,}/.test(name); }
      function part(element) {
        if (element.id && stable(element.id)) return '#' + CSS.escape(element.id);
        var text = element.tagName.toLowerCase();
        var classes = Array.prototype.filter.call(element.classList, stable).slice(0, 2);
        for (var i = 0; i < classes.length; i++) text += '.' + CSS.escape(classes[i]);
        var parent = element.parentElement;
        if (parent) {
          var same = Array.prototype.filter.call(parent.children, function (child) { return child.matches(text); });
          if (same.length > 1) {
            var tag = element.tagName.toLowerCase();
            var index = Array.prototype.filter.call(parent.children, function (child) {
              return child.tagName === element.tagName;
            }).indexOf(element) + 1;
            text = tag + ':nth-of-type(' + index + ')';
            for (var j = 0; j < classes.length; j++) text += '.' + CSS.escape(classes[j]);
          }
        }
        return text;
      }
      function selectorFor(element) {
        var parts = [];
        while (element && element.nodeType === 1 && element !== document.documentElement) {
          parts.unshift(part(element));
          var selector = parts.join(' > ');
          try { if (document.querySelectorAll(selector).length === 1) return selector; } catch (e) {}
          if (element === document.body) break;
          element = element.parentElement;
        }
        return parts.length ? parts.join(' > ') : null;
      }
      function target(event) {
        var element = event.target;
        if (!(element instanceof Element) || element === box) return null;
        if (element === document.documentElement || element === document.body) return null;
        return element;
      }
      function onMove(event) {
        current = target(event);
        if (!current) { box.style.display = 'none'; return; }
        var rect = current.getBoundingClientRect();
        box.style.display = 'block';
        box.style.left = rect.left + 'px';
        box.style.top = rect.top + 'px';
        box.style.width = rect.width + 'px';
        box.style.height = rect.height + 'px';
      }
      function swallow(event) {
        event.preventDefault();
        event.stopPropagation();
        event.stopImmediatePropagation();
      }
      function onClick(event) {
        swallow(event);
        var element = target(event);
        if (!element) return;
        var selector = selectorFor(element);
        if (selector) {
          picked.push(selector);
          element.style.setProperty('display', 'none', 'important');
        }
        current = null;
        box.style.display = 'none';
      }
      function onKey(event) {
        if (event.key === 'Escape') { swallow(event); stop(); }
      }
      var listeners = [
        ['mousemove', onMove], ['mouseover', onMove], ['click', onClick], ['keydown', onKey],
        ['mousedown', swallow], ['mouseup', swallow], ['pointerdown', swallow], ['pointerup', swallow],
        ['auxclick', swallow], ['dblclick', swallow], ['contextmenu', swallow],
      ];
      listeners.forEach(function (pair) { window.addEventListener(pair[0], pair[1], true); });
      function stop() {
        if (done) return;
        done = true;
        listeners.forEach(function (pair) { window.removeEventListener(pair[0], pair[1], true); });
        box.remove();
      }
      Object.defineProperty(window, '__openArcZap', { configurable: true, value: {
        take: function () { return JSON.stringify({ picked: picked.splice(0), done: done }); },
        stop: stop,
      } });
      return 'started';
    })()
    """

    /// The elements zapped since the last poll, and whether zapping ended.
    static let zapPollScript = """
    (function () {
      var zap = window.__openArcZap;
      if (!zap) return JSON.stringify({ picked: [], done: true });
      var answer = zap.take();
      if (JSON.parse(answer).done) delete window.__openArcZap;
      return answer;
    })()
    """

    /// Ends zapping and answers as the poll does.
    static let zapStopScript = """
    (function () {
      var zap = window.__openArcZap;
      if (!zap) return JSON.stringify({ picked: [], done: true });
      zap.stop();
      var answer = zap.take();
      delete window.__openArcZap;
      return answer;
    })()
    """

    /// The scripts a new document of the address runs, stylesheet first.
    static func documentScripts(forURLString urlString: String, in boosts: [BrowserBoost]) -> [String] {
        guard let boost = boosts.applicableBoost(forURLString: urlString) else { return [] }
        return documentScripts(for: boost)
    }

    static func documentScripts(for boost: BrowserBoost) -> [String] {
        var scripts = [String]()
        let stylesheet = boost.activeStylesheet
        if !stylesheet.isEmpty {
            scripts.append(styleScript(stylesheet: stylesheet))
        }
        let javaScript = boost.activeJavaScript
        if !javaScript.isEmpty {
            scripts.append(javaScriptScript(javaScript))
        }
        return scripts
    }

    /// Puts the stylesheet last in the document, replacing an earlier one, and
    /// moves it last again once the page is parsed, so its rules win ties. An
    /// empty stylesheet removes it.
    static func styleScript(stylesheet: String) -> String {
        """
        (function () {
          var css = \(literal(stylesheet));
          var id = \(literal(styleElementID));
          function apply() {
            var root = document.documentElement;
            var style = document.getElementById(id);
            if (!css) { if (style) style.remove(); return; }
            if (!root) { document.addEventListener('readystatechange', apply, { once: true }); return; }
            if (!style) { style = document.createElement('style'); style.id = id; }
            if (style.textContent !== css) style.textContent = css;
            if (style.parentNode !== root || style.nextSibling) root.appendChild(style);
          }
          apply();
          if (css && document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', apply, { once: true });
          }
        })();
        """
    }

    /// Runs the user's JavaScript once per document, after the page is parsed.
    static func javaScriptScript(_ javaScript: String) -> String {
        """
        (function () {
          if (window.__openArcBoostRan) return;
          window.__openArcBoostRan = true;
          function run() {
            try {
        \(javaScript)
            } catch (error) {
              console.error('Boost:', error);
            }
          }
          if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', run, { once: true });
          } else {
            run();
          }
        })();
        """
    }

    /// WebKit's user scripts: every boost's scripts, each run only where its
    /// boost is the one that applies. They run in every frame at document start.
    static func webKitUserScripts(for boosts: [BrowserBoost]) -> [String] {
        let hosts = boosts.filter { $0.isEnabled && $0.hasContent }.map(\.host)
        guard !hosts.isEmpty else { return [] }
        let hostList = literal(hosts)
        return boosts.filter { $0.isEnabled && $0.hasContent }.flatMap { boost in
            documentScripts(for: boost).map { script in
                """
                (function () {
                  var hosts = \(hostList);
                  var host = location.hostname.toLowerCase().replace(/\\.+$/, '');
                  for (;;) {
                    if (hosts.indexOf(host) >= 0) break;
                    var dot = host.indexOf('.');
                    if (dot < 0) return;
                    host = host.slice(dot + 1);
                  }
                  if (host !== \(literal(boost.host))) return;
                \(script)
                })();
                """
            }
        }
    }

    static func zapPoll(fromJSON json: String?) -> ZapPoll? {
        json.flatMap { try? JSONDecoder().decode(ZapPoll.self, from: Data($0.utf8)) }
    }

    // MARK: Private

    /// A JavaScript literal for a JSON value.
    private static func literal(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), var text = String(data: data, encoding: .utf8) else {
            return "null"
        }
        // Line and paragraph separators end lines in older JavaScript parsers.
        text = text.replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return text
    }
}

// MARK: - BrowserBoostCatalog

/// The boosts both page engines read as documents start. The application
/// controller keeps it equal to the preferences; windows follow `changes` to
/// update their open pages.
@MainActor final class BrowserBoostCatalog {
    struct Change {
        let old: [BrowserBoost]
        let new: [BrowserBoost]
    }

    static let shared = BrowserBoostCatalog()

    let changes = PassthroughSubject<Change, Never>()

    private(set) var boosts = [BrowserBoost]()

    func update(_ boosts: [BrowserBoost]) {
        guard boosts != self.boosts else { return }
        let old = self.boosts
        self.boosts = boosts
        changes.send(Change(old: old, new: boosts))
    }

    func documentScripts(forURLString urlString: String) -> [String] {
        BrowserBoostScript.documentScripts(forURLString: urlString, in: boosts)
    }
}

// MARK: - Helpers

private extension String {
    var isBlank: Bool {
        allSatisfy(\.isWhitespace)
    }
}

private extension [String] {
    func uniqued() -> [String] {
        var seen = Set<String>()
        return filter { !$0.isBlank && seen.insert($0).inserted }
    }
}
