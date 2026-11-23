# OpenArc's Ladybird engine: Ladybird's libraries with OpenArc's layer, as the framework "OpenArc Ladybird"
# (docs/ladybird-engine.md). Ladybird/engine/apply.sh puts this file in UI/OpenArc of a Ladybird checkout.

set(OPENARC_APPKIT_DIR "${LADYBIRD_SOURCE_DIR}/UI/AppKit")

execute_process(
    COMMAND git -C "${LADYBIRD_SOURCE_DIR}" rev-parse --short=10 HEAD
    OUTPUT_VARIABLE OPENARC_LADYBIRD_COMMIT
    OUTPUT_STRIP_TRAILING_WHITESPACE
    ERROR_QUIET
)
if (NOT OPENARC_LADYBIRD_COMMIT)
    set(OPENARC_LADYBIRD_COMMIT "unknown")
endif()

if (NOT LADYBIRD_BROWSER_VERSION)
    set(OPENARC_LADYBIRD_BROWSER_VERSION "1.0")
else()
    set(OPENARC_LADYBIRD_BROWSER_VERSION "${LADYBIRD_BROWSER_VERSION}")
endif()

add_library(openarc_ladybird SHARED
    openarc/engine_main.mm
    openarc/ladybird_page.mm
    # The web view and its pieces from Ladybird's AppKit port; its windows, tabs and menus stay out.
    ${OPENARC_APPKIT_DIR}/Application/ClipboardTypes.mm
    ${OPENARC_APPKIT_DIR}/Application/EventLoopImplementationMacOS.mm
    ${OPENARC_APPKIT_DIR}/Interface/Event.mm
    ${OPENARC_APPKIT_DIR}/Interface/LadybirdWebView.mm
    ${OPENARC_APPKIT_DIR}/Interface/LadybirdWebViewBridge.cpp
    ${OPENARC_APPKIT_DIR}/Interface/Menu.mm
    ${OPENARC_APPKIT_DIR}/Interface/Palette.mm
    ${OPENARC_APPKIT_DIR}/Interface/SelectDropdown.mm
    ${OPENARC_APPKIT_DIR}/Utilities/Conversions.mm
    ${OPENARC_APPKIT_DIR}/Utilities/DictionaryLookup.mm
    ${OPENARC_APPKIT_DIR}/Utilities/ExternalURLHandler.mm
)

target_include_directories(openarc_ladybird PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}"
    "${OPENARC_APPKIT_DIR}"
    "${CMAKE_CURRENT_BINARY_DIR}/.."
    "${LADYBIRD_SOURCE_DIR}"
    "${LADYBIRD_SOURCE_DIR}/Services"
)

target_compile_options(openarc_ladybird PRIVATE
    $<$<COMPILE_LANGUAGE:CXX>:-fobjc-arc>
    $<$<COMPILE_LANGUAGE:CXX>:-Wno-deprecated-anon-enum-enum-conversion>
)
target_compile_features(openarc_ladybird PRIVATE cxx_std_23)
target_compile_definitions(openarc_ladybird PRIVATE
    OPENARC_LADYBIRD_VERSION="${OPENARC_LADYBIRD_BROWSER_VERSION}"
    OPENARC_LADYBIRD_COMMIT="${OPENARC_LADYBIRD_COMMIT}"
)

target_link_libraries(openarc_ladybird PRIVATE
    AK LibCore LibFileSystem LibGfx LibHTTP LibIPC LibMain LibURL LibUnicode LibWakeLock LibWebView
    OpenSSL::Crypto OpenSSL::SSL
    "-framework Cocoa -framework Metal -framework QuartzCore -framework UniformTypeIdentifiers -framework ImageIO"
)

# The framework's binary: OpenArc loads it with dlopen and finds Ladybird's libraries beside it.
set_target_properties(openarc_ladybird PROPERTIES
    OUTPUT_NAME "OpenArc Ladybird"
    PREFIX ""
    SUFFIX ""
    INSTALL_NAME_DIR "@rpath/OpenArc Ladybird.framework/Versions/A"
    BUILD_WITH_INSTALL_NAME_DIR TRUE
    BUILD_RPATH "@loader_path/Libraries"
    INSTALL_RPATH "@loader_path/Libraries"
)

# The helpers the framework carries come from the same build.
add_dependencies(openarc_ladybird ladybird)
