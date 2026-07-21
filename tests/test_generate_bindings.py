import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
GENERATOR = ROOT / "tools/generate_bindings.py"
API = ROOT / "godot-cpp/gdextension/extension_api.json"
PROFILE = ROOT / "tools/bindings_profile.json"


class GenerateBindingsTest(unittest.TestCase):
    def generate(self, output: Path) -> str:
        subprocess.run(
            [
                sys.executable,
                str(GENERATOR),
                "--api",
                str(API),
                "--profile",
                str(PROFILE),
                "--output",
                str(output),
            ],
            check=True,
            cwd=ROOT,
        )
        return output.read_text()

    def test_profile_targets_scene_and_ui_wrappers(self) -> None:
        profile = json.loads(PROFILE.read_text())
        self.assertEqual(
            [
                "Node",
                "CanvasItem",
                "Control",
                "Node2D",
                "Sprite2D",
                "Node3D",
                "Texture2D",
                "Viewport",
                "Tween",
            ],
            profile["classes"],
        )

    def test_generation_is_deterministic_and_flattens_node2d_methods(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            first = Path(directory) / "first.zig"
            second = Path(directory) / "second.zig"
            first_text = self.generate(first)
            second_text = self.generate(second)

        self.assertEqual(first_text, second_text)
        self.assertIn("pub const Node2D = extern struct", first_text)
        self.assertIn("pub const Sprite2D = extern struct", first_text)
        self.assertEqual(2, first_text.count("pub fn setRotation("))
        self.assertIn("pub inline fn setRotation(", first_text)

        self.assertNotIn("pub fn setTransform(", first_text)
        self.assertIn("pub fn asNode(self: @This()) Node", first_text)
        self.assertIn("pub fn asCanvasItem(self: @This()) CanvasItem", first_text)
        self.assertIn("pub fn asNode2D(self: @This()) Node2D", first_text)
        self.assertIn("pub const ProcessMode = enum(i64)", first_text)
        self.assertIn("pub const Side = enum(i64)", first_text)
        self.assertIn("pub const SizeFlags = enum(i64)", first_text)
        self.assertIn("pub fn setProcessMode(self: @This(), mode: Node.ProcessMode) !void", first_text)
        self.assertIn("pub fn getProcessMode(self: @This()) !Node.ProcessMode", first_text)
        self.assertIn("pub fn setRotationOrder(self: @This(), order: EulerOrder) !void", first_text)
        self.assertIn("pub fn setHSizeFlags(self: @This(), flags: Control.SizeFlags) !void", first_text)
        self.assertIn("pub fn addChild(self: @This(), node: Node,", first_text)
        self.assertIn("pub fn setOwner(self: @This(), owner: ?Node) !void", first_text)
        self.assertIn("pub fn setTexture(self: @This(), texture: ?Texture2D) !void", first_text)
        self.assertIn("pub fn getTexture(self: @This()) !?Texture2D", first_text)
        self.assertIn("pub fn createTween(self: @This()) !Tween", first_text)
        self.assertIn("try support.ptrcallVoid(self, _mb_set_process_mode.?, .{mode});", first_text)
        self.assertIn("pub const locale: @This() = .application_locale;", first_text)

        size_flags = first_text.split("pub const SizeFlags = enum(i64)", 1)[1].split("};", 1)[0]
        self.assertIn("    _,", size_flags)
        self.assertIn("pub const Texture2D = extern struct", first_text)
        texture_shell = first_text.split("pub const Texture2D = extern struct", 1)[1].split(
            "pub const Viewport = extern struct", 1
        )[0]
        self.assertNotIn("pub fn ", texture_shell)

    def test_selected_object_types_require_generated_shells(self) -> None:
        profile = json.loads(PROFILE.read_text())
        profile["classes"].remove("Viewport")
        with tempfile.TemporaryDirectory() as directory:
            temporary_profile = Path(directory) / "profile.json"
            output = Path(directory) / "classes.zig"
            temporary_profile.write_text(json.dumps(profile))
            result = subprocess.run(
                [
                    sys.executable,
                    str(GENERATOR),
                    "--api",
                    str(API),
                    "--profile",
                    str(temporary_profile),
                    "--output",
                    str(output),
                ],
                cwd=ROOT,
                capture_output=True,
                text=True,
            )
        self.assertNotEqual(0, result.returncode)
        self.assertIn("Viewport", result.stderr)

    def test_selected_methods_require_selected_enum_types(self) -> None:
        profile = json.loads(PROFILE.read_text())
        profile["enums"]["Node"].remove("ProcessMode")
        with tempfile.TemporaryDirectory() as directory:
            temporary_profile = Path(directory) / "profile.json"
            output = Path(directory) / "classes.zig"
            temporary_profile.write_text(json.dumps(profile))
            result = subprocess.run(
                [
                    sys.executable,
                    str(GENERATOR),
                    "--api",
                    str(API),
                    "--profile",
                    str(temporary_profile),
                    "--output",
                    str(output),
                ],
                cwd=ROOT,
                capture_output=True,
                text=True,
            )
        self.assertNotEqual(0, result.returncode)
        self.assertIn("ProcessMode", result.stderr)

    def test_profile_classes_are_publicly_exported(self) -> None:
        profile = json.loads(PROFILE.read_text())
        godot_source = (ROOT / "addons/gzscript/zig/godot.zig").read_text()
        for class_name in profile["classes"]:
            self.assertIn(f"pub const {class_name} = classes.{class_name};", godot_source)

    def test_checked_in_output_is_current(self) -> None:
        subprocess.run(
            [sys.executable, str(GENERATOR), "--check"],
            check=True,
            cwd=ROOT,
        )


if __name__ == "__main__":
    unittest.main()
