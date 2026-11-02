// Copyright 2024 The Chromium Embedded Framework Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CEF_LIBCEF_BROWSER_CHROME_EXTENSIONS_CHROME_EXTENSION_UTIL_H_
#define CEF_LIBCEF_BROWSER_CHROME_EXTENSIONS_CHROME_EXTENSION_UTIL_H_
#pragma once

#include <optional>
#include <vector>

#include "ui/base/window_open_disposition.h"
#include "url/gurl.h"

namespace content {
class WebContents;
}  // namespace content

class Profile;

namespace cef {

// Same as ExtensionTabUtil::GetTabById but searching only Alloy style
// CefBrowserHosts.
bool GetAlloyTabById(int tab_id,
                     Profile* profile,
                     bool include_incognito,
                     content::WebContents** contents);

// Returns true if |contents| is owned by an Alloy style CefBrowserHost.
// If |primary_only| is false then guest contents will also be matched.
bool IsAlloyContents(content::WebContents* contents, bool primary_only);

// Routes extension-created tabs/windows through the focused Alloy browser so
// embedders can decide whether to create a tab instead of a Chrome window.
bool OpenURLInAlloyBrowser(Profile* profile,
                           const GURL& target_url,
                           WindowOpenDisposition disposition,
                           bool user_gesture);

// A tab the embedder has reported through OpenArcSetExtensionTabs. Alloy style
// browsers have no tab strip, so the embedder owns their order and selection.
struct AlloyExtensionTab {
  content::WebContents* contents = nullptr;
  int window_id = -1;
  int index = -1;
  bool active = false;
  bool pinned = false;
};

// Reported tabs visible to `profile`, ordered by window and then by index.
std::vector<AlloyExtensionTab> GetAlloyExtensionTabs(Profile* profile,
                                                     bool include_incognito);

// The reported state of `contents`, if the embedder listed it as a tab.
std::optional<AlloyExtensionTab> GetAlloyExtensionTab(
    content::WebContents* contents);

// The window most recently reported as focused that holds a tab visible to
// `profile`, or -1.
int GetLastFocusedAlloyWindowId(Profile* profile, bool include_incognito);

// Whether the embedder currently reports `window_id` as focused.
bool IsAlloyWindowFocused(int window_id);

// Asks the embedder to select or close a tab it owns. Returns false when
// `contents` is not a reported tab or the embedder registered no handler.
bool ActivateAlloyExtensionTab(content::WebContents* contents);
bool CloseAlloyExtensionTab(content::WebContents* contents);

}  // namespace cef

#endif  // CEF_LIBCEF_BROWSER_CHROME_EXTENSIONS_CHROME_EXTENSION_UTIL_H_
