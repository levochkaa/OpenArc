#import "Browser/SwiftBridge.h"

#import <AuthenticationServices/AuthenticationServices.h>

#import <Sparkle/Sparkle.h>

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

struct ExtensionBridgeSymbols {
  CopyInstalledExtensionsJSONFunction copy_installed_extensions_json = nullptr;
  SetExtensionEnabledFunction set_extension_enabled = nullptr;
  RunExtensionActionFunction run_extension_action = nullptr;
  RemoveExtensionFunction remove_extension = nullptr;
  FreeStringFunction free_string = nullptr;
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
  return symbols;
}

const ExtensionBridgeSymbols& GetExtensionBridgeSymbols() {
  static ExtensionBridgeSymbols symbols = LoadExtensionBridgeSymbols();
  return symbols;
}

}  // namespace

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
