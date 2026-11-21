// OpenArc's own scheme on Chrome's engine. Chrome registers openarc as a standard, secure, CORS-enabled scheme in
// every process (patches/openarc-scheme.patch); here the browser process loads its pages. The tab controller loads
// Chromium's own page for openarc://extensions and the like, so only OpenArc's own addresses (an Easel's or a
// note's empty page, a shared page's Add to OpenArc button) reach this loader.

#import "openarc/scheme.h"

#include <algorithm>
#include <optional>
#include <string>
#include <utility>

#include "base/byte_size.h"
#include "base/containers/span.h"
#include "base/memory/scoped_refptr.h"
#include "base/memory/self_deleting.h"
#include "base/strings/sys_string_conversions.h"
#include "content/public/browser/child_process_security_policy.h"
#include "mojo/public/cpp/bindings/pending_receiver.h"
#include "mojo/public/cpp/bindings/remote.h"
#include "mojo/public/cpp/system/data_pipe.h"
#include "net/base/net_errors.h"
#include "net/http/http_response_headers.h"
#include "net/http/http_util.h"
#include "services/network/public/cpp/resource_request.h"
#include "services/network/public/cpp/self_deleting_url_loader_factory.h"
#include "services/network/public/cpp/url_loader_completion_status.h"
#include "services/network/public/mojom/url_loader.mojom.h"
#include "services/network/public/mojom/url_response_head.mojom.h"

namespace openarc {

namespace {

constexpr char kScheme[] = "openarc";

SchemePageProvider g_page_provider = nil;

std::string StatusLine(NSInteger status_code) {
  switch (status_code) {
    case 200:
      return "HTTP/1.1 200 OK";
    case 404:
      return "HTTP/1.1 404 Not Found";
    default:
      return "HTTP/1.1 " + std::to_string(status_code);
  }
}

class SchemeLoaderFactory : public network::SelfDeletingURLLoaderFactory {
 public:
  static mojo::PendingRemote<network::mojom::URLLoaderFactory> Create() {
    mojo::PendingRemote<network::mojom::URLLoaderFactory> remote;
    base::MakeSelfDeleting<SchemeLoaderFactory>(remote.InitWithNewPipeAndPassReceiver());
    return remote;
  }

  SchemeLoaderFactory(mojo::PendingReceiver<network::mojom::URLLoaderFactory> receiver,
                      base::SelfDeletingPassKey key)
      : network::SelfDeletingURLLoaderFactory(std::move(receiver), key) {}

 private:
  ~SchemeLoaderFactory() override = default;

  // network::mojom::URLLoaderFactory:
  void CreateLoaderAndStart(mojo::PendingReceiver<network::mojom::URLLoader> loader,
                            int32_t request_id,
                            uint32_t options,
                            const network::ResourceRequest& request,
                            mojo::PendingRemote<network::mojom::URLLoaderClient> client,
                            const net::MutableNetworkTrafficAnnotationTag& traffic_annotation) override {
    mojo::Remote<network::mojom::URLLoaderClient> remote(std::move(client));
    NSInteger status_code = 200;
    NSString* html =
        g_page_provider ? g_page_provider(base::SysUTF8ToNSString(request.url.spec()), &status_code) : nil;
    // The app took the address itself: the navigation stops where it is, without an error page.
    if (!html) {
      remote->OnComplete(network::URLLoaderCompletionStatus(net::ERR_ABORTED));
      return;
    }

    const std::string body = base::SysNSStringToUTF8(html);
    auto head = network::mojom::URLResponseHead::New();
    head->headers = base::MakeRefCounted<net::HttpResponseHeaders>(net::HttpUtil::AssembleRawHeaders(
        StatusLine(status_code) + "\nContent-Type: text/html; charset=utf-8\n\n"));
    head->mime_type = "text/html";
    head->charset = "utf-8";
    head->content_length = static_cast<int64_t>(body.size());

    mojo::ScopedDataPipeProducerHandle producer;
    mojo::ScopedDataPipeConsumerHandle consumer;
    if (mojo::CreateDataPipe(static_cast<uint32_t>(std::max<size_t>(body.size(), 1)), producer, consumer) !=
            MOJO_RESULT_OK ||
        producer->WriteAllData(base::as_byte_span(body)) != MOJO_RESULT_OK) {
      remote->OnComplete(network::URLLoaderCompletionStatus(net::ERR_INSUFFICIENT_RESOURCES));
      return;
    }
    producer.reset();
    remote->OnReceiveResponse(std::move(head), std::move(consumer), std::nullopt);

    network::URLLoaderCompletionStatus status(net::OK);
    status.decoded_body_length = base::ByteSize(body.size());
    remote->OnComplete(status);
  }
};

}  // namespace

void SetSchemePageProvider(SchemePageProvider provider) {
  g_page_provider = [provider copy];
}

void RegisterScheme() {
  content::ChildProcessSecurityPolicy::GetInstance()->RegisterWebSafeScheme(kScheme);
}

mojo::PendingRemote<network::mojom::URLLoaderFactory> CreateSchemeLoaderFactory(const std::string& scheme) {
  if (scheme != kScheme) {
    return {};
  }
  return SchemeLoaderFactory::Create();
}

}  // namespace openarc
