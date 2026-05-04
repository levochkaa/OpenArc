def _require_path(repository_ctx, fork_root, relative_path):
    path = repository_ctx.path(fork_root + "/" + relative_path)
    if not path.exists:
        fail("Chromium fork CEF export is missing %s: %s" % (relative_path, fork_root))
    return path

def _thebrowser_chromium_fork_repository_impl(repository_ctx):
    fork_root = repository_ctx.getenv("THEBROWSER_CHROMIUM_FORK_CEF_ROOT")
    if not fork_root:
        workspace_root = repository_ctx.path(repository_ctx.attr.workspace_file).dirname
        fork_root = str(workspace_root) + "/ThirdParty/cef/export"

    root_path = repository_ctx.path(fork_root)
    if not root_path.exists:
        fail("""TheBrowser requires a Chromium fork CEF export.
Create the project-local export with ./script/chromium_source.sh package Debug,
or set THEBROWSER_CHROMIUM_FORK_CEF_ROOT=/path/to/thebrowser-chromium/cef-export.
Missing export: %s
Stock CEF downloads are intentionally disabled because full Chrome extension support is mandatory.""" % fork_root)

    _require_path(repository_ctx, fork_root, ".thebrowser-chromium-fork")

    for required_path in [
        "CREDITS.html",
        "Debug/Chromium Embedded Framework.framework",
        "include/cef_app.h",
        "libcef_dll/CMakeLists.txt",
    ]:
        _require_path(repository_ctx, fork_root, required_path)

    for linked_path in [
        "CREDITS.html",
        "Debug",
        "Release",
        "include",
        "libcef_dll",
    ]:
        path = repository_ctx.path(fork_root + "/" + linked_path)
        if path.exists:
            repository_ctx.symlink(path, linked_path)

    repository_ctx.symlink(repository_ctx.path(repository_ctx.attr.build_file), "BUILD.bazel")

thebrowser_chromium_fork_repository = repository_rule(
    implementation = _thebrowser_chromium_fork_repository_impl,
    attrs = {
        "build_file": attr.label(allow_single_file = True, mandatory = True),
        "workspace_file": attr.label(allow_single_file = True, default = "//:MODULE.bazel"),
    },
    environ = ["THEBROWSER_CHROMIUM_FORK_CEF_ROOT"],
)
