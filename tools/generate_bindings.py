#!/usr/bin/env python3

import argparse
import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_API = ROOT / "godot-cpp/gdextension/extension_api.json"
DEFAULT_PROFILE = ROOT / "tools/bindings_profile.json"
DEFAULT_OUTPUT = ROOT / "addons/gzscript/zig/class.zig"
ZIG_KEYWORDS = {
    "addrspace",
    "align",
    "allowzero",
    "and",
    "anyframe",
    "anytype",
    "asm",
    "async",
    "await",
    "break",
    "callconv",
    "catch",
    "comptime",
    "const",
    "continue",
    "defer",
    "else",
    "enum",
    "errdefer",
    "error",
    "export",
    "extern",
    "fn",
    "for",
    "if",
    "inline",
    "linksection",
    "noalias",
    "noinline",
    "nosuspend",
    "opaque",
    "or",
    "orelse",
    "packed",
    "pub",
    "resume",
    "return",
    "struct",
    "suspend",
    "switch",
    "test",
    "threadlocal",
    "try",
    "union",
    "unreachable",
    "usingnamespace",
    "var",
    "volatile",
    "while",
}


def identifier(name: str) -> str:
    return f'@"{name}"' if name in ZIG_KEYWORDS else name


def camel_case(name: str) -> str:
    head, *tail = name.split("_")
    return head + "".join(part.capitalize().replace("2d", "2D").replace("3d", "3D") for part in tail)


def camel_to_snake(name: str) -> str:
    res = []
    for i, c in enumerate(name):
        if c.isupper() and i > 0 and (name[i-1].islower() or (i + 1 < len(name) and name[i+1].islower())):
            res.append("_")
        res.append(c.lower())
    return "".join(res)



def zig_type(
    type_name: str,
    *,
    returning: bool,
    generated_classes: set[str],
    enum_types: dict[str, str],
    required: bool = False,
) -> str | None:
    primitive = {
        "bool": "bool",
        "int": "i64",
        "float": "f64",
        "Vector2": "abi.Vector2(f64)",
    }

    if type_name in primitive:
        return primitive[type_name]
    if type_name == "String" and not returning:
        return "[]const u8"
    if type_name in ("StringName", "NodePath") and not returning:
        return "[]const u8"
    if type_name.startswith(("enum::", "bitfield::")):
        return enum_types.get(type_name)
    if type_name in generated_classes:
        return type_name if required else f"?{type_name}"
    return None


def inheritance_chain(class_name: str, classes: dict[str, dict]) -> list[str]:
    chain = []
    current = class_name
    visited = set()
    while current:
        if current in visited:
            raise ValueError(f"inheritance cycle at {current}")
        if current not in classes:
            raise ValueError(f"missing inherited class: {current}")
        visited.add(current)
        chain.append(current)
        current = classes[current].get("inherits")
    chain.reverse()
    return chain


def selected_methods(
    class_name: str,
    classes: dict[str, dict],
    method_profile: dict[str, list[str]],
) -> list[dict]:
    selected: dict[str, dict] = {}
    for ancestor in inheritance_chain(class_name, classes):
        wanted = set(method_profile.get(ancestor, []))
        declared = {method["name"]: method for method in classes[ancestor].get("methods", [])}
        missing = wanted - declared.keys()
        if missing:
            raise ValueError(f"{ancestor} methods not found: {', '.join(sorted(missing))}")
        for method in classes[ancestor].get("methods", []):
            if method["name"] in wanted:
                selected[method["name"]] = method
    return list(selected.values())


def find_enum(entries: list[dict], name: str, context: str) -> dict:
    for entry in entries:
        if entry["name"] == name:
            return entry
    raise ValueError(f"{context} enum not found: {name}")


def clean_enum_field_name(field_name: str, enum_name: str) -> str:
    upper_field = field_name.upper()
    prefixes = [camel_to_snake(enum_name).upper() + "_"]
    for suffix in ["Mode", "Flags", "Direction", "Preset", "Order", "Filter", "Repeat"]:
        if enum_name.endswith(suffix) and len(enum_name) > len(suffix):
            base = enum_name[:-len(suffix)]
            prefixes.append(camel_to_snake(base).upper() + "_")
            if suffix == "Flags":
                prefixes.append(camel_to_snake(enum_name[:-1]).upper() + "_")
            elif suffix in ["Filter", "Repeat", "Preset"]:
                prefixes.append(suffix.upper() + "_")
    if "PRESET_MODE_" in upper_field:
        prefixes.insert(0, "PRESET_MODE_")
    elif "PRESET_" in upper_field:
        prefixes.insert(0, "PRESET_")

    for prefix in prefixes:
        if upper_field.startswith(prefix):
            trimmed = field_name[len(prefix):]
            if trimmed:
                return trimmed.lower()
    return field_name.lower()


def render_enum(entry: dict, indent: str = "") -> list[str]:
    enum_name = entry["name"]
    values: dict[int, str] = {}
    aliases = []
    for value in entry.get("values", []):
        number = value["value"]
        clean_name = clean_enum_field_name(value["name"], enum_name)
        if not isinstance(number, int) or not -(2**63) <= number < 2**63:
            raise ValueError(f"{entry['name']}.{value['name']} does not fit i64")
        if number in values:
            aliases.append((clean_name, values[number]))
        else:
            values[number] = clean_name

    lines = [f"{indent}pub const {identifier(entry['name'])} = enum(i64) {{"]
    for number, name in values.items():
        lines.append(f"{indent}    {identifier(name)} = {number},")
    if entry.get("is_bitfield"):
        lines.append(f"{indent}    _,")
    for alias, canonical in aliases:
        lines.append(
            f"{indent}    pub const {identifier(alias)}: @This() = .{identifier(canonical)};"
        )
    lines.append(f"{indent}}};")
    return lines



def is_ptrcall_safe(type_name: str | None) -> bool:
    if type_name is None:
        return True
    if "[]" in type_name or "?" in type_name:
        return False
    return True


def render_method(method: dict, generated_classes: set[str], enum_types: dict[str, str], class_name: str = "") -> list[str]:
    if method.get("is_virtual") or method.get("is_static") or method.get("is_vararg"):
        raise ValueError(f"unsupported method kind: {method['name']}")

    parameters = ["self: @This()"]
    argument_names = []
    argument_types = []
    for argument in method.get("arguments", []):
        argument_type = zig_type(
            argument["type"],
            returning=False,
            generated_classes=generated_classes,
            enum_types=enum_types,
            required=argument.get("meta") == "required",
        )
        if argument_type is None:
            raise ValueError(f"unsupported argument type for {method['name']}: {argument['type']}")
        argument_name = identifier(argument["name"])
        parameters.append(f"{argument_name}: {argument_type}")
        argument_names.append(argument_name)
        argument_types.append(argument_type)

    return_value = method.get("return_value")
    return_type = None
    if return_value:
        return_type = zig_type(
            return_value["type"],
            returning=True,
            generated_classes=generated_classes,
            enum_types=enum_types,
            required=return_value.get("meta") == "required",
        )
        if return_type is None:
            raise ValueError(f"unsupported return type for {method['name']}: {return_value['type']}")

    method_hash = method.get("hash", 0)
    use_ptrcall = (
        is_ptrcall_safe(return_type)
        and all(is_ptrcall_safe(at) for at in argument_types)
        and method_hash != 0
        and class_name
    )

    tuple_arguments = ".{" + ", ".join(argument_names) + "}"
    if len(argument_names) > 1:
        tuple_arguments = ".{ " + ", ".join(argument_names) + " }"
    lines = [f"    pub fn {identifier(camel_case(method['name']))}({', '.join(parameters)}) !{return_type or 'void'} {{"]
    if use_ptrcall:
        mb_var = f"_mb_{method['name']}"
        lines.append(f'        if ({mb_var} == null) {mb_var} = runtime.getMethodBind("{class_name}", "{method["name"]}", {method_hash});')
        if return_type:
            lines.append(f'        return support.ptrcall(self, {return_type}, {mb_var}.?, {tuple_arguments});')
        else:
            lines.append(f'        try support.ptrcallVoid(self, {mb_var}.?, {tuple_arguments});')
    else:
        if return_type:
            lines.append(
                f'        return support.call(self, {return_type}, "{method["name"]}", {tuple_arguments});'
            )
        else:
            lines.append(f'        try support.callVoid(self, "{method["name"]}", {tuple_arguments});')
    lines.append("    }")
    return lines


def find_declaring_class(method_name: str, class_name: str, classes: dict[str, dict]) -> str:
    for cls in reversed(inheritance_chain(class_name, classes)):
        declared = {m["name"] for m in classes[cls].get("methods", [])}
        if method_name in declared:
            return cls
    return class_name


def render_forwarded_method(method: dict, declaring_class: str, generated_classes: set[str], enum_types: dict[str, str]) -> list[str]:
    parameters = ["self: @This()"]
    argument_names = []
    for argument in method.get("arguments", []):
        argument_type = zig_type(
            argument["type"],
            returning=False,
            generated_classes=generated_classes,
            enum_types=enum_types,
            required=argument.get("meta") == "required",
        )
        argument_name = identifier(argument["name"])
        parameters.append(f"{argument_name}: {argument_type}")
        argument_names.append(argument_name)

    return_value = method.get("return_value")
    return_type = None
    if return_value:
        return_type = zig_type(
            return_value["type"],
            returning=True,
            generated_classes=generated_classes,
            enum_types=enum_types,
            required=return_value.get("meta") == "required",
        )

    method_name = identifier(camel_case(method["name"]))
    call_args = ", ".join(argument_names)
    lines = [
        "    // ponytail: forward to ancestor class to avoid duplicating _mb_ handle",
        f"    pub inline fn {method_name}({', '.join(parameters)}) !{return_type or 'void'} {{",
    ]
    if return_type:
        lines.append(f"        return try self.as{declaring_class}().{method_name}({call_args});")
    else:
        lines.append(f"        try self.as{declaring_class}().{method_name}({call_args});")
    lines.append("    }")
    return lines


def generate(api: dict, profile: dict) -> str:
    version = api["header"]
    if version["version_major"] != 4 or version["version_minor"] != 7:
        raise ValueError("bindings profile requires Godot 4.7")

    classes = {entry["name"]: entry for entry in api["classes"]}
    target_classes = profile["classes"]
    if len(target_classes) != len(set(target_classes)):
        raise ValueError("profile classes must be unique")
    missing_classes = set(target_classes) - classes.keys()
    if missing_classes:
        raise ValueError(f"classes not found: {', '.join(sorted(missing_classes))}")
    generated_classes = set(target_classes)
    shell_classes = set(profile.get("shells", []))
    unknown_shells = shell_classes - generated_classes
    if unknown_shells:
        raise ValueError(f"shells not found in profile classes: {', '.join(sorted(unknown_shells))}")

    enum_types = {}
    selected_global_enums = []
    for enum_name in profile.get("global_enums", []):
        entry = find_enum(api.get("global_enums", []), enum_name, "global")
        prefix = "bitfield" if entry.get("is_bitfield") else "enum"
        enum_types[f"{prefix}::{enum_name}"] = enum_name
        selected_global_enums.append(entry)

    selected_class_enums: dict[str, list[dict]] = {}
    for class_name, enum_names in profile.get("enums", {}).items():
        if class_name not in generated_classes:
            raise ValueError(f"enum owner is not a generated class: {class_name}")
        selected_class_enums[class_name] = []
        for enum_name in enum_names:
            entry = find_enum(classes[class_name].get("enums", []), enum_name, class_name)
            prefix = "bitfield" if entry.get("is_bitfield") else "enum"
            enum_types[f"{prefix}::{class_name}.{enum_name}"] = f"{class_name}.{enum_name}"
            selected_class_enums[class_name].append(entry)

    lines = [
        "// Generated by tools/generate_bindings.py. Do not edit.",
        f"// Godot {version['version_major']}.{version['version_minor']}.{version['version_patch']} {version['version_status']}; precision: {version['precision']}.",
        'const abi = @import("abi.zig");',
        'const runtime = @import("runtime.zig");',
        'const support = @import("class_support.zig");',
        "",
        "pub const Vector2 = abi.Vector2;",
        "",
    ]

    for enum_entry in selected_global_enums:
        lines.extend(render_enum(enum_entry))
        lines.append("")

    for class_name in target_classes:
        lines.extend(
            [
                f"pub const {class_name} = extern struct {{",
                "    owner: u64,",
                "",
                f'    pub const godot_class = "{class_name}";',
                "    pub const emitSignal = support.emitSignal;",
            ]
        )
        for enum_entry in selected_class_enums.get(class_name, []):
            lines.append("")
            lines.extend(render_enum(enum_entry, "    "))
        if class_name not in shell_classes:
            for ancestor in inheritance_chain(class_name, classes)[:-1]:
                if ancestor not in generated_classes or ancestor in shell_classes:
                    continue
                lines.extend(
                    [
                        "",
                        f"    pub fn as{ancestor}(self: @This()) {ancestor} {{",
                        "        return .{ .owner = self.owner };",
                        "    }",
                    ]
                )
        methods = [] if class_name in shell_classes else selected_methods(class_name, classes, profile.get("methods", {}))
        native_methods = []
        forwarded_methods = []
        for method in methods:
            declaring_class = find_declaring_class(method["name"], class_name, classes)
            if declaring_class == class_name:
                native_methods.append(method)
            else:
                forwarded_methods.append((method, declaring_class))

        for method in native_methods:
            arg_types = [
                zig_type(a["type"], returning=False, generated_classes=generated_classes, enum_types=enum_types, required=a.get("meta") == "required")
                for a in method.get("arguments", [])
            ]
            ret_type = (
                zig_type(method["return_value"]["type"], returning=True, generated_classes=generated_classes, enum_types=enum_types, required=method["return_value"].get("meta") == "required")
                if method.get("return_value")
                else None
            )
            if is_ptrcall_safe(ret_type) and all(is_ptrcall_safe(at) for at in arg_types) and method.get("hash", 0) != 0:
                lines.append(f'    var _mb_{method["name"]}: abi.MethodBind = null;')

        for method in native_methods:
            lines.append("")
            lines.extend(render_method(method, generated_classes, enum_types, class_name))

        for method, declaring_class in forwarded_methods:
            lines.append("")
            lines.extend(render_forwarded_method(method, declaring_class, generated_classes, enum_types))

        lines.extend(["};", ""])
    return "\n".join(lines)




def main() -> int:
    parser = argparse.ArgumentParser(description="Generate typed gzscript Godot wrappers")
    parser.add_argument("--api", type=Path, default=DEFAULT_API)
    parser.add_argument("--profile", type=Path, default=DEFAULT_PROFILE)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--check", action="store_true")
    arguments = parser.parse_args()

    output = generate(json.loads(arguments.api.read_text()), json.loads(arguments.profile.read_text()))
    if arguments.check:
        if not arguments.output.exists() or arguments.output.read_text() != output:
            print(f"generated bindings are stale: {arguments.output}", file=sys.stderr)
            return 1
        return 0
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(output, encoding="utf-8", newline="\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
