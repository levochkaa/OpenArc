// OpenArc's own scheme on Chrome's engine: the openarc:// pages that are not Chromium's, with the HTML the app gives
// (BrowserChromeEngine.h, setSchemePageProvider:), as CEF's scheme handler serves them.
#ifndef OPENARC_SCHEME_H_
#define OPENARC_SCHEME_H_

#import <Foundation/Foundation.h>

#include <string>

#include "mojo/public/cpp/bindings/pending_remote.h"
#include "services/network/public/mojom/url_loader_factory.mojom-forward.h"

namespace openarc {

using SchemePageProvider = NSString* _Nullable (^)(NSString* _Nonnull url_string, NSInteger* _Nonnull status_code);

// The app's pages; nil until it sets them.
void SetSchemePageProvider(SchemePageProvider _Nullable provider);

// Lets pages request and commit openarc:// addresses, as CEF does for its custom schemes. Browser process, before
// any page.
void RegisterScheme();

// openarc_engine_hooks.h's g_scheme_loader_factory: the loader of openarc:// navigations, null for other schemes.
mojo::PendingRemote<network::mojom::URLLoaderFactory> CreateSchemeLoaderFactory(const std::string& scheme);

}  // namespace openarc

#endif  // OPENARC_SCHEME_H_
