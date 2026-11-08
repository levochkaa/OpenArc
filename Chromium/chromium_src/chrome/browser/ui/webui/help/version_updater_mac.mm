// Copyright 2012 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// OpenArc: the app updates itself with Sparkle, not with Google's updater,
// whose check always fails here and showed an error on the About page. As on
// Linux, the page hides its update status unless an upgrade is waiting.

#include <memory>
#include <string>

#include "chrome/browser/ui/webui/help/version_updater.h"
#include "chrome/browser/upgrade_detector/upgrade_detector.h"

namespace {

class VersionUpdaterMac : public VersionUpdater {
 public:
  VersionUpdaterMac() = default;
  VersionUpdaterMac(const VersionUpdaterMac&) = delete;
  VersionUpdaterMac& operator=(const VersionUpdaterMac&) = delete;
  ~VersionUpdaterMac() override = default;

  // VersionUpdater implementation.
  void CheckForUpdate(StatusCallback callback, PromoteCallback) override {
    const Status status = UpgradeDetector::GetInstance()->is_upgrade_available()
                              ? NEARLY_UPDATED
                              : DISABLED;
    callback.Run(status, 0, false, false, std::string(), 0, std::u16string());
  }
  // There is no system updater to promote.
  void PromoteUpdater() override {}
};

}  // namespace

std::unique_ptr<VersionUpdater> VersionUpdater::Create(
    content::WebContents* web_contents) {
  return std::make_unique<VersionUpdaterMac>();
}
