// BrowserMobilePageTools.js
// Reader Mode and page translation. Runs in the app's own content world,
// after Readability.js, so the page's scripts never see these functions.
(function () {
  "use strict";
  if (window.__openArcPageTools) return;
  const tools = (window.__openArcPageTools = {});
  const post = (message) => {
    try {
      window.webkit.messageHandlers.openArcPageTools.postMessage(message);
    } catch (e) {}
  };

  // MARK: Reader

  const readerCSS = `
    :root { color-scheme: light dark; --bg: #fff; --text: #000; --muted: #8e8e93; --link: #007aff;
      --button: #f2f2f7; --rule: rgba(0,0,0,0.12); }
    @media (prefers-color-scheme: dark) {
      :root { --bg: #000; --text: #fff; --muted: #8e8e93; --link: #0a84ff; --button: #1c1c1e;
        --rule: rgba(255,255,255,0.16); }
    }
    html { background: var(--bg); -webkit-text-size-adjust: var(--oa-text-size, 100%); }
    body { margin: 0; background: var(--bg); color: var(--text);
      font: 19px/1.5 -apple-system, system-ui, sans-serif; overflow-wrap: break-word; }
    .oa-reader { padding: 33px 28px 48px; max-width: 680px; margin: 0 auto; }
    .oa-normal { display: block; width: 100%; height: 43px; border: 0; border-radius: 10px;
      background: var(--button); color: var(--text); font: 17px -apple-system, system-ui, sans-serif;
      margin: 0 0 33px; -webkit-tap-highlight-color: transparent; }
    .oa-normal:active { opacity: 0.6; }
    .oa-title { font: 700 28px/1.2 -apple-system, system-ui, sans-serif; margin: 0 0 18px; }
    .oa-byline { font: 600 13px/1.3 -apple-system, system-ui, sans-serif; color: var(--muted);
      text-transform: uppercase; letter-spacing: 0.02em; margin: 0 0 20px; }
    .oa-content p, .oa-content ul, .oa-content ol, .oa-content blockquote, .oa-content pre,
    .oa-content table, .oa-content figure { margin: 0 0 18px; }
    .oa-content h1, .oa-content h2, .oa-content h3, .oa-content h4 { line-height: 1.25; margin: 28px 0 12px; }
    .oa-content h1 { font-size: 26px; } .oa-content h2 { font-size: 23px; } .oa-content h3 { font-size: 20px; }
    .oa-content a { color: var(--link); }
    .oa-content img, .oa-content video, .oa-content svg { max-width: 100%; height: auto; border-radius: 8px; }
    .oa-content figure { margin-left: 0; margin-right: 0; }
    .oa-content figcaption { font-size: 15px; color: var(--muted); margin-top: 6px; }
    .oa-content blockquote { border-left: 3px solid var(--rule); margin-left: 0; padding-left: 16px; }
    .oa-content pre { overflow-x: auto; font-size: 15px; }
    .oa-content table { display: block; overflow-x: auto; border-collapse: collapse; font-size: 16px; }
    .oa-content td, .oa-content th { border: 1px solid var(--rule); padding: 4px 8px; }
    .oa-content hr { border: 0; border-top: 1px solid var(--rule); }
  `;
  let readerSheet = null;
  let saved = null;

  tools.isReaderable = function () {
    try {
      // Lower than Readability's defaults: mobile sites split articles into
      // short paragraphs and folded sections.
      return typeof isProbablyReaderable === "function" &&
        isProbablyReaderable(document, { minContentLength: 100, minScore: 12 });
    } catch (e) {
      return false;
    }
  };

  tools.isReading = function () {
    return saved !== null;
  };

  tools.enterReader = function (normalPageTitle, host, textSize) {
    if (saved) return true;
    let article = null;
    try {
      article = new Readability(document.cloneNode(true)).parse();
    } catch (e) {}
    if (!article || !article.content) return false;
    const html = document.createElement("html");
    if (article.lang) html.setAttribute("lang", article.lang);
    if (article.dir) html.setAttribute("dir", article.dir);
    const head = document.createElement("head");
    const viewport = document.createElement("meta");
    viewport.name = "viewport";
    viewport.content = "width=device-width, initial-scale=1";
    head.appendChild(viewport);
    const title = document.createElement("title");
    title.textContent = document.title;
    head.appendChild(title);
    const body = document.createElement("body");
    const main = document.createElement("article");
    main.className = "oa-reader";
    const button = document.createElement("button");
    button.className = "oa-normal";
    button.textContent = normalPageTitle;
    button.addEventListener("click", () => {
      tools.exitReader();
      post({ reader: false });
    });
    main.appendChild(button);
    const heading = document.createElement("h1");
    heading.className = "oa-title";
    heading.textContent = article.title || document.title;
    main.appendChild(heading);
    const byline = [article.byline || article.siteName, host].filter(Boolean).join(" • ");
    if (byline) {
      const line = document.createElement("div");
      line.className = "oa-byline";
      line.textContent = byline;
      main.appendChild(line);
    }
    const content = document.createElement("div");
    content.className = "oa-content";
    content.innerHTML = article.content;
    main.appendChild(content);
    body.appendChild(main);
    html.appendChild(head);
    html.appendChild(body);
    if (!readerSheet) {
      readerSheet = new CSSStyleSheet();
      readerSheet.replaceSync(readerCSS);
    }
    saved = { root: document.documentElement, sheets: document.adoptedStyleSheets, y: window.scrollY };
    html.style.setProperty("--oa-text-size", textSize || "100%");
    document.replaceChild(html, document.documentElement);
    document.adoptedStyleSheets = [readerSheet];
    window.scrollTo(0, 0);
    return true;
  };

  tools.exitReader = function () {
    if (!saved) return;
    const state = saved;
    saved = null;
    document.replaceChild(state.root, document.documentElement);
    document.adoptedStyleSheets = state.sheets;
    window.scrollTo(0, state.y);
  };

  // MARK: Translation

  const skipped = new Set(["SCRIPT", "STYLE", "NOSCRIPT", "CODE", "PRE", "TEXTAREA", "KBD", "SAMP", "SVG", "MATH"]);
  let textNodes = [];
  let originals = [];

  function isTranslatable(node) {
    for (let element = node.parentElement; element; element = element.parentElement) {
      if (skipped.has(element.tagName.toUpperCase())) return false;
      if (element.getAttribute("translate") === "no" || element.classList.contains("notranslate")) return false;
      if (element.isContentEditable) return false;
    }
    return /\p{L}/u.test(node.nodeValue);
  }

  /// The page's text, one string per text node, without its outer whitespace.
  tools.collectText = function () {
    tools.restoreText();
    textNodes = [];
    originals = [];
    const root = document.body || document.documentElement;
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    const texts = [];
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      if (!isTranslatable(node)) continue;
      textNodes.push(node);
      originals.push(node.nodeValue);
      texts.push(node.nodeValue.trim());
    }
    return { texts: texts, lang: document.documentElement.lang || "", title: document.title };
  };

  /// Puts translations in place, keeping each node's outer whitespace.
  tools.applyText = function (start, texts) {
    for (let index = 0; index < texts.length; index++) {
      const node = textNodes[start + index];
      const original = originals[start + index];
      if (!node || original === undefined || texts[index] == null) continue;
      const lead = original.match(/^\s*/)[0];
      const trail = original.match(/\s*$/)[0];
      node.nodeValue = lead + texts[index] + trail;
    }
  };

  tools.restoreText = function () {
    for (let index = 0; index < textNodes.length; index++) {
      if (textNodes[index]) textNodes[index].nodeValue = originals[index];
    }
    textNodes = [];
    originals = [];
  };
})();
