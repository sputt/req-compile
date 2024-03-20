"""Bazel rules for `req_compile`"""

load(
    "//private:compiler.bzl",
    _py_reqs_compiler = "py_reqs_compiler",
    _py_reqs_solution_test = "py_reqs_solution_test",
)
load(
    "//private:reqs_repo.bzl",
    _py_multi_plat_reqs_repository = "py_multi_plat_reqs_repository",
    _py_requirements_repository = "py_requirements_repository",
)
load(
    "//private:sdist_repo.bzl",
    _sdist_repository = "sdist_repository",
)
load(
    "//private:whl_repo.bzl",
    _whl_repository = "whl_repository",
)

py_reqs_compiler = _py_reqs_compiler
py_reqs_solution_test = _py_reqs_solution_test
py_requirements_repository = _py_requirements_repository
py_multi_plat_reqs_repository = _py_multi_plat_reqs_repository
sdist_repository = _sdist_repository
whl_repository = _whl_repository
