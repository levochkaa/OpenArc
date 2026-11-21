// Chrome's permission prompts for OpenArc's pages, shown by OpenArc in its own window as on CEF instead of
// Chrome's bubble (Chromium/engine/patches/permission-prompts.patch).
#ifndef OPENARC_PERMISSION_PROMPT_H_
#define OPENARC_PERMISSION_PROMPT_H_

#import <Foundation/Foundation.h>

#include <memory>

#include "components/permissions/permission_prompt.h"

@protocol BrowserChromePageDelegate;

namespace openarc {

// The prompt for `delegate`'s requests, which `page`'s delegate shows, or null when the delegate leaves them
// to Chrome.
std::unique_ptr<permissions::PermissionPrompt> CreatePermissionPrompt(id page,
                                                                      id<BrowserChromePageDelegate> page_delegate,
                                                                      permissions::PermissionPrompt::Delegate* delegate);

}  // namespace openarc

#endif  // OPENARC_PERMISSION_PROMPT_H_
