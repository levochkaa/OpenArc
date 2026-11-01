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

// To the browser: the frame has a password field.
inline constexpr char kPasswordFormMessage[] = "OpenArc.PasswordForm";
// To the browser: a form with a password was sent: username and password.
inline constexpr char kPasswordSubmittedMessage[] = "OpenArc.PasswordSubmitted";
// To the renderer: put these in the frame's sign-in fields: username and password.
inline constexpr char kPasswordFillMessage[] = "OpenArc.PasswordFill";
// To the browser: the frame has an address form.
inline constexpr char kAddressFormMessage[] = "OpenArc.AddressForm";
// To the browser: an address form was sent: its fields as JSON.
inline constexpr char kAddressSubmittedMessage[] = "OpenArc.AddressSubmitted";
// To the renderer: put these in the frame's address fields: JSON.
inline constexpr char kAddressFillMessage[] = "OpenArc.AddressFill";

}  // namespace shared

#endif  // OPENARC_SHARED_BROWSER_MEDIA_MESSAGES_H_
