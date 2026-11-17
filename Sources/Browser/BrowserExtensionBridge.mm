#import "Browser/SwiftBridge.h"

#import <AuthenticationServices/AuthenticationServices.h>

#import <Sparkle/Sparkle.h>

#import <WebKit/WebKit.h>

#import "OpenArc-Swift.h"

#include <dlfcn.h>

namespace {

using CopyInstalledExtensionsJSONFunction = char* (*)(const char* profile_path);
using SetExtensionEnabledFunction = int (*)(const char* profile_path,
                                            const char* extension_id,
                                            int is_enabled);
using RunExtensionActionFunction = char* (*)(const char* profile_path,
                                             const char* extension_id);
using RemoveExtensionFunction = int (*)(const char* profile_path,
                                        const char* extension_id);
using FreeStringFunction = void (*)(char* value);
using ExtensionTabActionCallback = void (*)(int browser_id, int action);
using SetExtensionTabActionFunction = void (*)(ExtensionTabActionCallback);
using SetExtensionTabsFunction = void (*)(const char* window_key,
                                          bool focused,
                                          const char* tabs_json);
using TranslatePageFunction = int (*)(int browser_id, const char* language);
using RevertTranslationFunction = void (*)(int browser_id);
using TranslationStateFunction = int (*)(int browser_id);
using SetNextDesktopMediaIDFunction = void (*)(const char* media_id);

struct ExtensionBridgeSymbols {
  CopyInstalledExtensionsJSONFunction copy_installed_extensions_json = nullptr;
  SetExtensionEnabledFunction set_extension_enabled = nullptr;
  RunExtensionActionFunction run_extension_action = nullptr;
  RemoveExtensionFunction remove_extension = nullptr;
  FreeStringFunction free_string = nullptr;
  SetExtensionTabActionFunction set_extension_tab_action = nullptr;
  SetExtensionTabsFunction set_extension_tabs = nullptr;
  TranslatePageFunction translate_page = nullptr;
  RevertTranslationFunction revert_translation = nullptr;
  TranslationStateFunction translation_state = nullptr;
  SetNextDesktopMediaIDFunction set_next_desktop_media_id = nullptr;
};

void* ChromiumEmbeddedFrameworkHandle() {
  BrowserRuntimeConfiguration* configuration =
      [BrowserRuntimeConfiguration currentConfiguration];
  if (!configuration || configuration.frameworkPath.length == 0) {
    return nullptr;
  }

  NSString* framework_binary_path = [configuration.frameworkPath
      stringByAppendingPathComponent:@"Chromium Embedded Framework"];
  const char* path = framework_binary_path.UTF8String;
  if (!path) {
    return nullptr;
  }

  void* handle = dlopen(path, RTLD_LAZY | RTLD_NOLOAD);
  if (!handle) {
    handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL);
  }
  return handle;
}

ExtensionBridgeSymbols LoadExtensionBridgeSymbols() {
  ExtensionBridgeSymbols symbols;
  void* handle = ChromiumEmbeddedFrameworkHandle();
  if (!handle) {
    return symbols;
  }

  symbols.copy_installed_extensions_json =
      reinterpret_cast<CopyInstalledExtensionsJSONFunction>(
          dlsym(handle, "OpenArcCopyInstalledExtensionsJSON"));
  symbols.set_extension_enabled =
      reinterpret_cast<SetExtensionEnabledFunction>(
          dlsym(handle, "OpenArcSetExtensionEnabled"));
  symbols.run_extension_action =
      reinterpret_cast<RunExtensionActionFunction>(
          dlsym(handle, "OpenArcRunExtensionAction"));
  symbols.remove_extension = reinterpret_cast<RemoveExtensionFunction>(
      dlsym(handle, "OpenArcRemoveExtension"));
  symbols.free_string = reinterpret_cast<FreeStringFunction>(
      dlsym(handle, "OpenArcFreeString"));
  symbols.set_extension_tab_action =
      reinterpret_cast<SetExtensionTabActionFunction>(
          dlsym(handle, "OpenArcSetExtensionTabAction"));
  symbols.set_extension_tabs = reinterpret_cast<SetExtensionTabsFunction>(
      dlsym(handle, "OpenArcSetExtensionTabs"));
  symbols.translate_page = reinterpret_cast<TranslatePageFunction>(
      dlsym(handle, "OpenArcTranslatePage"));
  symbols.revert_translation = reinterpret_cast<RevertTranslationFunction>(
      dlsym(handle, "OpenArcRevertTranslation"));
  symbols.translation_state = reinterpret_cast<TranslationStateFunction>(
      dlsym(handle, "OpenArcTranslationState"));
  symbols.set_next_desktop_media_id = reinterpret_cast<SetNextDesktopMediaIDFunction>(
      dlsym(handle, "OpenArcSetNextDesktopMediaID"));
  return symbols;
}

const ExtensionBridgeSymbols& GetExtensionBridgeSymbols() {
  static ExtensionBridgeSymbols symbols = LoadExtensionBridgeSymbols();
  return symbols;
}

void (^g_extension_tab_action_handler)(int, int) = nil;

void ForwardExtensionTabAction(int browser_id, int action) {
  if (g_extension_tab_action_handler) {
    g_extension_tab_action_handler(browser_id, action);
  }
}

}  // namespace

void BrowserSetExtensionTabs(NSString* window_key, BOOL focused,
                             NSString* tabs_json) {
  const ExtensionBridgeSymbols& symbols = GetExtensionBridgeSymbols();
  if (!symbols.set_extension_tabs || !window_key || !tabs_json) {
    return;
  }
  if (symbols.set_extension_tab_action) {
    symbols.set_extension_tab_action(&ForwardExtensionTabAction);
  }
  symbols.set_extension_tabs(window_key.UTF8String, focused,
                             tabs_json.UTF8String);
}

void BrowserSetExtensionTabActionHandler(void (^handler)(int browser_id,
                                                         int action)) {
  g_extension_tab_action_handler = [handler copy];
}

int BrowserTranslatePage(int browser_id, NSString* language) {
  const ExtensionBridgeSymbols& symbols = GetExtensionBridgeSymbols();
  return symbols.translate_page && language
             ? symbols.translate_page(browser_id, language.UTF8String)
             : 0;
}

void BrowserRevertTranslation(int browser_id) {
  const ExtensionBridgeSymbols& symbols = GetExtensionBridgeSymbols();
  if (symbols.revert_translation) {
    symbols.revert_translation(browser_id);
  }
}

void BrowserSetNextDesktopMediaID(NSString* media_id) {
  const ExtensionBridgeSymbols& symbols = GetExtensionBridgeSymbols();
  if (symbols.set_next_desktop_media_id && media_id) {
    symbols.set_next_desktop_media_id(media_id.UTF8String);
  }
}

int BrowserTranslationState(int browser_id) {
  const ExtensionBridgeSymbols& symbols = GetExtensionBridgeSymbols();
  return symbols.translation_state ? symbols.translation_state(browser_id) : 0;
}

NSString* BrowserCopyInstalledExtensionsJSON(NSString* profile_path) {
  const ExtensionBridgeSymbols& symbols = GetExtensionBridgeSymbols();
  if (!symbols.copy_installed_extensions_json || !symbols.free_string ||
      !profile_path) {
    return nil;
  }

  char* json = symbols.copy_installed_extensions_json(profile_path.UTF8String);
  if (!json) {
    return nil;
  }

  NSString* result = [NSString stringWithUTF8String:json];
  symbols.free_string(json);
  return result;
}

BOOL BrowserSetExtensionEnabled(NSString* profile_path, NSString* extension_id,
                                BOOL is_enabled) {
  const ExtensionBridgeSymbols& symbols = GetExtensionBridgeSymbols();
  if (!symbols.set_extension_enabled || !profile_path ||
      extension_id.length == 0) {
    return NO;
  }

  return symbols.set_extension_enabled(profile_path.UTF8String,
                                       extension_id.UTF8String,
                                       is_enabled ? 1 : 0)
             ? YES
             : NO;
}

NSString* BrowserRunExtensionAction(NSString* profile_path,
                                    NSString* extension_id) {
  const ExtensionBridgeSymbols& symbols = GetExtensionBridgeSymbols();
  if (!symbols.run_extension_action || !symbols.free_string || !profile_path ||
      extension_id.length == 0) {
    return nil;
  }

  char* json =
      symbols.run_extension_action(profile_path.UTF8String, extension_id.UTF8String);
  if (!json) {
    return nil;
  }

  NSString* result = [NSString stringWithUTF8String:json];
  symbols.free_string(json);
  return result;
}

BOOL BrowserRemoveExtension(NSString* profile_path, NSString* extension_id) {
  const ExtensionBridgeSymbols& symbols = GetExtensionBridgeSymbols();
  if (!symbols.remove_extension || !profile_path || extension_id.length == 0) {
    return NO;
  }

  return symbols.remove_extension(profile_path.UTF8String,
                                  extension_id.UTF8String)
             ? YES
             : NO;
}
