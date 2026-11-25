// Copyright 2016 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "chrome/browser/ui/webui/settings/settings_utils.h"

#include <optional>

#include "base/check.h"
#include "chrome/browser/extensions/extension_tab_util.h"
#include "chrome/browser/metrics/critical_user_journeys/features.h"
#include "chrome/browser/ui/browser_element_identifiers.h"
#include "chrome/browser/ui/browser_window/public/browser_window_features.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/interaction/browser_elements.h"
#include "components/tabs/public/tab_interface.h"
#include "components/url_formatter/url_fixer.h"
#include "content/public/browser/web_ui.h"
#include "ui/base/interaction/element_tracker.h"
#include "url/gurl.h"

namespace settings_utils {

namespace {

// OpenArc: settings pages also open in CEF browsers, whose tabs have no
// Chrome browser window or browser elements. Journey metrics then have
// nothing to notify, so they are skipped instead of failing a CHECK.
std::optional<ui::ElementContext> BrowserElementContext(
    content::WebUI* web_ui) {
  // May be null in unit tests using TestWebUI without a WebContents or tab.
  if (!web_ui->GetWebContents()) {
    return std::nullopt;
  }
  tabs::TabInterface* const tab =
      tabs::TabInterface::MaybeGetFromContents(web_ui->GetWebContents());
  if (!tab || !tab->GetBrowserWindowInterface()) {
    return std::nullopt;
  }
  BrowserElements* const elements =
      BrowserElements::From(tab->GetBrowserWindowInterface());
  if (!elements) {
    return std::nullopt;
  }
  return elements->GetContext();
}

}  // namespace

bool FixupAndValidateStartupPage(const std::string& url_string,
                                 GURL* fixed_url) {
  GURL url = url_formatter::FixupURL(url_string);
  bool valid = url.is_valid() && !extensions::ExtensionTabUtil::IsKillURL(url);
  if (valid && fixed_url) {
    fixed_url->Swap(&url);
  }
  return valid;
}

void MaybeNotifySettingsCustomEvent(content::WebUI* web_ui,
                                    ui::CustomElementEventType event_type) {
  CHECK(web_ui);
  if (!base::FeatureList::IsEnabled(metrics::kSettingsGlowupJourneys)) {
    return;
  }
  std::optional<ui::ElementContext> maybe_context =
      BrowserElementContext(web_ui);
  if (!maybe_context) {
    return;
  }
  ui::ElementContext context = *maybe_context;
  ui::TrackedElement* const browser_element =
      ui::ElementTracker::GetElementTracker()->GetUniqueElement(
          kBrowserViewElementId, context);
  if (!browser_element) {
    return;
  }
  ui::ElementTracker::GetFrameworkDelegate()->NotifyCustomEvent(browser_element,
                                                                event_type);
}

void MaybeNotifySettingsElementActivated(content::WebUI* web_ui,
                                         ui::ElementIdentifier element_id) {
  CHECK(web_ui);
  if (!base::FeatureList::IsEnabled(metrics::kSettingsGlowupJourneys)) {
    return;
  }
  std::optional<ui::ElementContext> maybe_context =
      BrowserElementContext(web_ui);
  if (!maybe_context) {
    return;
  }
  ui::ElementContext context = *maybe_context;
  ui::TrackedElement* tracked_element =
      ui::ElementTracker::GetElementTracker()->GetUniqueElement(element_id,
                                                                context);
  if (!tracked_element) {
    tracked_element =
        ui::ElementTracker::GetElementTracker()->GetElementInAnyContext(
            element_id);
  }
  if (tracked_element) {
    ui::ElementTracker::GetFrameworkDelegate()->NotifyElementActivated(
        tracked_element);
  }
}

}  // namespace settings_utils
