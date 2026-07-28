pub const abi = @import("abi.zig");
const adapter = @import("adapter.zig");
const classes = @import("class.zig");
pub const codec = @import("codec.zig");
const properties = @import("property.zig");
const runtime = @import("runtime.zig");
const signals = @import("signal.zig");

pub const ScriptAdapter = adapter.ScriptAdapter;
pub const property = properties.property;
pub const Property = properties.Property;
pub const exports = properties.exports;
pub const field = properties.field;
pub const category = properties.category;
pub const group = properties.group;
pub const subgroup = properties.subgroup;
pub const endGroup = properties.endGroup;
pub const signal = signals.signal;
pub const InitContext = runtime.InitContext;
pub const Object = runtime.Object;
pub const log = runtime.log;
pub const getTicksUsec = runtime.getTicksUsec;
pub const Vector = abi.Vector;
pub const Color = abi.Color;
pub const Transform2D = abi.Transform2D;
pub const Transform3D = abi.Transform3D;
pub const Rect2 = abi.Rect2;
pub const Side = classes.Side;

pub const EulerOrder = classes.EulerOrder;
pub const HorizontalAlignment = classes.HorizontalAlignment;

pub const Node = classes.Node;
pub const CanvasItem = classes.CanvasItem;
pub const Node2D = classes.Node2D;
pub const Sprite2D = classes.Sprite2D;
pub const Control = classes.Control;
pub const Node3D = classes.Node3D;
pub const Window = classes.Window;
pub const SceneTree = classes.SceneTree;
pub const Tween = classes.Tween;
pub const Viewport = classes.Viewport;
pub const MultiplayerAPI = classes.MultiplayerAPI;
pub const MultiMesh = classes.MultiMesh;
pub const Texture2D = classes.Texture2D;
pub const CanvasLayer = classes.CanvasLayer;
pub const World2D = classes.World2D;
pub const Material = classes.Material;
pub const InputEvent = classes.InputEvent;
pub const Theme = classes.Theme;
pub const StyleBox = classes.StyleBox;
pub const Font = classes.Font;
pub const AccessibilityServer = classes.AccessibilityServer;
pub const World3D = classes.World3D;
pub const Node3DGizmo = classes.Node3DGizmo;
pub const Mesh = classes.Mesh;
pub const TextServer = classes.TextServer;

pub fn initialize(api: *const abi.EngineApi, output: **const abi.ScriptDescriptor, descriptor: *const abi.ScriptDescriptor) abi.Status {
    if (api.abi_version != abi.abi_version or api.struct_size != @sizeOf(abi.EngineApi)) return .abi_mismatch;
    runtime.engine_api = api;
    output.* = descriptor;
    return .ok;
}
