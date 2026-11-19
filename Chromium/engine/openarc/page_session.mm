// Based on Cra's page protocol session (https://github.com/VictorKildahl/cra, MIT License).
#include "openarc/page_session.h"

#include <optional>
#include <string_view>

#include "base/containers/span.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/strings/sys_string_conversions.h"
#include "base/values.h"
#include "content/public/browser/devtools_agent_host.h"
#include "content/public/browser/web_contents.h"

namespace openarc {

namespace {

NSString* JSON(const base::Value& value) {
  std::string text;
  base::JSONWriter::Write(value, &text);
  return base::SysUTF8ToNSString(text);
}

}  // namespace

PageSession::PageSession(content::WebContents* contents)
    : contents_(contents), pending_([NSMutableDictionary dictionary]) {}

PageSession::~PageSession() {
  if (host_) {
    host_->DetachClient(this);
  }
  NSDictionary<NSNumber*, ProtocolReply>* pending = pending_;
  pending_ = [NSMutableDictionary dictionary];
  for (NSNumber* key in pending) {
    ProtocolReply reply = pending[key];
    dispatch_async(dispatch_get_main_queue(), ^{
      reply(nil);
    });
  }
}

void PageSession::Send(const std::string& method, const std::string& params_json, ProtocolReply reply) {
  const int id = ++next_id_;
  pending_[@(id)] = [reply copy];
  if (!host_) {
    host_ = content::DevToolsAgentHost::GetOrCreateFor(contents_);
    if (!host_ || !host_->AttachClient(this)) {
      host_ = nullptr;
      Answer(id, nil);
      return;
    }
  }
  // Method names are plain identifiers ("Domain.method"), so they need no escaping.
  std::string message = "{\"id\":" + std::to_string(id) + ",\"method\":\"" + method +
                        "\",\"params\":" + (params_json.empty() ? std::string("{}") : params_json) + "}";
  host_->DispatchProtocolMessage(this, base::as_byte_span(message));
}

void PageSession::Answer(int id, NSString* result) {
  ProtocolReply reply = pending_[@(id)];
  [pending_ removeObjectForKey:@(id)];
  if (!reply) {
    return;
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    reply(result);
  });
}

void PageSession::DispatchProtocolMessage(content::DevToolsAgentHost* host, base::span<const uint8_t> message) {
  std::string_view text(reinterpret_cast<const char*>(message.data()), message.size());
  std::optional<base::DictValue> dict = base::JSONReader::ReadDict(text, base::JSON_PARSE_RFC);
  if (!dict) {
    return;
  }
  std::optional<int> id = dict->FindInt("id");
  if (!id) {
    return;  // An event: nobody here asked for them.
  }
  const base::Value* result = dict->Find("result");
  Answer(*id, dict->Find("error") ? nil : (result ? JSON(*result) : @"{}"));
}

void PageSession::AgentHostClosed(content::DevToolsAgentHost* host) {
  host_ = nullptr;
  NSDictionary<NSNumber*, ProtocolReply>* pending = [pending_ copy];
  for (NSNumber* key in pending) {
    Answer(key.intValue, nil);
  }
}

// OpenArc drives its own pages, as CEF's client did: Chrome's trusted-client checks are for remote clients.
bool PageSession::IsTrusted() {
  return true;
}

bool PageSession::MayReadLocalFiles() {
  return true;
}

bool PageSession::AllowUnsafeOperations() {
  return true;
}

}  // namespace openarc
