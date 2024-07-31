"""Native requirements compilation for bzlmod."""

load("//private:reqs_repo.bzl", "parse_lockfile")
load("//private:utils.bzl", "sanitize_package_name")
load("//private:whl_repo.bzl", "whl_repository")

# Pure Python dependencies for req-compile.
DEPS = [
    (
        "https://files.pythonhosted.org/packages/3b/00/2344469e2084fb287c2e0b57b72910309874c3245463acd6cf5e3db69324/appdirs-1.4.4-py2.py3-none-any.whl",
        "a841dacd6b99318a741b166adb07e19ee71a274450e68237b4650ca1055ab128",
    ),
    (
        "https://files.pythonhosted.org/packages/ba/06/a07f096c664aeb9f01624f858c3add0a4e913d6c96257acb4fce61e7de14/certifi-2024.2.2-py3-none-any.whl",
        "dc383c07b76109f368f6106eee2b593b04a011ea4d55f652c6ca24a754d1cdd1",
    ),
    (
        "https://files.pythonhosted.org/packages/28/76/e6222113b83e3622caa4bb41032d0b1bf785250607392e1b778aca0b8a7d/charset_normalizer-3.3.2-py3-none-any.whl",
        "3e4d1f6587322d2788836a99c69062fbb091331ec940e02d12d179c1d53e25fc",
    ),
    (
        "https://files.pythonhosted.org/packages/e5/3e/741d8c82801c347547f8a2a06aa57dbb1992be9e948df2ea0eda2c8b79e8/idna-3.7-py3-none-any.whl",
        "82fee1fc78add43492d3a1898bfa6d8a904cc97d8427f683ed8e798d07761aa0",
    ),
    (
        "https://files.pythonhosted.org/packages/49/df/1fceb2f8900f8639e278b056416d49134fb8d84c5942ffaa01ad34782422/packaging-24.0-py3-none-any.whl",
        "2ddfb553fdf02fb784c234c7ba6ccc288296ceabec964ad2eae3777778130bc5",
    ),
    (
        "https://files.pythonhosted.org/packages/3b/1e/7c857196fb177e33bd6d9a0ed0f73d23a88a2f6b38936077859d76d938fd/req_compile-0.10.21-py2.py3-none-any.whl",
        "3c5c0382c2638f919d0f40ea9293f12690ea3464a305953888f25c477b5ca20c",
    ),
    (
        "https://files.pythonhosted.org/packages/70/8e/0e2d847013cb52cd35b38c009bb167a1a26b2ce6cd6965bf26b47bc0bf44/requests-2.31.0-py3-none-any.whl",
        "58cd2187c01e70e6e26505bca751777aa9f2ee0b7f4300988b709f44e013003f",
    ),
    (
        "https://files.pythonhosted.org/packages/d9/5a/e7c31adbe875f2abbb91bd84cf2dc52d792b5a01506781dbcf25c91daf11/six-1.16.0-py2.py3-none-any.whl",
        "8abb2f1d86890a2dfb989f9a77cfcfd3e47c2a354b01111771326f8aa26e0254",
    ),
    (
        "https://files.pythonhosted.org/packages/44/6f/7120676b6d73228c96e17f1f794d8ab046fc910d781c8d151120c3f1569e/toml-0.10.2-py2.py3-none-any.whl",
        "806143ae5bfb6a3c6e736a764057db0e6a0e05e338b5630894a5f779cabb4f9b",
    ),
    (
        "https://files.pythonhosted.org/packages/a2/73/a68704750a7679d0b6d3ad7aa8d4da8e14e151ae82e6fee774e6e0d05ec8/urllib3-2.2.1-py3-none-any.whl",
        "450b20ec296a467077128bff42b73080516e71b56ff59a60a02bef2232c4fa9d",
    ),
    (
        "https://files.pythonhosted.org/packages/7d/cd/d7460c9a869b16c3dd4e1e403cce337df165368c71d6af229a74699622ce/wheel-0.43.0-py3-none-any.whl",
        "55c570405f142630c6b9f72fe09d9b67cf1477fcf543ae5b8dcb1f5b7377da81",
    ),
]

def _req_compile_impl(ctx):
    python_interpreter = ctx.which("python")
    if not python_interpreter:
        fail("A system Python interpreter version 3.7 or greater is required.")

    inputs = {}
    index_urls = []

    direct_repos = []
    dev_repos = []
    requirements_files = []

    total_requirements = 0
    for mod in ctx.modules:
        if mod.tags.python_dep or mod.tags.python_requirements_file:
            inputs[mod.name] = ""
        for req in mod.tags.python_dep:
            total_requirements += 1
            inputs[mod.name] += req.name + "\n"
            sanitized_name = sanitize_package_name(req.name)
            if mod.is_root:
                if ctx.is_dev_dependency(req):
                    dev_repos.append(sanitized_name)
                else:
                    direct_repos.append(sanitized_name)

        for file in mod.tags.python_requirements_file:
            requirements_files.append(file.src)
            contents = ctx.read(file.src)
            for line in contents.split("\n"):
                line = line.strip()
                if not line or line.startswith("#"):
                    continue

                if line.startswith("-"):
                    fail("Directive {} in {} is not supported.".format(
                        line,
                        file.src,
                    ))
                project = line.split("[", 1)[0]
                sanitized_name = sanitize_package_name(project)
                total_requirements += 1
                if mod.is_root:
                    if ctx.is_dev_dependency(file):
                        dev_repos.append(sanitized_name)
                    else:
                        direct_repos.append(sanitized_name)

        for index_url in mod.tags.index_url:
            index_urls.append(index_url.url)

    if not total_requirements:
        fail("Extension included, but no requirements found.")

    for dep_url, sha256 in DEPS:
        if not dep_url.endswith(".whl") or "none-any" not in dep_url:
            fail("All dependencies must be purelib (no OS specific extensions) and wheels.")

        ctx.download_and_extract(
            url = dep_url,
            output = "deps/",
            type = "zip",
            sha256 = sha256,
        )

    for mod_name, contents in inputs.items():
        path = "{}/MODULE.bazel.in".format(mod_name)
        ctx.file(path, contents, executable = False)
        requirements_files.append(path)

    ctx.report_progress("Compiling {} Python requirements".format(
        total_requirements,
    ))
    result = ctx.execute(
        [
            python_interpreter,
            "-B",  # Do not create bytecode.
            "-I",  # Isolate from a user's environment.
            "-s",  # Don't add user site directory to sys.path.
            "-m",
            "req_compile",
            "--urls",
            "--hashes",
        ] +
        requirements_files +
        ["-i={}".format(url) for url in index_urls],
        environment = {
            "PYTHONPATH": str(ctx.path("deps")) +
                          "," +
                          str(ctx.path(Label("//req_compile"))) +
                          "/..",
        },
    )
    if result.return_code != 0:
        fail("Failed to compile requirements:\n{}".format(result.stderr))

    parsed_lockfile = parse_lockfile(result.stdout, "", {}, "")
    for repo_name, data in parsed_lockfile.items():
        whl_repository(
            name = repo_name,
            annotations = "{}",
            constraint = data["constraint"],
            deps = data["deps"],
            package = repo_name,
            sha256 = data["sha256"],
            urls = [data["url"]] if data.get("url", None) else None,
            version = data["version"],
            whl = data["whl"],
        )

    return ctx.extension_metadata(
        root_module_direct_deps = direct_repos,
        root_module_direct_dev_deps = dev_repos,
    )

_index_url = tag_class(attrs = {"url": attr.string(mandatory = True)})
_python_dep = tag_class(
    doc = "A Python dependency.",
    attrs = {
        "name": attr.string(mandatory = True),
        "version": attr.string(),
        "extras": attr.string_list(),
    },
)
_python_requirements_file = tag_class(
    doc = "A Python requirements input file.",
    attrs = {
        "src": attr.label(),
    },
)

compile = module_extension(
    implementation = _req_compile_impl,
    tag_classes = {
        "python_dep": _python_dep,
        "python_requirements_file": _python_requirements_file,
        "index_url": _index_url,
    },
)
