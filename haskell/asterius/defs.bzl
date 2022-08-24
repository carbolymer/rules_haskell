# Since this module depends on rules_nodejs, documentation using
# stardoc does not seem to be possible at the moment because of
# https://github.com/bazelbuild/rules_nodejs/issues/2874.
# And for now stardoc always try to explore third party dependencies
# https://github.com/bazelbuild/stardoc/issues/93.

load("@bazel_skylib//lib:paths.bzl", "paths")
load("@build_bazel_rules_nodejs//:index.bzl", "nodejs_binary", "nodejs_test")
load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")

def _asterius_toolchain_impl(ctx):
    ahc_dist = None
    for file in ctx.files.binaries:
        basename_no_ext = paths.split_extension(file.basename)[0]
        if basename_no_ext == "ahc-dist":
            ahc_dist = file
    if ahc_dist == None:
        fail("ahc-dist was not found when defining the asterius toolchain")

    return [
        platform_common.ToolchainInfo(
            name = ctx.label.name,
            ahc_dist = ahc_dist,
            tools = ctx.files.tools,
        ),
    ]

asterius_toolchain = rule(
    _asterius_toolchain_impl,
    attrs = {
        "binaries": attr.label_list(
            mandatory = True,
            doc = "The asterius top level wrappers",
        ),
        "tools": attr.label_list(
            mandatory = True,
            doc = "The complete asterius bundle, which is needed to execute the wrappers.",
        ),
    },
    doc = "Toolchain for asterius tools that are not part of the regular haskell toolchain",
)

# The ahc_dist rule generates an archive containing javascript files
# from a haskell binary build with the asterius toolchain.  We ensure
# that this toolchain is selected using the following transition to
# select the asterius platform.
# We also set the asterius_targets_browser back to it's default value
# as it in not needed anymore.
def _asterius_transition_impl(settings, attr):
    return {
        "//command_line_option:platforms": "@rules_haskell//haskell/asterius:asterius_platform",
        "@rules_haskell_asterius_build_setting//:asterius_targets_browser": False,
    }

_asterius_transition = transition(
    implementation = _asterius_transition_impl,
    inputs = [],
    outputs = [
        "//command_line_option:platforms",
        "@rules_haskell_asterius_build_setting//:asterius_targets_browser",
    ],
)

# ahc_dist targets used by asterius_webpack rules must be configured for the browser.
# We use the following transition for this purpose.
def _set_ahc_dist_browser_target_impl(settings, attr):
    return {"@rules_haskell_asterius_build_setting//:asterius_targets_browser": True}

_set_ahc_dist_browser_target = transition(
    implementation = _set_ahc_dist_browser_target_impl,
    inputs = [],
    outputs = ["@rules_haskell_asterius_build_setting//:asterius_targets_browser"],
)

AhcDistInfo = provider(
    "Info about the output files of ahc_dist.",
    fields = {
        "targets_browser": "whether this target was built for the browser (instead of for node)",
        "webpack_config": "The webpack_config file that may be used by the asterius_webpack rule ",
    },
)

# runtime modules generated by ahc_dist
_javascript_runtime_modules = [
    "rts.autoapply.mjs",
    "rts.closuretypes.mjs",
    "rts.constants.mjs",
    "rts.eventlog.mjs",
    "rts.exception.mjs",
    "rts.exports.mjs",
    "rts.float.mjs",
    "rts.fs.mjs",
    "rts.funtypes.mjs",
    "rts.gc.mjs",
    "rts.heapalloc.mjs",
    "rts.integer.mjs",
    "rts.jsval.mjs",
    "rts.memory.mjs",
    "rts.memorytrap.mjs",
    "rts.messages.mjs",
    "rts.mjs",
    "rts.modulify.mjs",
    "rts.reentrancy.mjs",
    "rts.scheduler.mjs",
    "rts.setimmediate.mjs",
    "rts.stablename.mjs",
    "rts.stableptr.mjs",
    "rts.staticptr.mjs",
    "rts.symtable.mjs",
    "rts.time.mjs",
    "rts.tracing.mjs",
    "rts.unicode.mjs",
    "rts.wasi.mjs",
    "default.mjs",
]

# Label of the template file to use for the webpack config.
_TEMPLATE = "@rules_haskell//haskell/asterius:asterius_webpack_config.js.tpl"
_SUBFOLDER_PREFIX = "asterius"

def _ahc_dist_impl(ctx):
    asterius_toolchain = ctx.toolchains["@rules_haskell//haskell/asterius:toolchain_type"]
    posix_toolchain = ctx.toolchains["@rules_sh//sh/posix:toolchain_type"]
    nodejs_toolchain = ctx.toolchains["@rules_nodejs//nodejs:toolchain_type"]
    node_toolfiles = nodejs_toolchain.nodeinfo.tool_files

    subfolder_name = ctx.attr.subfolder_name or "{}_{}".format(_SUBFOLDER_PREFIX, ctx.label.name)
    entry_point = ctx.attr.entry_point or "{}.mjs".format(ctx.label.name)
    entry_point_file = ctx.actions.declare_file(paths.join(subfolder_name, entry_point))
    all_output_files = [entry_point_file]

    for m in _javascript_runtime_modules:
        f = ctx.actions.declare_file(paths.join(subfolder_name, m))
        all_output_files.append(f)

    (output_prefix, _) = paths.split_extension(entry_point)

    for ext in [".wasm", ".wasm.mjs", ".req.mjs"]:
        f = ctx.actions.declare_file(paths.join(subfolder_name, output_prefix + ext))
        all_output_files.append(f)

    targets_browser = ctx.attr._target[BuildSettingInfo].value
    if targets_browser:
        f = ctx.actions.declare_file(paths.join(subfolder_name, output_prefix + ".html"))
        all_output_files.append(f)

    # ctx.file.dep was generated in the asterius platform configuration,
    # and we want to generate js files in the current configuration.
    # So we will copy it to the folder corresponding to the current platform.

    file_copy_path = paths.join(entry_point_file.dirname, ctx.file.dep.basename)

    # custom entry point to the javascript/webassembly, because the
    # asterius default one catches failures before they are detected
    # by bazel tests.
    entrypoint_path = paths.replace_extension(file_copy_path, ".mjs")
    entrypoint_file = ctx.actions.declare_file(entrypoint_path)
    ctx.actions.write(
        entrypoint_file,
        """
import * as rts from "./rts.mjs";
import module from "./{output_prefix}.wasm.mjs";
import req from "./{output_prefix}.req.mjs";

module
  .then(m => rts.newAsteriusInstance(Object.assign(req, {{ module: m }})))
  .then(i => {{
    i.exports.main();
  }});
        """.format(output_prefix = output_prefix),
    )

    # We generate the webpack config file that can be used by the
    # asterius_webpack rule to bundle all the files together.
    webpack_config = ctx.actions.declare_file(
        paths.join(subfolder_name, "{}.webpack.config.js".format(ctx.label.name)),
    )
    ctx.actions.expand_template(
        template = ctx.file._template,
        output = webpack_config,
        substitutions = {
            "{ENTRY}": entry_point,
        },
    )

    input_mjs = "--input-mjs {}".format(entrypoint_file.path)
    browser = " --browser" if targets_browser else ""
    options = " ".join(ctx.attr.options)
    command = " && ".join([
        "cp $2 $3",
        "$1 --input-exe $3 {} --output-prefix {} {} {}".format(options, output_prefix, input_mjs, browser),
    ])

    ctx.actions.run_shell(
        inputs = [ctx.file.dep, entrypoint_file, webpack_config],
        outputs = all_output_files,
        command = command,
        env = {"PATH": ":".join(posix_toolchain.paths + [node_toolfiles[0].dirname])},
        arguments = [
            asterius_toolchain.ahc_dist.path,
            ctx.file.dep.path,
            file_copy_path,
        ],
        tools = asterius_toolchain.tools + node_toolfiles,
    )

    all_output_files.append(entrypoint_file)
    all_output_files.append(webpack_config)

    runfiles = ctx.runfiles(files = all_output_files)
    runfiles = runfiles.merge(ctx.attr.dep[0][DefaultInfo].default_runfiles)

    return [
        DefaultInfo(
            files = depset(all_output_files),
            runfiles = runfiles,
        ),
        AhcDistInfo(
            targets_browser = targets_browser,
            webpack_config = webpack_config,
        ),
    ]

ahc_dist = rule(
    _ahc_dist_impl,
    attrs = {
        "dep": attr.label(
            mandatory = True,
            allow_single_file = True,
            cfg = _asterius_transition,
            doc = """\
            The label of a haskell_binary, haskell_test or haskell_cabal_binary target.
            """,
        ),
        "entry_point": attr.string(
            default = "",
            doc = "The name for the output file corresponding to the entrypoint. It must terminate by '.mjs'",
        ),
        "options": attr.string_list(
            doc = "Other options to pass to ahc-dist",
        ),
        "subfolder_name": attr.string(
            doc = "Optional name to override the generated folder. The default one is based on the rule name.",
            default = "",
        ),
        "_target": attr.label(default = "@rules_haskell_asterius_build_setting//:asterius_targets_browser"),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
        "_template": attr.label(
            default = Label(_TEMPLATE),
            allow_single_file = True,
        ),
    },
    toolchains = [
        "@rules_sh//sh/posix:toolchain_type",
        "@rules_haskell//haskell/asterius:toolchain_type",
        "@rules_nodejs//nodejs:toolchain_type",
    ],
    doc = "This rule transforms a haskell binary target into an archive containing javascript files.",
)

def asterius_webpack_impl(ctx):
    ahc_dist_info = ctx.attr.ahc_dist_dep[0][AhcDistInfo]
    if not ahc_dist_info.targets_browser:
        fail("{} was not built for the browser (with @rules_haskell_asterius_build_setting//:asterius_targets_browser set to True).".format(
            ctx.attr.ahc_dist_dep[0].label,
        ))

    output_file = ctx.actions.declare_file("{}.mjs".format(ctx.label.name))
    posix_toolchain = ctx.toolchains["@rules_sh//sh/posix:toolchain_type"]
    all_paths = posix_toolchain.paths + [paths.dirname(ctx.executable._webpack.path)]

    webpack_config_path = ahc_dist_info.webpack_config.path
    webpack_command = " ".join([
        "webpack.sh",
        "--nobazel_node_patches",  # https://github.com/bazelbuild/rules_nodejs/issues/2076
        "--config",
        webpack_config_path,
        "-o .",
        "--output-filename",
        output_file.path,
    ])
    ctx.actions.run_shell(
        inputs = ctx.files.ahc_dist_dep,
        outputs = [output_file],
        command = webpack_command,
        env = {"PATH": ":".join(all_paths)},
        arguments = [],
        tools = ctx.files._webpack,
    )
    return [DefaultInfo(files = depset([output_file]))]

asterius_webpack = rule(
    asterius_webpack_impl,
    attrs = {
        "ahc_dist_dep": attr.label(
            mandatory = True,
            doc = """\
The ahc_dist target (built with target="browser") from which we will create a bundle.
                  """,
            cfg = _set_ahc_dist_browser_target,
        ),
        "_webpack": attr.label(
            default = "@rules_haskell_asterius_webpack//:webpack",
            executable = True,
            cfg = "exec",
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
    toolchains = [
        "@rules_sh//sh/posix:toolchain_type",
    ],
    doc = "Creates a bundle using webpack out of ahc_dist target build for the browser.",
)

# Copied from https://github.com/tweag/asterius/blob/9f2574d9c2b50aa83d105741799e2f65b05e2023/asterius/test/ghc-testsuite.hs
# The node options required to execute outputs from asterius.

_node_options = [
    "--experimental-modules",
    "--experimental-wasi-unstable-preview1",
    "--experimental-wasm-return-call",
    "--no-wasm-bounds-checks",
    "--no-wasm-stack-checks",
    "--unhandled-rejections=strict",
    "--wasm-lazy-compilation",
    "--wasm-lazy-validation",
    "--unhandled-rejections=strict",
]

def _name_of_label(l):
    return l.split(":")[-1]

def _asterius_common_impl(is_asterius_test, name, ahc_dist_dep, entry_point = None, subfolder_name = None, data = [], **kwargs):
    """common implementation for asterius_test and asterius_binary"""
    subfolder_name = subfolder_name or "_".join([_SUBFOLDER_PREFIX, _name_of_label(ahc_dist_dep)])
    entry_point = entry_point or "{}.mjs".format(_name_of_label(ahc_dist_dep))
    nodejs_rule = nodejs_test if is_asterius_test else nodejs_binary
    nodejs_rule(
        name = name,
        entry_point = paths.join(subfolder_name, entry_point),
        templated_args =
            ["--node_options={}".format(opt) for opt in _node_options] +
            ["--nobazel_node_patches "],  # https://github.com/bazelbuild/rules_nodejs/issues/2076
        chdir = native.package_name() + "/" + subfolder_name,
        data = data + [ahc_dist_dep],
        **kwargs
    )

def asterius_test(**kwargs):
    """\
    A wrapper around the [nodejs_test](https://bazelbuild.github.io/rules_nodejs/Built-ins.html#nodejs_binary) rule compatibe with asterius.

    Args:
        name: A unique name for this rule.
        ahc_dist_dep:
            The ahc_dist target (built with target="node") to be executed.
        subfolder_name:
            If the `subfolder_name` attribute was overriden in the `ahc_dist_dep` target,
            we need to specify the same here.
        entry_point:
            If the `entry_point` attribute was overriden in the `ahc_dist_dep` target,
            we need to specify the same here.
        configuration_env_vars:
            [see nodejs_test](https://bazelbuild.github.io/rules_nodejs/Built-ins.html#nodejs_test-configuration_env_vars)
        data:
            [see nodejs_test](https://bazelbuild.github.io/rules_nodejs/Built-ins.html#nodejs_test-data)
        default_env_vars:
            [see nodejs_test](https://bazelbuild.github.io/rules_nodejs/Built-ins.html#nodejs_test-default_env_vars)
        env:
            [see nodejs_test](https://bazelbuild.github.io/rules_nodejs/Built-ins.html#nodejs_test-env)
        link_workspace_root:
            [see nodejs_test](https://bazelbuild.github.io/rules_nodejs/Built-ins.html#nodejs_test-link_workspace_root)
        """
    _asterius_common_impl(is_asterius_test = True, **kwargs)

def asterius_binary(**kwargs):
    """\
    A wrapper around the [nodejs_binary](https://bazelbuild.github.io/rules_nodejs/Built-ins.html#nodejs_binary) rule compatibe with asterius.

    Args:
        name: A unique name for this rule.
        ahc_dist_dep:
            The ahc_dist target (built with target="node") to be executed.
        subfolder_name:
            If the `subfolder_name` attribute was overriden in the `ahc_dist_dep` target,
            we need to specify the same here.
        entry_point:
            If the `entry_point` attribute was overriden in the `ahc_dist_dep` target,
            we need to specify the same here.
        configuration_env_vars:
            [see nodejs_binary](https://bazelbuild.github.io/rules_nodejs/Built-ins.html#nodejs_binary-configuration_env_vars)
        data:
            [see nodejs_binary](https://bazelbuild.github.io/rules_nodejs/Built-ins.html#nodejs_binary-data)
        default_env_vars:
            [see nodejs_binary](https://bazelbuild.github.io/rules_nodejs/Built-ins.html#nodejs_binary-default_env_vars)
        env:
            [see nodejs_binary](https://bazelbuild.github.io/rules_nodejs/Built-ins.html#nodejs_binary-env)
        link_workspace_root:
            [see nodejs_binary](https://bazelbuild.github.io/rules_nodejs/Built-ins.html#nodejs_binary-link_workspace_root)
        """
    _asterius_common_impl(is_asterius_test = False, **kwargs)
