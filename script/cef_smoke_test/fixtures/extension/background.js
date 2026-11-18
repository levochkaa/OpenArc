// Answers the content script: "smoke-tabs" with every tab chrome.tabs can see,
// "smoke-popup" with what the popup last reported.
chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message === "smoke-tabs") {
    chrome.tabs.query({}).then(
      (tabs) => sendResponse({ count: tabs.length, urls: tabs.map((tab) => tab.url || tab.pendingUrl || "") }),
      (error) => sendResponse({ error: String(error) }),
    );
    return true;
  }
  if (message === "smoke-popup") {
    chrome.storage.session.get("popup").then((stored) => sendResponse(stored.popup || null));
    return true;
  }
  if (message && message.popup) {
    chrome.storage.session.set({ popup: message.popup }).then(() => sendResponse(true));
    return true;
  }
  return false;
});
