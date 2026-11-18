// Shows the active tab's title and reports it to the service worker, so the
// smoke test can read it back through a page.
chrome.tabs.query({ active: true, currentWindow: true }).then(
  (tabs) => {
    const tab = tabs[0];
    const report = { title: tab ? tab.title : null, url: tab ? tab.url : null, count: tabs.length, at: Date.now() };
    document.getElementById("status").textContent =
      "Smoke popup active tab: " + (report.title || "none") + " (" + tabs.length + ")";
    chrome.runtime.sendMessage({ popup: report });
  },
  (error) => {
    document.getElementById("status").textContent = "Smoke popup error: " + error;
    chrome.runtime.sendMessage({ popup: { error: String(error), at: Date.now() } });
  },
);
