// Copyright 2024 The Chromium Embedded Framework Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "cef/libcef/browser/chrome/extensions/chrome_extension_util.h"

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <map>
#include <memory>
#include <set>
#include <string>
#include <tuple>
#include <utility>
#include <vector>

#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/scoped_refptr.h"
#include "base/no_destructor.h"
#include "base/values.h"
#include "cef/libcef/browser/browser_info_manager.h"
#include "cef/libcef/browser/browser_host_base.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/extensions/api/tabs/tabs_constants.h"
#include "chrome/browser/extensions/extension_action_runner.h"
#include "chrome/browser/extensions/extension_tab_util.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "chrome/browser/translate/chrome_translate_client.h"
#include "chrome/common/extensions/api/tabs.h"
#include "components/language_detection/core/constants.h"
#include "components/sessions/content/session_tab_helper.h"
#include "components/sessions/core/session_id.h"
#include "components/translate/core/browser/language_state.h"
#include "components/translate/core/browser/translate_manager.h"
#include "components/translate/core/browser/translate_metrics_logger.h"
#include "content/public/browser/page_navigator.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_process_host.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_delegate.h"
#include "content/public/browser/web_contents_observer.h"
#include "third_party/blink/public/mojom/favicon/favicon_url.mojom.h"
#include "extensions/browser/disable_reason.h"
#include "extensions/browser/event_router.h"
#include "extensions/browser/extension_action.h"
#include "extensions/browser/extension_action_manager.h"
#include "extensions/browser/extension_registrar.h"
#include "extensions/browser/extension_registry.h"
#include "extensions/browser/uninstall_reason.h"
#include "extensions/common/event_args.h"
#include "extensions/common/extension.h"
#include "extensions/common/icons/extension_icon_set.h"
#include "extensions/common/manifest.h"
#include "extensions/common/manifest_handlers/icons_handler.h"
#include "ui/base/page_transition_types.h"
#include "url/gurl.h"

namespace {

char* CopyCString(const std::string& value) {
  char* result = static_cast<char*>(std::malloc(value.size() + 1));
  if (!result) {
    return nullptr;
  }

  std::memcpy(result, value.c_str(), value.size() + 1);
  return result;
}

Profile* OpenArcProfileForPath(const char* profile_path) {
  if (!profile_path || !g_browser_process ||
      !g_browser_process->profile_manager()) {
    return nullptr;
  }

  const auto path = base::FilePath::FromUTF8Unsafe(profile_path);
  ProfileManager* profile_manager = g_browser_process->profile_manager();
  if (auto* profile = profile_manager->GetProfileByPath(path)) {
    return profile;
  }

  return profile_manager->GetProfile(path);
}

bool IsUserVisibleExtension(const extensions::Extension* extension) {
  return extension && extension->manifest() &&
         !extensions::Manifest::IsComponentLocation(extension->location()) &&
         !extension->was_installed_by_default() &&
         !extension->was_installed_by_oem();
}

bool ProfileMatches(Profile* browser_profile, Profile* target_profile) {
  if (!browser_profile || !target_profile) {
    return false;
  }
  return browser_profile == target_profile ||
         browser_profile->GetOriginalProfile() ==
             target_profile->GetOriginalProfile();
}

bool IsUsableAlloyBrowser(CefRefPtr<CefBrowserHostBase> browser,
                          Profile* profile) {
  if (!browser || !browser->IsAlloyStyle() || browser->IsPopup()) {
    return false;
  }

  Profile* browser_profile =
      Profile::FromBrowserContext(browser->GetBrowserContext());
  return ProfileMatches(browser_profile, profile);
}

CefRefPtr<CefBrowserHostBase> GetAlloyBrowserForProfile(Profile* profile) {
  CefRefPtr<CefBrowserHostBase> focused_browser =
      CefBrowserHostBase::GetLikelyFocusedBrowser();
  if (IsUsableAlloyBrowser(focused_browser, profile)) {
    return focused_browser;
  }

  for (const auto& browser_info :
       CefBrowserInfoManager::GetInstance()->GetBrowserInfoList()) {
    CefRefPtr<CefBrowserHostBase> browser = browser_info->browser();
    if (IsUsableAlloyBrowser(browser, profile)) {
      return browser;
    }
  }

  return nullptr;
}

std::string ExtensionSidePanelURLString(
    const extensions::Extension* extension) {
  if (!extension || !extension->manifest()) {
    return std::string();
  }

  const std::string* default_path =
      extension->manifest()->FindStringPath("side_panel.default_path");
  if (!default_path || default_path->empty()) {
    return std::string();
  }

  GURL side_panel_url = extension->ResolveExtensionURL(*default_path);
  return side_panel_url.is_valid() ? side_panel_url.spec() : std::string();
}

std::string ExtensionIconPath(const extensions::Extension* extension) {
  if (!extension) {
    return std::string();
  }

  auto icon_resource = extensions::IconsInfo::GetIconResource(
      extension, 32, ExtensionIconSet::Match::kBigger);
  if (icon_resource.empty()) {
    icon_resource = extensions::IconsInfo::GetIconResource(
        extension, 32, ExtensionIconSet::Match::kSmaller);
  }
  if (icon_resource.empty()) {
    return std::string();
  }

  return extension->path().Append(icon_resource.relative_path()).AsUTF8Unsafe();
}

char* CopyActionResult(const std::string& kind, const GURL& url = GURL()) {
  base::DictValue payload;
  payload.Set("kind", kind);
  if (url.is_valid()) {
    payload.Set("urlString", url.spec());
  }

  std::string json;
  return base::JSONWriter::Write(payload, &json) ? CopyCString(json) : nullptr;
}

}  // namespace

namespace {

using OpenArcTabAction = void (*)(int browser_id, int action);
constexpr int kOpenArcTabActionActivate = 0;
constexpr int kOpenArcTabActionClose = 1;
OpenArcTabAction g_tab_action = nullptr;

struct RegisteredTab {
  int browser_id = 0;
  int index = 0;
  bool active = false;
  bool pinned = false;
};

class AlloyTabObserver;

struct RegisteredWindow {
  SessionID session_id = SessionID::InvalidValue();
  bool focused = false;
  std::vector<RegisteredTab> tabs;
};

std::map<std::string, RegisteredWindow>& RegisteredWindows() {
  static base::NoDestructor<std::map<std::string, RegisteredWindow>> windows;
  return *windows;
}

std::map<int, std::unique_ptr<AlloyTabObserver>>& TabObservers() {
  static base::NoDestructor<std::map<int, std::unique_ptr<AlloyTabObserver>>>
      observers;
  return *observers;
}

int g_last_focused_window_id = -1;

content::WebContents* ContentsForBrowserId(int browser_id) {
  CefRefPtr<CefBrowserHostBase> browser =
      CefBrowserHostBase::GetBrowserForBrowserId(browser_id);
  return browser && browser->IsAlloyStyle() ? browser->GetWebContents()
                                            : nullptr;
}

bool WillDispatchAlloyTabUpdated(
    content::WebContents* contents,
    const std::set<std::string>& changed_property_names,
    content::BrowserContext* browser_context,
    extensions::mojom::ContextType target_context,
    const extensions::Extension* extension,
    const base::DictValue* listener_filter,
    std::optional<base::ListValue>& event_args_out,
    extensions::mojom::EventFilteringInfoPtr& event_filtering_info_out,
    bool* dispatch_separate_event_out) {
  auto scrub = extensions::ExtensionTabUtil::GetScrubTabBehavior(
      extension, target_context, contents);
  base::DictValue tab_value =
      extensions::ExtensionTabUtil::CreateTabObject(contents, scrub, extension)
          .ToValue();
  base::DictValue changed_properties;
  for (const auto& property : changed_property_names) {
    if (const base::Value* value = tab_value.Find(property)) {
      changed_properties.Set(property, value->Clone());
    }
  }
  event_args_out.emplace();
  event_args_out->Append(extensions::ExtensionTabUtil::GetTabId(contents));
  event_args_out->Append(std::move(changed_properties));
  event_args_out->Append(std::move(tab_value));
  return true;
}

bool WillDispatchAlloyTabCreated(
    content::WebContents* contents,
    content::BrowserContext* browser_context,
    extensions::mojom::ContextType target_context,
    const extensions::Extension* extension,
    const base::DictValue* listener_filter,
    std::optional<base::ListValue>& event_args_out,
    extensions::mojom::EventFilteringInfoPtr& event_filtering_info_out,
    bool* dispatch_separate_event_out) {
  auto scrub = extensions::ExtensionTabUtil::GetScrubTabBehavior(
      extension, target_context, contents);
  event_args_out.emplace();
  event_args_out->Append(
      extensions::ExtensionTabUtil::CreateTabObject(contents, scrub, extension)
          .ToValue());
  return true;
}

void BroadcastTabEvent(content::BrowserContext* context,
                       extensions::events::HistogramValue histogram_value,
                       const std::string& event_name,
                       base::ListValue args) {
  auto* router = extensions::EventRouter::Get(context);
  if (!router) {
    return;
  }
  router->BroadcastEvent(std::make_unique<extensions::Event>(
      histogram_value, event_name,
      base::MakeRefCounted<extensions::EventArgs>(std::move(args)), context));
}

void DispatchTabUpdated(content::WebContents* contents,
                        std::set<std::string> changed_property_names) {
  content::BrowserContext* context = contents->GetBrowserContext();
  auto* router = extensions::EventRouter::Get(context);
  if (!router || changed_property_names.empty()) {
    return;
  }
  auto event = std::make_unique<extensions::Event>(
      extensions::events::TABS_ON_UPDATED,
      extensions::api::tabs::OnUpdated::kEventName,
      // The arguments depend on the extension's permissions; the
      // will-dispatch callback sets them.
      nullptr, context);
  event->user_gesture = extensions::EventRouter::UserGestureState::kNotEnabled;
  event->will_dispatch_callback =
      base::BindRepeating(&WillDispatchAlloyTabUpdated, contents,
                          std::move(changed_property_names));
  router->BroadcastEvent(std::move(event));
}

void DispatchTabCreated(content::WebContents* contents) {
  content::BrowserContext* context = contents->GetBrowserContext();
  auto* router = extensions::EventRouter::Get(context);
  if (!router) {
    return;
  }
  auto event = std::make_unique<extensions::Event>(
      extensions::events::TABS_ON_CREATED,
      extensions::api::tabs::OnCreated::kEventName, nullptr, context);
  event->user_gesture = extensions::EventRouter::UserGestureState::kNotEnabled;
  event->will_dispatch_callback =
      base::BindRepeating(&WillDispatchAlloyTabCreated, contents);
  router->BroadcastEvent(std::move(event));
}

void DispatchTabActivated(content::WebContents* contents, int window_id) {
  content::BrowserContext* context = contents->GetBrowserContext();
  const int tab_id = extensions::ExtensionTabUtil::GetTabId(contents);

  base::DictValue select_info;
  select_info.Set("windowId", window_id);
  base::ListValue deprecated_args;
  deprecated_args.Append(tab_id);
  deprecated_args.Append(select_info.Clone());
  BroadcastTabEvent(context, extensions::events::TABS_ON_SELECTION_CHANGED,
                    extensions::api::tabs::OnSelectionChanged::kEventName,
                    deprecated_args.Clone());
  BroadcastTabEvent(context, extensions::events::TABS_ON_ACTIVE_CHANGED,
                    extensions::api::tabs::OnActiveChanged::kEventName,
                    std::move(deprecated_args));

  select_info.Set("tabId", tab_id);
  base::ListValue args;
  args.Append(std::move(select_info));
  BroadcastTabEvent(context, extensions::events::TABS_ON_ACTIVATED,
                    extensions::api::tabs::OnActivated::kEventName,
                    std::move(args));
}

void DispatchTabRemoved(content::BrowserContext* context,
                        int tab_id,
                        int window_id,
                        bool window_closing) {
  base::ListValue args;
  args.Append(tab_id);
  base::DictValue info;
  info.Set("windowId", window_id);
  info.Set("isWindowClosing", window_closing);
  args.Append(std::move(info));
  BroadcastTabEvent(context, extensions::events::TABS_ON_REMOVED,
                    extensions::api::tabs::OnRemoved::kEventName,
                    std::move(args));
}

// Mirrors TabsEventRouter::TabEntry for a tab that has no tab strip.
class AlloyTabObserver : public content::WebContentsObserver {
 public:
  AlloyTabObserver(content::WebContents* contents, int browser_id)
      : content::WebContentsObserver(contents),
        browser_id_(browser_id),
        tab_id_(extensions::ExtensionTabUtil::GetTabId(contents)),
        context_(contents->GetBrowserContext()),
        url_(contents->GetURL()) {}

  int tab_id() const { return tab_id_; }
  int window_id() const { return window_id_; }
  void set_window_id(int window_id) { window_id_ = window_id; }
  content::BrowserContext* context() const { return context_; }

  // content::WebContentsObserver:
  void NavigationEntryCommitted(
      const content::LoadCommittedDetails& load_details) override {
    complete_waiting_on_load_ = true;
    std::set<std::string> changed = {
        extensions::tabs_constants::kStatusKey};
    AddURLIfChanged(changed);
    DispatchTabUpdated(web_contents(), std::move(changed));
  }

  void DidStopLoading() override {
    if (!complete_waiting_on_load_) {
      return;
    }
    complete_waiting_on_load_ = false;
    std::set<std::string> changed = {
        extensions::tabs_constants::kStatusKey};
    AddURLIfChanged(changed);
    DispatchTabUpdated(web_contents(), std::move(changed));
  }

  void TitleWasSet(content::NavigationEntry* entry) override {
    DispatchTabUpdated(web_contents(),
                       {extensions::tabs_constants::kTitleKey});
  }

  void DidUpdateFaviconURL(
      content::RenderFrameHost* render_frame_host,
      const std::vector<blink::mojom::FaviconURLPtr>& candidates,
      blink::mojom::FaviconUpdateReason reason) override {
    DispatchTabUpdated(web_contents(),
                       {extensions::tabs_constants::kFaviconUrlKey});
  }

  void WebContentsDestroyed() override {
    // Destroys `this`.
    const int browser_id = browser_id_;
    DispatchTabRemoved(context_, tab_id_, window_id_, false);
    for (auto& [key, window] : RegisteredWindows()) {
      std::erase_if(window.tabs, [browser_id](const RegisteredTab& tab) {
        return tab.browser_id == browser_id;
      });
    }
    TabObservers().erase(browser_id);
  }

 private:
  void AddURLIfChanged(std::set<std::string>& changed) {
    if (web_contents()->GetURL() != url_) {
      url_ = web_contents()->GetURL();
      changed.insert(extensions::tabs_constants::kUrlKey);
    }
  }

  const int browser_id_;
  const int tab_id_;
  int window_id_ = -1;
  const raw_ptr<content::BrowserContext> context_;
  GURL url_;
  bool complete_waiting_on_load_ = false;
};

bool ContextVisibleTo(content::BrowserContext* context,
                      Profile* profile,
                      bool include_incognito) {
  Profile* candidate = Profile::FromBrowserContext(context);
  return candidate == profile ||
         (include_incognito && profile->IsSameOrParent(candidate));
}

bool RunTabAction(content::WebContents* contents, int action) {
  auto browser = CefBrowserHostBase::GetBrowserForContents(contents);
  if (!browser || !g_tab_action || !cef::GetAlloyExtensionTab(contents)) {
    return false;
  }
  g_tab_action(browser->GetIdentifier(), action);
  return true;
}

}  // namespace

namespace cef {

bool GetAlloyTabById(int tab_id,
                     Profile* profile,
                     bool include_incognito,
                     content::WebContents** contents) {
  for (auto rph_iterator = content::RenderProcessHost::AllHostsIterator();
       !rph_iterator.IsAtEnd(); rph_iterator.Advance()) {
    content::RenderProcessHost* rph = rph_iterator.GetCurrentValue();

    // Ignore renderers that aren't ready.
    if (!rph->IsInitializedAndNotDead()) {
      continue;
    }
    // Ignore renderers that aren't from a valid profile. This is either the
    // same profile or the incognito profile if `include_incognito` is true.
    Profile* process_profile =
        Profile::FromBrowserContext(rph->GetBrowserContext());
    if (process_profile != profile &&
        !(include_incognito && profile->IsSameOrParent(process_profile))) {
      continue;
    }

    rph->ForEachRenderFrameHost([&contents,
                                 tab_id](content::RenderFrameHost* rfh) {
      CHECK(rfh);
      auto* web_contents = content::WebContents::FromRenderFrameHost(rfh);
      CHECK(web_contents);
      if (sessions::SessionTabHelper::IdForTab(web_contents).id() != tab_id) {
        return;
      }

      // We only consider Alloy style CefBrowserHosts in this loop. Otherwise,
      // we could end up returning a WebContents that shouldn't be exposed to
      // extensions.
      auto browser = CefBrowserHostBase::GetBrowserForContents(web_contents);
      if (!browser || !browser->IsAlloyStyle()) {
        return;
      }

      if (contents) {
        *contents = web_contents;
      }
    });

    if (contents && *contents) {
      return true;
    }
  }

  return false;
}

bool IsAlloyContents(content::WebContents* contents, bool primary_only) {
  auto browser = CefBrowserHostBase::GetBrowserForContents(contents);
  if (browser && browser->IsAlloyStyle()) {
    return !primary_only || browser->GetWebContents() == contents;
  }
  return false;
}

bool OpenURLInAlloyBrowser(Profile* profile,
                           const GURL& target_url,
                           WindowOpenDisposition disposition,
                           bool user_gesture) {
  if (!target_url.is_valid()) {
    return false;
  }

  CefRefPtr<CefBrowserHostBase> browser = GetAlloyBrowserForProfile(profile);
  if (!browser) {
    return false;
  }

  content::WebContents* web_contents = browser->GetWebContents();
  if (!web_contents || !web_contents->GetDelegate()) {
    return false;
  }

  content::OpenURLParams params(target_url, content::Referrer(), disposition,
                                ui::PAGE_TRANSITION_LINK,
                                /*is_renderer_initiated=*/false);
  params.user_gesture = user_gesture;
  web_contents->GetDelegate()->OpenURLFromTab(web_contents, params,
                                              base::NullCallback());
  return true;
}

std::vector<AlloyExtensionTab> GetAlloyExtensionTabs(Profile* profile,
                                                     bool include_incognito) {
  std::vector<AlloyExtensionTab> result;
  for (const auto& [key, window] : RegisteredWindows()) {
    for (const auto& tab : window.tabs) {
      content::WebContents* contents = ContentsForBrowserId(tab.browser_id);
      if (!contents || !ContextVisibleTo(contents->GetBrowserContext(), profile,
                                         include_incognito)) {
        continue;
      }
      result.push_back({contents, window.session_id.id(), tab.index, tab.active,
                        tab.pinned});
    }
  }
  std::sort(result.begin(), result.end(),
            [](const AlloyExtensionTab& a, const AlloyExtensionTab& b) {
              return std::tie(a.window_id, a.index) <
                     std::tie(b.window_id, b.index);
            });
  return result;
}

std::optional<AlloyExtensionTab> GetAlloyExtensionTab(
    content::WebContents* contents) {
  auto browser = CefBrowserHostBase::GetBrowserForContents(contents);
  if (!browser || browser->GetWebContents() != contents) {
    return std::nullopt;
  }
  const int browser_id = browser->GetIdentifier();
  for (const auto& [key, window] : RegisteredWindows()) {
    for (const auto& tab : window.tabs) {
      if (tab.browser_id == browser_id) {
        return AlloyExtensionTab{contents, window.session_id.id(), tab.index,
                                 tab.active, tab.pinned};
      }
    }
  }
  return std::nullopt;
}

int GetLastFocusedAlloyWindowId(Profile* profile, bool include_incognito) {
  const std::vector<AlloyExtensionTab> tabs =
      GetAlloyExtensionTabs(profile, include_incognito);
  for (const auto& tab : tabs) {
    if (tab.window_id == g_last_focused_window_id) {
      return tab.window_id;
    }
  }
  return tabs.empty() ? -1 : tabs.front().window_id;
}

bool IsAlloyWindowFocused(int window_id) {
  for (const auto& [key, window] : RegisteredWindows()) {
    if (window.session_id.id() == window_id) {
      return window.focused;
    }
  }
  return false;
}

bool ActivateAlloyExtensionTab(content::WebContents* contents) {
  return RunTabAction(contents, kOpenArcTabActionActivate);
}

bool CloseAlloyExtensionTab(content::WebContents* contents) {
  return RunTabAction(contents, kOpenArcTabActionClose);
}

}  // namespace cef

extern "C" __attribute__((visibility("default"))) char*
OpenArcCopyInstalledExtensionsJSON(const char* profile_path) {
  Profile* profile = OpenArcProfileForPath(profile_path);
  if (!profile) {
    return nullptr;
  }

  extensions::ExtensionRegistry* registry =
      extensions::ExtensionRegistry::Get(profile);
  if (!registry) {
    return nullptr;
  }

  base::ListValue payload;
  const auto installed_extensions = registry->GenerateInstalledExtensionsSet(
      extensions::ExtensionRegistry::ENABLED |
      extensions::ExtensionRegistry::DISABLED |
      extensions::ExtensionRegistry::TERMINATED);

  for (const auto& extension : installed_extensions) {
    if (!IsUserVisibleExtension(extension.get())) {
      continue;
    }

    base::DictValue extension_payload;
    extension_payload.Set("id", extension->id());
    extension_payload.Set("name", extension->name());
    extension_payload.Set("version", extension->version().GetString());
    extension_payload.Set("isEnabled",
                          registry->enabled_extensions().Contains(
                              extension->id()));

    const auto icon_path = ExtensionIconPath(extension.get());
    if (!icon_path.empty()) {
      extension_payload.Set("iconPath", icon_path);
    }

    const auto side_panel_url = ExtensionSidePanelURLString(extension.get());
    if (!side_panel_url.empty()) {
      extension_payload.Set("sidePanelURLString", side_panel_url);
    }

    payload.Append(std::move(extension_payload));
  }

  std::string json;
  return base::JSONWriter::Write(payload, &json) ? CopyCString(json) : nullptr;
}

extern "C" __attribute__((visibility("default"))) int
OpenArcSetExtensionEnabled(const char* profile_path,
                              const char* extension_id,
                              int is_enabled) {
  if (!extension_id || extension_id[0] == '\0') {
    return 0;
  }

  Profile* profile = OpenArcProfileForPath(profile_path);
  if (!profile) {
    return 0;
  }

  extensions::ExtensionRegistry* registry =
      extensions::ExtensionRegistry::Get(profile);
  extensions::ExtensionRegistrar* registrar =
      extensions::ExtensionRegistrar::Get(profile);
  if (!registry || !registrar || !registrar->IsInitialized()) {
    return 0;
  }

  const std::string extension_id_string(extension_id);
  const extensions::Extension* extension =
      registry->GetInstalledExtension(extension_id_string);
  if (!IsUserVisibleExtension(extension)) {
    return 0;
  }

  const bool is_currently_enabled =
      registry->enabled_extensions().Contains(extension_id_string);
  if (is_currently_enabled == static_cast<bool>(is_enabled)) {
    return 1;
  }

  if (is_enabled) {
    registrar->GrantPermissionsAndEnableExtension(*extension);
  } else {
    registrar->DisableExtension(
        extension_id_string,
        {extensions::disable_reason::DISABLE_USER_ACTION});
  }

  return 1;
}

extern "C" __attribute__((visibility("default"))) char*
OpenArcRunExtensionAction(const char* profile_path,
                             const char* extension_id) {
  if (!extension_id || extension_id[0] == '\0') {
    return nullptr;
  }

  Profile* profile = OpenArcProfileForPath(profile_path);
  if (!profile) {
    return nullptr;
  }

  extensions::ExtensionRegistry* registry =
      extensions::ExtensionRegistry::Get(profile);
  if (!registry) {
    return nullptr;
  }

  const std::string extension_id_string(extension_id);
  const extensions::Extension* extension =
      registry->GetInstalledExtension(extension_id_string);
  if (!IsUserVisibleExtension(extension) ||
      !registry->enabled_extensions().Contains(extension_id_string)) {
    return nullptr;
  }

  CefRefPtr<CefBrowserHostBase> browser = GetAlloyBrowserForProfile(profile);
  if (!browser) {
    return nullptr;
  }

  content::WebContents* web_contents = browser->GetWebContents();
  if (!web_contents) {
    return nullptr;
  }

  extensions::ExtensionActionManager* action_manager =
      extensions::ExtensionActionManager::Get(profile);
  extensions::ExtensionAction* extension_action =
      action_manager ? action_manager->GetExtensionAction(*extension) : nullptr;
  if (!extension_action) {
    return CopyActionResult("handled");
  }

  const int tab_id = sessions::SessionTabHelper::IdForTab(web_contents).id();
  auto popup_url_for_tab = [&extension_action, tab_id]() -> GURL {
    if (!extension_action->GetIsVisible(tab_id) ||
        !extension_action->HasPopup(tab_id)) {
      return GURL();
    }

    return extension_action->GetPopupUrl(tab_id);
  };

  extensions::ExtensionActionRunner* action_runner =
      extensions::ExtensionActionRunner::GetForWebContents(web_contents);
  if (!action_runner) {
    GURL popup_url = popup_url_for_tab();
    return popup_url.is_valid() ? CopyActionResult("popup", popup_url)
                                : nullptr;
  }

  extensions::ExtensionAction::ShowAction action =
      action_runner->RunAction(extension, /*grant_tab_permissions=*/true);
  if (action == extensions::ExtensionAction::ShowAction::kShowPopup) {
    GURL popup_url = popup_url_for_tab();
    return popup_url.is_valid() ? CopyActionResult("popup", popup_url)
                                : nullptr;
  }
  if (action == extensions::ExtensionAction::ShowAction::kToggleSidePanel) {
    return CopyActionResult("sidePanel");
  }

  return CopyActionResult("handled");
}

extern "C" __attribute__((visibility("default"))) int
OpenArcRemoveExtension(const char* profile_path, const char* extension_id) {
  if (!extension_id || extension_id[0] == '\0') {
    return 0;
  }

  Profile* profile = OpenArcProfileForPath(profile_path);
  if (!profile) {
    return 0;
  }

  extensions::ExtensionRegistry* registry =
      extensions::ExtensionRegistry::Get(profile);
  extensions::ExtensionRegistrar* registrar =
      extensions::ExtensionRegistrar::Get(profile);
  if (!registry || !registrar || !registrar->IsInitialized()) {
    return 0;
  }

  const std::string extension_id_string(extension_id);
  const extensions::Extension* extension =
      registry->GetInstalledExtension(extension_id_string);
  if (!IsUserVisibleExtension(extension)) {
    return 0;
  }

  std::u16string error;
  return registrar->UninstallExtension(
             extension_id_string,
             extensions::UNINSTALL_REASON_USER_INITIATED,
             &error)
             ? 1
             : 0;
}

extern "C" __attribute__((visibility("default"))) void
OpenArcSetExtensionTabAction(OpenArcTabAction action) {
  g_tab_action = action;
}

// Reports one window's tabs as JSON: [{browserId, index, active, pinned}]. Tabs
// absent from every window stay invisible to extensions, which keeps preview
// pages and popups out of chrome.tabs.
extern "C" __attribute__((visibility("default"))) void
OpenArcSetExtensionTabs(const char* window_key,
                        bool focused,
                        const char* tabs_json) {
  if (!window_key || !tabs_json) {
    return;
  }
  std::vector<RegisteredTab> tabs;
  std::optional<base::Value> parsed =
      base::JSONReader::Read(tabs_json, base::JSON_PARSE_RFC);
  if (parsed && parsed->is_list()) {
    for (const base::Value& item : parsed->GetList()) {
      if (!item.is_dict()) {
        continue;
      }
      const base::DictValue& dict = item.GetDict();
      std::optional<int> browser_id = dict.FindInt("browserId");
      if (!browser_id || !ContentsForBrowserId(*browser_id)) {
        continue;
      }
      tabs.push_back({*browser_id, dict.FindInt("index").value_or(0),
                      dict.FindBool("active").value_or(false),
                      dict.FindBool("pinned").value_or(false)});
    }
  }

  auto& windows = RegisteredWindows();
  const std::string key(window_key);
  if (tabs.empty() && !windows.contains(key)) {
    return;
  }

  RegisteredWindow& window = windows[key];
  if (!window.session_id.is_valid()) {
    window.session_id = SessionID::NewUnique();
  }
  window.focused = focused;
  if (focused) {
    g_last_focused_window_id = window.session_id.id();
  }

  int old_active = 0;
  for (const auto& tab : window.tabs) {
    if (tab.active) {
      old_active = tab.browser_id;
    }
  }
  std::vector<RegisteredTab> old_tabs = std::move(window.tabs);
  window.tabs = std::move(tabs);

  std::set<int> kept;
  for (const auto& tab : window.tabs) {
    kept.insert(tab.browser_id);
  }

  // A tab moved here from another window stays registered only in this one.
  for (auto& [other_key, other] : windows) {
    if (other_key == key) {
      continue;
    }
    std::erase_if(other.tabs, [&kept](const RegisteredTab& tab) {
      return kept.count(tab.browser_id) > 0;
    });
  }

  for (const auto& tab : old_tabs) {
    if (kept.count(tab.browser_id)) {
      continue;
    }
    auto observer = TabObservers().find(tab.browser_id);
    if (observer != TabObservers().end()) {
      DispatchTabRemoved(observer->second->context(),
                         observer->second->tab_id(), window.session_id.id(),
                         false);
      TabObservers().erase(observer);
    }
  }

  for (const auto& tab : window.tabs) {
    content::WebContents* contents = ContentsForBrowserId(tab.browser_id);
    if (auto* helper =
            sessions::SessionTabHelper::FromWebContents(contents)) {
      helper->SetWindowID(window.session_id);
    }
    auto observer = TabObservers().find(tab.browser_id);
    if (observer == TabObservers().end()) {
      auto created = std::make_unique<AlloyTabObserver>(contents, tab.browser_id);
      created->set_window_id(window.session_id.id());
      TabObservers()[tab.browser_id] = std::move(created);
      DispatchTabCreated(contents);
    } else {
      observer->second->set_window_id(window.session_id.id());
    }
    if (tab.active && tab.browser_id != old_active) {
      DispatchTabActivated(contents, window.session_id.id());
    }
  }
}

// Translates a page in place with Chromium's translate agent. Returns 0 when the
// page cannot be translated, for example an internal URL, 1 when translation
// started and 2 when the page is already in `target_language`.
extern "C" __attribute__((visibility("default"))) int OpenArcTranslatePage(
    int browser_id,
    const char* target_language) {
  content::WebContents* contents = ContentsForBrowserId(browser_id);
  if (!contents || !target_language || !*target_language) {
    return 0;
  }
  auto* client = ChromeTranslateClient::FromWebContents(contents);
  if (!client || !client->IsTranslatableURL(contents->GetLastCommittedURL())) {
    return 0;
  }
  std::string source = client->GetLanguageState().source_language();
  if (source == target_language) {
    return 2;
  }
  if (source.empty()) {
    source = language_detection::kUnknownLanguageCode;
  }
  client->GetTranslateManager()->TranslatePage(
      source, target_language, /*triggered_from_menu=*/true,
      translate::TranslationType::kManualUiInitialTranslation);
  return 1;
}

extern "C" __attribute__((visibility("default"))) void
OpenArcRevertTranslation(int browser_id) {
  content::WebContents* contents = ContentsForBrowserId(browser_id);
  auto* client =
      contents ? ChromeTranslateClient::FromWebContents(contents) : nullptr;
  if (client && client->GetLanguageState().IsPageTranslated()) {
    client->GetTranslateManager()->RevertTranslation();
  }
}

// 0: not translated, 1: translating, 2: translated.
extern "C" __attribute__((visibility("default"))) int OpenArcTranslationState(
    int browser_id) {
  content::WebContents* contents = ContentsForBrowserId(browser_id);
  auto* client =
      contents ? ChromeTranslateClient::FromWebContents(contents) : nullptr;
  if (!client) {
    return 0;
  }
  const translate::LanguageState& state = client->GetLanguageState();
  if (state.IsPageTranslated()) {
    return 2;
  }
  return state.translation_pending() ? 1 : 0;
}

extern "C" __attribute__((visibility("default"))) void OpenArcFreeString(
    char* value) {
  std::free(value);
}
