#include "Shared/BrowserProtectedMedia.h"

#include <CoreFoundation/CoreFoundation.h>

#include <cctype>

#include "Shared/BrowserMediaMessages.h"

namespace shared {

namespace {

CFPropertyListRef CopyPreference(const char* name) {
  CFStringRef key = CFStringCreateWithCString(nullptr, name, kCFStringEncodingUTF8);
  CFStringRef domain = CFStringCreateWithCString(nullptr, kAppPreferencesDomain, kCFStringEncodingUTF8);
  CFPropertyListRef value = CFPreferencesCopyAppValue(key, domain);
  CFRelease(key);
  CFRelease(domain);
  return value;
}

/// The host of an http(s) address, lowercased; empty otherwise.
std::string HostOf(const std::string& url) {
  const size_t scheme = url.find("://");
  if (scheme == std::string::npos) {
    return std::string();
  }
  const std::string prefix = url.substr(0, scheme);
  if (prefix != "https" && prefix != "http") {
    return std::string();
  }
  const size_t start = scheme + 3;
  size_t end = url.find_first_of(":/?#", start);
  std::string host = url.substr(start, end == std::string::npos ? std::string::npos : end - start);
  for (char& character : host) {
    character = static_cast<char>(tolower(static_cast<unsigned char>(character)));
  }
  return host;
}

bool HostIsOrUnder(const std::string& host, const char* domain) {
  const std::string suffix = std::string(".") + domain;
  return host == domain || (host.size() > suffix.size() && host.compare(host.size() - suffix.size(), suffix.size(), suffix) == 0);
}

}  // namespace

bool ProtectedMediaBridgeOn() {
  CFPropertyListRef value = CopyPreference(kProtectedMediaPreference);
  const bool on = value && CFGetTypeID(value) == CFBooleanGetTypeID() && CFBooleanGetValue(static_cast<CFBooleanRef>(value));
  if (value) {
    CFRelease(value);
  }
  return on;
}

bool BridgesProtectedVideo(const std::string& url) {
  for (const char* origin : {"https://www.netflix.com/", "https://www.disneyplus.com/"}) {
    if (url.rfind(origin, 0) == 0) {
      return true;
    }
  }
  CFPropertyListRef value = CopyPreference(kProtectedVideoTestOriginsPreference);
  bool found = false;
  if (value && CFGetTypeID(value) == CFArrayGetTypeID()) {
    CFArrayRef origins = static_cast<CFArrayRef>(value);
    for (CFIndex index = 0; index < CFArrayGetCount(origins) && !found; ++index) {
      CFTypeRef item = CFArrayGetValueAtIndex(origins, index);
      char buffer[512];
      if (CFGetTypeID(item) == CFStringGetTypeID() &&
          CFStringGetCString(static_cast<CFStringRef>(item), buffer, sizeof(buffer), kCFStringEncodingUTF8)) {
        const std::string origin = std::string(buffer) + "/";
        found = url.rfind(origin, 0) == 0;
      }
    }
  }
  if (value) {
    CFRelease(value);
  }
  return found;
}

bool NeedsSafariUserAgent(const std::string& url) {
  const std::string host = HostOf(url);
  return HostIsOrUnder(host, "netflix.com") || HostIsOrUnder(host, "disneyplus.com");
}

const std::string& SafariUserAgent() {
  static const std::string agent = [] {
    std::string version = "26.0";
    CFURLRef url = CFURLCreateWithFileSystemPath(nullptr, CFSTR("/Applications/Safari.app"), kCFURLPOSIXPathStyle, true);
    CFBundleRef bundle = url ? CFBundleCreate(nullptr, url) : nullptr;
    if (bundle) {
      CFTypeRef value = CFBundleGetValueForInfoDictionaryKey(bundle, CFSTR("CFBundleShortVersionString"));
      char buffer[64];
      if (value && CFGetTypeID(value) == CFStringGetTypeID() &&
          CFStringGetCString(static_cast<CFStringRef>(value), buffer, sizeof(buffer), kCFStringEncodingUTF8)) {
        version = buffer;
      }
      CFRelease(bundle);
    }
    if (url) {
      CFRelease(url);
    }
    return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/" +
           version + " Safari/605.1.15";
  }();
  return agent;
}

}  // namespace shared
