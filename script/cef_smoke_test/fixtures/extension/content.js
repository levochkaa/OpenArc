// Puts the extension's answers into the page, where the smoke test reads them
// with `openarc eval`: data-smoke-tabs and data-smoke-popup on <html>.
function ask(message, attribute) {
  chrome.runtime.sendMessage(message).then(
    (answer) => document.documentElement.setAttribute(attribute, JSON.stringify(answer)),
    (error) => document.documentElement.setAttribute(attribute, JSON.stringify({ error: String(error) })),
  );
}
ask("smoke-tabs", "data-smoke-tabs");
document.addEventListener("smoke-tabs-refresh", () => ask("smoke-tabs", "data-smoke-tabs"));
document.addEventListener("smoke-popup-refresh", () => ask("smoke-popup", "data-smoke-popup"));
