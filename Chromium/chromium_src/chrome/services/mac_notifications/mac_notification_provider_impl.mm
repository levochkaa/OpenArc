// Copyright 2021 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "chrome/services/mac_notifications/mac_notification_provider_impl.h"

#import <UserNotifications/UserNotifications.h>

#include <utility>

#include "base/check.h"
#include "base/functional/callback_helpers.h"
#import "chrome/services/mac_notifications/mac_notification_service_un.h"

namespace mac_notifications {

MacNotificationProviderImpl::MacNotificationProviderImpl() = default;

MacNotificationProviderImpl::MacNotificationProviderImpl(
    mojo::PendingReceiver<mojom::MacNotificationProvider> binding)
    : binding_(this, std::move(binding)) {}

MacNotificationProviderImpl::~MacNotificationProviderImpl() = default;

void MacNotificationProviderImpl::BindNotificationService(
    mojo::PendingReceiver<mojom::MacNotificationService> service,
    mojo::PendingRemote<mojom::MacNotificationActionHandler> handler) {
  DCHECK(!service_);

  // OpenArc: always the UNNotification API. OpenArc asks macOS for
  // notification permission through UNUserNotificationCenter, and macOS then
  // turns away a legacy NSUserNotificationCenter client of the same app, so
  // its notifications never showed.
  service_ = std::make_unique<MacNotificationServiceUN>(
      std::move(handler), base::DoNothing(),
      [UNUserNotificationCenter currentNotificationCenter]);
  auto* service_un = static_cast<MacNotificationServiceUN*>(service_.get());
  service_un->Bind(std::move(service));
  // The dispatcher starts this service with the first notification, so a site
  // has been allowed by now. macOS asks only while it has no decision for this
  // bundle: the browser, or the helper that shows alerts.
  service_un->RequestPermission(base::DoNothing());
}

}  // namespace mac_notifications
