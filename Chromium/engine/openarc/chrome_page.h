// OpenArc's pages on Chrome's framework: OpenArcChromePage (BrowserChromeEngine.h's BrowserChromePage) and the
// pieces of Chrome it rides on. Based on Cra's engine bridge (https://github.com/VictorKildahl/cra, MIT License).
#ifndef OPENARC_CHROME_PAGE_H_
#define OPENARC_CHROME_PAGE_H_

#import "openarc/BrowserChromeEngine.h"

namespace content {
class WebContents;
}

// Exported from the framework (framework.exports): the app looks the class up by name.
__attribute__((visibility("default")))
@interface OpenArcChromePage : NSObject <BrowserChromePage>
@property(nonatomic, weak) id<BrowserChromePageDelegate> delegate;
@property(nonatomic) BOOL inPageFullscreen;

- (instancetype)initWithURLString:(NSString*)urlString
                              profilePath:(NSString*)profilePath
                                ephemeral:(BOOL)ephemeral
                                 delegate:(id<BrowserChromePageDelegate>)delegate;
@end

namespace openarc {

// Sets Chrome's hooks to OpenArc's pages and starts the downloads watch, once Chrome's browser process is up.
void StartPages();
// Chrome is quitting: pages stop asking for new contents.
void StopPages();

void CancelDownload(NSString* downloadID);

}  // namespace openarc

#endif  // OPENARC_CHROME_PAGE_H_
