// OpenArc's hooks into Chrome's password manager (Chromium/engine in the OpenArc repository), apart from
// openarc_engine_hooks.h so the password manager's own files include nothing of chrome/browser. Chrome's password
// manager still finds sign-in forms and decides when one was sent; OpenArc asks about saving and keeps the
// passwords in its own Keychain store, as it does on CEF. OpenArc's layer sets them before ChromeMain runs; Chrome
// never does.
#ifndef COMPONENTS_PASSWORD_MANAGER_CONTENT_BROWSER_OPENARC_PASSWORD_HOOKS_H_
#define COMPONENTS_PASSWORD_MANAGER_CONTENT_BROWSER_OPENARC_PASSWORD_HOOKS_H_

#include <string>

class GURL;

namespace content {
class RenderFrameHost;
class WebContents;
}  // namespace content

namespace openarc {

// A sign-in Chrome would ask to save or update: the address of the frame whose form sent it, the username and the
// password. True when the page is OpenArc's, which asks instead, and Chrome neither shows its prompt nor saves
// (chrome/browser/password_manager/chrome_password_manager_client.cc).
using PasswordSubmittedHook = bool (*)(content::WebContents* contents,
                                       const GURL& url,
                                       const std::u16string& username,
                                       const std::u16string& password);
inline PasswordSubmittedHook g_password_submitted = nullptr;

// A frame has a form with a password field (components/password_manager/content/browser/
// content_password_manager_driver.cc).
using PasswordFormFoundHook = void (*)(content::RenderFrameHost* frame);
inline PasswordFormFoundHook g_password_form_found = nullptr;

}  // namespace openarc

#endif  // COMPONENTS_PASSWORD_MANAGER_CONTENT_BROWSER_OPENARC_PASSWORD_HOOKS_H_
