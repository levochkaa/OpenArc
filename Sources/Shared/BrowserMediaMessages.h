#ifndef OPENARC_SHARED_BROWSER_MEDIA_MESSAGES_H_
#define OPENARC_SHARED_BROWSER_MEDIA_MESSAGES_H_

namespace shared {

// A frame's media state, from the renderer: audible, playing, paused (media
// that can resume), video, has previous track, has next track (bools) and
// the media session title (string), in that order. CEF has no audible
// signal of its own.
inline constexpr char kMediaStateMessage[] = "OpenArc.MediaState";
inline constexpr int kMediaStateArgumentCount = 8;

// A command for a frame's media, to the renderer: "play", "pause",
// "previoustrack" or "nexttrack".
inline constexpr char kMediaControlMessage[] = "OpenArc.MediaControl";

}  // namespace shared

#endif  // OPENARC_SHARED_BROWSER_MEDIA_MESSAGES_H_
