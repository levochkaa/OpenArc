#ifndef OPENARC_SHARED_BROWSER_MEDIA_MESSAGES_H_
#define OPENARC_SHARED_BROWSER_MEDIA_MESSAGES_H_

namespace shared {

// A frame's media state, from the renderer: audible, playing, paused (media
// that can resume), video, has previous track, has next track, in Picture in
// Picture, can toggle the microphone, can toggle the camera, microphone on,
// camera on (bools) and the media session title (string), in that order. CEF
// has no audible signal of its own.
inline constexpr char kMediaStateMessage[] = "OpenArc.MediaState";
inline constexpr int kMediaStateArgumentCount = 12;

// A command for a frame's media, to the renderer: "play", "pause",
// "previoustrack", "nexttrack", "togglemicrophone" or "togglecamera".
inline constexpr char kMediaControlMessage[] = "OpenArc.MediaControl";

// To the browser: the frame has a password field.
inline constexpr char kPasswordFormMessage[] = "OpenArc.PasswordForm";
// To the browser: a form with a password was sent: username and password.
inline constexpr char kPasswordSubmittedMessage[] = "OpenArc.PasswordSubmitted";
// To the renderer: put these in the frame's sign-in fields: username and password.
inline constexpr char kPasswordFillMessage[] = "OpenArc.PasswordFill";
// To the browser: the renderer's process ID, for the Task Manager.
inline constexpr char kRendererProcessMessage[] = "OpenArc.RendererProcess";
// To the browser: the frame has an address form.
inline constexpr char kAddressFormMessage[] = "OpenArc.AddressForm";
// To the browser: the frame has a card form.
inline constexpr char kCardFormMessage[] = "OpenArc.CardForm";
// To the browser: an address or card form was sent: its fields as JSON.
inline constexpr char kAddressSubmittedMessage[] = "OpenArc.AddressSubmitted";
// To the renderer: put these in the frame's address or card fields: JSON.
inline constexpr char kAddressFillMessage[] = "OpenArc.AddressFill";
// To the browser: a page with video failed to play protected media in
// Chromium: the key system's name and the reason, such as "access" or
// "license-timeout" (`BrowserProtectedMediaFailure`).
inline constexpr char kProtectedMediaFailedMessage[] = "OpenArc.ProtectedMediaFailed";
// To the browser: a FairPlay bridge request from the page's script, as JSON.
inline constexpr char kFairPlayMessage[] = "OpenArc.FairPlay";
// To the renderer: a FairPlay bridge event for the page's script, as JSON.
inline constexpr char kFairPlayEventMessage[] = "OpenArc.FairPlayEvent";
// To the browser: a protected video bridge request as JSON, then for media
// fragments their bytes.
inline constexpr char kProtectedVideoMessage[] = "OpenArc.ProtectedVideo";
// To the renderer: a protected video bridge event for the page's script, as JSON.
inline constexpr char kProtectedVideoEventMessage[] = "OpenArc.ProtectedVideoEvent";
// The app's preferences, which the renderer reads for the bridge's switch.
inline constexpr char kAppPreferencesDomain[] = "com.levochkaa.OpenArc";
inline constexpr char kProtectedMediaPreference[] = "browser.settings.playsProtectedMediaInChromium";
// Extra origins the video bridge serves, for testing it with local pages.
inline constexpr char kProtectedVideoTestOriginsPreference[] = "browser.debug.protectedVideoTestOrigins";

}  // namespace shared

#endif  // OPENARC_SHARED_BROWSER_MEDIA_MESSAGES_H_
