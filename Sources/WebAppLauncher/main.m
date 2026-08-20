#import <Foundation/Foundation.h>

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

NSString *const kHostBundlePathInfoKey = @"TheBrowserHostBundlePath";
NSString *const kWebAppBundleArgumentPrefix = @"--web-app-bundle=";

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    NSBundle *webAppBundle = NSBundle.mainBundle;
    NSString *hostBundlePath =
        [webAppBundle objectForInfoDictionaryKey:kHostBundlePathInfoKey];
    NSBundle *hostBundle = hostBundlePath.length > 0
                               ? [NSBundle bundleWithPath:hostBundlePath]
                               : nil;
    NSString *hostExecutablePath = hostBundle.executablePath;
    if (hostExecutablePath.length == 0) {
      fprintf(stderr, "TheBrowser web app launcher: missing host executable\n");
      return 1;
    }

    NSMutableArray<NSString *> *arguments =
        [NSMutableArray arrayWithObject:hostExecutablePath];
    [arguments addObject:[kWebAppBundleArgumentPrefix
                             stringByAppendingString:webAppBundle.bundlePath]];
    for (int index = 1; index < argc; index += 1) {
      NSString *argument = [NSString stringWithUTF8String:argv[index]];
      if (argument.length > 0) {
        [arguments addObject:argument];
      }
    }

    char **executionArguments =
        calloc(arguments.count + 1, sizeof(char *));
    if (executionArguments == NULL) {
      fprintf(stderr, "TheBrowser web app launcher: unable to allocate arguments\n");
      return 1;
    }

    for (NSUInteger index = 0; index < arguments.count; index += 1) {
      executionArguments[index] =
          strdup(arguments[index].fileSystemRepresentation);
    }

    execv(hostExecutablePath.fileSystemRepresentation, executionArguments);
    fprintf(stderr, "TheBrowser web app launcher: exec failed: %s\n",
            strerror(errno));
  }

  return 1;
}
