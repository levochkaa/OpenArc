// A page's own DevTools protocol session, as CEF's SendDevToolsMessage gave the CEF bridge: what
// -[OpenArcChromePage executeDevToolsMethod:params:completion:] uses.
// Based on Cra's page protocol session (https://github.com/VictorKildahl/cra, MIT License).
#ifndef OPENARC_PAGE_SESSION_H_
#define OPENARC_PAGE_SESSION_H_

#import <Foundation/Foundation.h>

#include <string>

#include "base/memory/raw_ptr.h"
#include "base/memory/scoped_refptr.h"
#include "content/public/browser/devtools_agent_host_client.h"

namespace content {
class DevToolsAgentHost;
class WebContents;
}  // namespace content

namespace openarc {

// The reply's "result" object as JSON, or nil when the method failed; on the main queue.
using ProtocolReply = void (^)(NSString* result);

class PageSession : public content::DevToolsAgentHostClient {
 public:
  explicit PageSession(content::WebContents* contents);
  PageSession(const PageSession&) = delete;
  PageSession& operator=(const PageSession&) = delete;
  ~PageSession() override;

  void Send(const std::string& method, const std::string& params_json, ProtocolReply reply);

  // content::DevToolsAgentHostClient:
  void DispatchProtocolMessage(content::DevToolsAgentHost* host, base::span<const uint8_t> message) override;
  void AgentHostClosed(content::DevToolsAgentHost* host) override;
  bool IsTrusted() override;
  bool MayReadLocalFiles() override;
  bool AllowUnsafeOperations() override;

 private:
  void Answer(int id, NSString* result);

  raw_ptr<content::WebContents> contents_;
  scoped_refptr<content::DevToolsAgentHost> host_;
  NSMutableDictionary<NSNumber*, ProtocolReply>* pending_;
  // Clear of the ids Chromium's own clients use.
  int next_id_ = 100000;
};

}  // namespace openarc

#endif  // OPENARC_PAGE_SESSION_H_
