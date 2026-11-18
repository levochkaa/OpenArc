// BrowserBoosts.swift

import Combine
import Foundation

// MARK: - BrowserBoost

/// A site's own look and behavior: colors, a font, text size and case, its
/// own CSS and JavaScript, and the page elements the user hid by clicking
/// them. It applies to its host and the host's subdomains.
struct BrowserBoost: Codable, Equatable, Identifiable {
    // MARK: Private

    private enum CodingKeys: String, CodingKey {
        case host
        case isEnabled
        case css
        case javaScript
        case zappedSelectors
        case title
        case colors
        case fontFamily
        case textCase
        case textZoom
    }

    // MARK: Internal

    /// The selector that keeps icon fonts out of the font and case rules.
    static let textSelector = "*:not(i, .material-symbols-outlined, .material-icons)"

    var host: String
    var isEnabled: Bool
    var css: String
    var javaScript: String
    /// CSS selectors of hidden elements, in the order they were zapped.
    var zappedSelectors: [String]
    /// The name the user gave the Boost; nil shows the default name.
    var title: String?
    /// How the page's colors change; nil keeps the site's own.
    var colors: BrowserBoostColors?
    /// The family every text of the page takes; nil keeps the site's fonts.
    var fontFamily: String?
    var textCase: BrowserBoostTextCase?
    /// The page's size, 1 for the site's own.
    var textZoom: Double?

    var id: String { host }

    /// Something to add to pages, whether or not the boost is on.
    var hasContent: Bool {
        !css.isBlank || !javaScript.isBlank || !zappedSelectors.isEmpty || hasStyle
    }

    /// Colors, a font, a case or a size: what the editor's controls change.
    var hasStyle: Bool {
        colors?.isOriginal == false || fontFamily != nil || textCase != nil || zoom != 1
    }

    /// Nothing worth keeping: no content and no name of its own.
    var isEmpty: Bool {
        !hasContent && title == nil
    }

    /// The page's size, 1 when the site keeps its own.
    var zoom: Double {
        textZoom.map { min(max($0, BrowserBoostTextZoom.minimum), BrowserBoostTextZoom.maximum) } ?? 1
    }

    /// The JavaScript pages run, empty while the boost is off.
    var activeJavaScript: String {
        isEnabled && !javaScript.isBlank ? javaScript : ""
    }

    /// The rules every frame of the site gets, empty while the boost is off:
    /// the font and case, the user's CSS, then one rule per zapped element, so
    /// a selector the page does not accept drops only its own rule.
    var activeStylesheet: String {
        guard isEnabled else { return "" }
        var parts = [String]()
        if let fontFamily {
            parts.append("\(Self.textSelector) { font-family: \(BrowserBoostFont.cssValue(fontFamily)) !important; }")
        }
        if let textCase {
            parts.append("\(Self.textSelector) { text-transform: \(textCase.rawValue) !important; }")
        }
        if !css.isBlank {
            parts.append(css)
        }
        parts += zappedSelectors.map { "\($0) { display: none !important; }" }
        return parts.joined(separator: "\n")
    }

    /// The rules only the top document gets, empty while the boost is off:
    /// the page's size and its colors, which also reach the frames inside it.
    var activePageStylesheet: String {
        guard isEnabled else { return "" }
        var parts = [String]()
        if zoom != 1 {
            parts.append("html { zoom: \(BrowserBoostColors.number(zoom)) !important; }")
        }
        if let colors, !colors.isOriginal {
            parts += colors.rules(filterID: BrowserBoostScript.tintFilterID)
        }
        return parts.joined(separator: "\n")
    }

    /// The color map the page's tint needs, nil while the boost is off or has none.
    var activeTintFilter: BrowserBoostTintFilter? {
        guard isEnabled, let colors, let tint = colors.tint else { return nil }
        return BrowserBoostTintFilter(tint: tint, originalSaturation: colors.originalSaturation)
    }

    init(
        host: String,
        isEnabled: Bool = true,
        css: String = "",
        javaScript: String = "",
        zappedSelectors: [String] = [],
        title: String? = nil,
        colors: BrowserBoostColors? = nil,
        fontFamily: String? = nil,
        textCase: BrowserBoostTextCase? = nil,
        textZoom: Double? = nil,
    ) {
        self.host = host
        self.isEnabled = isEnabled
        self.css = css
        self.javaScript = javaScript
        self.zappedSelectors = zappedSelectors
        self.title = title
        self.colors = colors
        self.fontFamily = fontFamily
        self.textCase = textCase
        self.textZoom = textZoom
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.host = try container.decode(String.self, forKey: .host)
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        self.css = try container.decodeIfPresent(String.self, forKey: .css) ?? ""
        self.javaScript = try container.decodeIfPresent(String.self, forKey: .javaScript) ?? ""
        self.zappedSelectors = try container.decodeIfPresent([String].self, forKey: .zappedSelectors) ?? []
        // Fields a later version may shape differently are read leniently.
        self.title = try? container.decodeIfPresent(String.self, forKey: .title)
        self.colors = try? container.decodeIfPresent(BrowserBoostColors.self, forKey: .colors)
        self.fontFamily = try? container.decodeIfPresent(String.self, forKey: .fontFamily)
        self.textCase = (try? container.decodeIfPresent(String.self, forKey: .textCase))
            .flatMap(BrowserBoostTextCase.init(rawValue:))
        self.textZoom = try? container.decodeIfPresent(Double.self, forKey: .textZoom)
    }

    /// The name lists and the editor show.
    func displayTitle(defaultTitle: String) -> String {
        guard let title, !title.isBlank else { return defaultTitle }
        return title
    }

    /// Keeps the content and name, and drops every edit of the editor's controls.
    mutating func resetStyle() {
        colors = nil
        fontFamily = nil
        textCase = nil
        textZoom = nil
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
    /// to add and no name is removed.
    mutating func updateBoost(host: String, _ change: (inout BrowserBoost) -> Void) {
        guard let host = BrowserBoost.normalizedHost(host) else { return }
        var boost = boost(forHost: host) ?? BrowserBoost(host: host)
        change(&boost)
        boost.host = host
        boost.zappedSelectors = boost.zappedSelectors.uniqued()
        if boost.colors?.isOriginal == true {
            boost.colors = nil
        }
        if boost.textZoom == 1 {
            boost.textZoom = nil
        }
        if let title = boost.title, title.isBlank {
            boost.title = nil
        }
        if let index = firstIndex(where: { $0.host == host }) {
            if boost.isEmpty {
                remove(at: index)
            } else {
                self[index] = boost
            }
        } else if !boost.isEmpty {
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
        let style = BrowserBoostScript.Style(after)
        guard style != BrowserBoostScript.Style(before) else { return .none }
        return .restyle(BrowserBoostScript.styleScript(style))
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

    /// What a page's style element and SVG filter hold for a Boost.
    struct Style: Equatable {
        var stylesheet = ""
        var pageStylesheet = ""
        var tint: BrowserBoostTintFilter?

        var isEmpty: Bool {
            stylesheet.isEmpty && pageStylesheet.isEmpty && tint == nil
        }

        init(stylesheet: String = "", pageStylesheet: String = "", tint: BrowserBoostTintFilter? = nil) {
            self.stylesheet = stylesheet
            self.pageStylesheet = pageStylesheet
            self.tint = tint
        }

        init(_ boost: BrowserBoost?) {
            self.stylesheet = boost?.activeStylesheet ?? ""
            self.pageStylesheet = boost?.activePageStylesheet ?? ""
            self.tint = boost?.activeTintFilter
        }
    }

    static let styleElementID = "openarc-boost-style"
    static let filterElementID = "openarc-boost-filters"
    static let tintFilterID = "openarc-boost-tint"

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
        let style = Style(boost)
        if !style.isEmpty {
            scripts.append(styleScript(style))
        }
        let javaScript = boost.activeJavaScript
        if !javaScript.isEmpty {
            scripts.append(javaScriptScript(javaScript))
        }
        return scripts
    }

    static func styleScript(
        stylesheet: String,
        pageStylesheet: String = "",
        tint: BrowserBoostTintFilter? = nil,
    ) -> String {
        styleScript(Style(stylesheet: stylesheet, pageStylesheet: pageStylesheet, tint: tint))
    }

    /// Puts the stylesheet last in the document, replacing an earlier one, and
    /// moves it last again once the page is parsed, so its rules win ties. The
    /// top document also takes the page rules and the tint's SVG filter, which
    /// color the frames inside it too. An empty style removes both.
    static func styleScript(_ style: Style) -> String {
        """
        (function () {
          var isTop = !window.top || window.top === window;
          var css = \(literal(style.stylesheet));
          var pageCSS = \(literal(style.pageStylesheet));
          if (isTop && pageCSS) css = css ? css + '\\n' + pageCSS : pageCSS;
          var tint = isTop ? \(literal(style.tint)) : null;
          var id = \(literal(styleElementID));
          var filterID = \(literal(filterElementID));
          var tintID = \(literal(tintFilterID));
          var tintKey = tint ? JSON.stringify(tint) : '';
          function node(name, attributes, parent) {
            var element = document.createElementNS('http://www.w3.org/2000/svg', name);
            for (var key in attributes) element.setAttribute(key, attributes[key]);
            if (parent) parent.appendChild(element);
            return element;
          }
          function filterElement() {
            var svg = node('svg', {
              id: filterID, 'aria-hidden': 'true', 'data-key': tintKey, width: '0', height: '0',
              style: 'position:absolute;width:0;height:0;overflow:hidden;pointer-events:none',
            });
            var filter = node('filter', {
              id: tintID, 'color-interpolation-filters': 'sRGB', x: '0', y: '0', width: '100%', height: '100%',
            }, svg);
            node('feColorMatrix', {
              type: 'matrix', result: 'lightness',
              values: '0.2126 0.7152 0.0722 0 0 0.2126 0.7152 0.0722 0 0 0.2126 0.7152 0.0722 0 0 0 0 0 1 0',
            }, filter);
            var map = node('feComponentTransfer', { in: 'lightness', result: 'tinted' }, filter);
            node('feFuncR', { type: 'table', tableValues: tint.red.join(' ') }, map);
            node('feFuncG', { type: 'table', tableValues: tint.green.join(' ') }, map);
            node('feFuncB', { type: 'table', tableValues: tint.blue.join(' ') }, map);
            node('feComposite', {
              in: 'tinted', in2: 'SourceGraphic', operator: 'arithmetic',
              k1: '0', k2: String(1 - tint.original), k3: String(tint.original), k4: '0',
            }, filter);
            return svg;
          }
          function apply() {
            var root = document.documentElement;
            var style = document.getElementById(id);
            var svg = document.getElementById(filterID);
            if (svg && (!tint || svg.getAttribute('data-key') !== tintKey)) { svg.remove(); svg = null; }
            if (!css) { if (style) style.remove(); return; }
            if (!root) { document.addEventListener('readystatechange', apply, { once: true }); return; }
            if (tint && !svg) svg = filterElement();
            if (svg && svg.parentNode !== root) root.appendChild(svg);
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
