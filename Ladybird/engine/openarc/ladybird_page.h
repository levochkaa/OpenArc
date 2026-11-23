/*
 * OpenArc's pages on Ladybird: OpenArcLadybirdPage (BrowserChromeEngine.h's BrowserChromePage), a container view
 * around Ladybird's AppKit web view (LadybirdWebView, from Ladybird's former AppKit port).
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#pragma once

#include <AK/Function.h>
#include <AK/String.h>
#include <LibWebView/Forward.h>

#import <Cocoa/Cocoa.h>

#import "Browser/LadybirdEngine/BrowserLadybirdEngine.h"

@class LadybirdWebView;

// Exported from the framework: the app reaches pages through the protocol only.
__attribute__((visibility("default")))
@interface OpenArcLadybirdPage : NSObject <BrowserChromePage>
@property(nonatomic, weak) id<BrowserChromePageDelegate> delegate;
@property(nonatomic, readonly) LadybirdWebView* webView;
@property(nonatomic, readonly) BOOL isEphemeral;

- (instancetype)initWithURLString:(NSString*)urlString
                      profilePath:(NSString*)profilePath
                        ephemeral:(BOOL)ephemeral
                         delegate:(id<BrowserChromePageDelegate>)delegate;
@end

namespace OpenArc {

// The page whose view last took focus, which Ladybird's application-wide requests (a context menu's "Open in New
// Tab", a download) report to.
OpenArcLadybirdPage* last_focused_page();
// Every page still open, for downloads with no page of their own.
NSArray<OpenArcLadybirdPage*>* open_pages();

// The app's openarc:// pages (BrowserLadybirdEngine's setSchemePageProvider:).
void set_scheme_page_provider(NSString* (^provider)(NSString* url_string, NSInteger* status_code));

// Ladybird's helpers save a page capture to a temporary file while one is pending (engine_main.mm).
void begin_screenshot_capture();
void end_screenshot_capture();

// Ladybird's DevTools server is running.
bool devtools_enabled();

// Reports a page's link or script asking for a new tab with `url`, from Ladybird's application.
void open_url_in_new_tab_from_page(OpenArcLadybirdPage* page, NSString* url_string, BOOL in_background);

}
