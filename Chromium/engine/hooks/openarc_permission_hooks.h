// OpenArc's hook into Chrome's permission prompts (Chromium/engine in the OpenArc repository), apart from
// openarc_engine_hooks.h so only the prompt factory and OpenArc's layer see the permissions headers. OpenArc's
// layer sets it before ChromeMain runs; Chrome never does.
#ifndef CHROME_BROWSER_OPENARC_PERMISSION_HOOKS_H_
#define CHROME_BROWSER_OPENARC_PERMISSION_HOOKS_H_

#include <memory>

#include "components/permissions/permission_prompt.h"

namespace content {
class WebContents;
}

namespace openarc {

// The prompt for a page's permission requests, shown in OpenArc's own window, or null to leave the requests to
// Chrome's prompt (chrome/browser/ui/views/permissions/permission_prompt_factory.cc).
using PermissionPromptHook = std::unique_ptr<permissions::PermissionPrompt> (*)(
    content::WebContents* contents,
    permissions::PermissionPrompt::Delegate* delegate);
inline PermissionPromptHook g_permission_prompt = nullptr;

}  // namespace openarc

#endif  // CHROME_BROWSER_OPENARC_PERMISSION_HOOKS_H_
