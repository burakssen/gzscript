#!/usr/bin/env python

import sys


env = SConscript("godot-cpp/SConstruct")
env.Append(CPPPATH=["src/"])
env.Append(CXXFLAGS=["-std=c++17"])

generated_bindings = env.Command(
    "addons/gzscript/zig/class.zig",
    [
        "tools/generate_bindings.py",
        "tools/bindings_profile.json",
        "godot-cpp/gdextension/extension_api.json",
    ],
    '"{}" tools/generate_bindings.py'.format(sys.executable),
)

sources = Glob("src/*.cpp")

if env["platform"] == "macos":
    library = env.SharedLibrary(
        "addons/gzscript/bin/libgzscript.macos.{}.{}.framework/libgzscript.macos.{}.{}".format(
            env["target"], env["arch"], env["target"], env["arch"]
        ),
        source=sources,
    )
else:
    library = env.SharedLibrary(
        "addons/gzscript/bin/libgzscript{}{}".format(env["suffix"], env["SHLIBSUFFIX"]),
        source=sources,
    )

env.NoCache(library)
env.Depends(library, generated_bindings)
Default(library)
