// Copyright 2018 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "ui/base/cocoa/secure_password_input.h"

#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>

#include "base/apple/scoped_cftyperef.h"
#include "base/check_op.h"

namespace {

// Used to protect from out-of-order calls to enabling/disabling functions.
int g_password_input_counter = 0;

// OpenArc: whether this process has Secure Input on. It is on while a password
// field holds the lock and the app is active. TN2150 says to turn it off when
// the app is deactivated: keys go to another app then, and Secure Input left
// on by a background app stops every other app's global shortcuts. Based on Cra (MIT License).
bool g_password_input_on = false;

// SetPasswordInputEnabled() is derived from WebKit's WebHTMLView.mm:
// https://github.com/WebKit/WebKit/blob/3f1b9104fd22eccdab649da2e331f1f1cfcbe873/Source/WebKitLegacy/mac/WebView/WebHTMLView.mm#L6762-L6777
//
// The following technote describes proper EnableSecureEventInput() usage:
// https://developer.apple.com/library/archive/technotes/tn2150/_index.html
void SetPasswordInputEnabled(bool enabled) {
  if (enabled) {
    EnableSecureEventInput();

    // Why not ScopedCFTypeRef? The property that needs to be set is the address
    // of the CFArrayRef, which is itself a typedef of a pointer to a
    // forward-declared (but not defined) struct. Doing it this way is more
    // clear as to what's going on, and the CFRelease is only four lines away,
    // as opposed to using a scoper, which would make it less clear about
    // exactly what pointer is being passed, for little benefit.
    CFArrayRef inputSources = TISCreateASCIICapableInputSourceList();
    TSMSetDocumentProperty(/*docID=*/nullptr,
                           kTSMDocumentEnabledInputSourcesPropertyTag,
                           sizeof(CFArrayRef), &inputSources);
    CFRelease(inputSources);
  } else {
    TSMRemoveDocumentProperty(/*docID=*/nullptr,
                              kTSMDocumentEnabledInputSourcesPropertyTag);

    DisableSecureEventInput();
  }
}

// Without an NSApp (unit tests), the lock alone decides, as before.
bool AppIsActive() {
  return !NSApp || NSApp.active;
}

void UpdatePasswordInput() {
  bool on = g_password_input_counter > 0 && AppIsActive();
  if (on == g_password_input_on) {
    return;
  }
  g_password_input_on = on;
  SetPasswordInputEnabled(on);
}

void ObserveAppActivation() {
  static bool observing = false;
  if (observing || !NSApp) {
    return;
  }
  observing = true;
  for (NSNotificationName name in @[
         NSApplicationDidBecomeActiveNotification,
         NSApplicationDidResignActiveNotification
       ]) {
    [NSNotificationCenter.defaultCenter
        addObserverForName:name
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification*) {
                  UpdatePasswordInput();
                }];
  }
}

}  // namespace

namespace ui {

ScopedPasswordInputEnabler::ScopedPasswordInputEnabler() {
  ObserveAppActivation();
  ++g_password_input_counter;
  UpdatePasswordInput();
}

ScopedPasswordInputEnabler::~ScopedPasswordInputEnabler() {
  --g_password_input_counter;
  DCHECK_LE(0, g_password_input_counter);
  UpdatePasswordInput();
}

// static
bool ScopedPasswordInputEnabler::IsPasswordInputEnabled() {
  return g_password_input_counter > 0;
}

}  // namespace ui
