// OpenArc's hook into Chrome's form history (Chromium/engine in the OpenArc repository): the values typed into a
// page's text fields, which Chrome offers under the field next time. OpenArc's layer sets it before ChromeMain
// runs; Chrome never does. Address and card suggestions stay as they are.
#ifndef COMPONENTS_AUTOFILL_CORE_BROWSER_OPENARC_AUTOFILL_HOOKS_H_
#define COMPONENTS_AUTOFILL_CORE_BROWSER_OPENARC_AUTOFILL_HOOKS_H_

namespace openarc {

// True while Chrome neither keeps nor suggests typed field values
// (chrome/browser/ui/autofill/chrome_autofill_client.cc, autocomplete_history_manager.cc).
inline bool g_form_history_off = false;

}  // namespace openarc

#endif  // COMPONENTS_AUTOFILL_CORE_BROWSER_OPENARC_AUTOFILL_HOOKS_H_
