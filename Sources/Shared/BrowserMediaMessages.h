#ifndef THEBROWSER_SHARED_BROWSER_MEDIA_MESSAGES_H_
#define THEBROWSER_SHARED_BROWSER_MEDIA_MESSAGES_H_

namespace shared {

// A frame's media state, from the renderer: audible, playing, paused (media
// that can resume), video, has previous track, has next track (bools) and
// the media session title (string), in that order. CEF has no audible
// signal of its own.
inline constexpr char kMediaStateMessage[] = "TheBrowser.MediaState";
inline constexpr int kMediaStateArgumentCount = 7;

// A command for a frame's media, to the renderer: "play", "pause",
// "previoustrack" or "nexttrack".
inline constexpr char kMediaControlMessage[] = "TheBrowser.MediaControl";

}  // namespace shared

#endif  // THEBROWSER_SHARED_BROWSER_MEDIA_MESSAGES_H_
