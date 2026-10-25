// Copyright 2024 The Chromium Embedded Framework Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "cef/libcef/browser/chrome/extensions/chrome_extension_util.h"

#include <cstdlib>
#include <cstring>
#include <string>

#include "base/functional/callback_helpers.h"
#include "base/json/json_writer.h"
#include "base/values.h"
#include "cef/libcef/browser/browser_info_manager.h"
#include "cef/libcef/browser/browser_host_base.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/extensions/extension_action_runner.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "components/sessions/content/session_tab_helper.h"
#include "content/public/browser/page_navigator.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_process_host.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_delegate.h"
#include "extensions/browser/disable_reason.h"
#include "extensions/browser/extension_action.h"
#include "extensions/browser/extension_action_manager.h"
#include "extensions/browser/extension_registrar.h"
#include "extensions/browser/extension_registry.h"
#include "extensions/browser/uninstall_reason.h"
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

extern "C" __attribute__((visibility("default"))) void OpenArcFreeString(
    char* value) {
  std::free(value);
}
