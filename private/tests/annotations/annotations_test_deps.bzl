"""Test dependencies for the annotations integration test"""

load("@bazel_tools//tools/build_defs/repo:utils.bzl", "maybe")
load(
    "//:defs.bzl",
    "py_requirements_repository",
    package_annotation = "py_package_annotation",
)

_NUMPY_LIBRARY_TARGET = """\
load("@rules_cc//cc:defs.bzl", "cc_library")
load("@rules_req_compile//:defs.bzl", "py_package_annotation_target")

_INCLUDE_DIR = "site-packages/numpy/core/include"

cc_library(
    name = "headers",
    hdrs = glob(["{}/**/*.h".format(_INCLUDE_DIR)]),
    includes = [_INCLUDE_DIR],
)

py_package_annotation_target(
    name = "pkg.headers",
    target = ":headers",
)
"""

def _req_compile_test_annotations_deps_impl(ctx):
    py_requirements_repository(
        name = "req_compile_test_annotations",
        requirements_locks = {
            Label("//private/tests/annotations:requirements.linux.txt"): "@platforms//os:linux",
            Label("//private/tests/annotations:requirements.macos.txt"): "@platforms//os:macos",
            Label("//private/tests/annotations:requirements.windows.txt"): "@platforms//os:windows",
        },
        annotations = {
            "numpy": package_annotation(
                additive_build_content = _NUMPY_LIBRARY_TARGET,
                data = [":pkg.headers"],
            ),
            # Sphinx is known to have a circular dependency. The annotations here solve for that.
            "sphinxcontrib-applehelp": package_annotation(
                deps = ["-sphinx"],
            ),
            "sphinxcontrib-devhelp": package_annotation(
                deps = ["-sphinx"],
            ),
            "sphinxcontrib-htmlhelp": package_annotation(
                deps = ["-sphinx"],
            ),
            "sphinxcontrib-jsmath": package_annotation(
                deps_excludes = ["sphinx"],
            ),
            "sphinxcontrib-qthelp": package_annotation(
                deps_excludes = ["sphinx"],
            ),
            "sphinxcontrib-serializinghtml": package_annotation(
                deps_excludes = ["sphinx"],
            ),
        },
    )

req_compile_test_annotations_deps = module_extension(implementation=_req_compile_test_annotations_deps_impl)
