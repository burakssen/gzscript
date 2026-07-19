#!/usr/bin/env python

env = SConscript("godot-cpp/SConstruct")
env.Append(CPPPATH=["src/"])
env.Append(CXXFLAGS=["-std=c++17"])

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
Default(library)
