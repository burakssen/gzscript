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
pub const signal = signals.signal;
pub const InitContext = runtime.InitContext;
pub const Object = runtime.Object;
pub const log = runtime.log;
pub const Vector2 = abi.Vector2;
pub const Side = classes.Side;

pub const EulerOrder = classes.EulerOrder;

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

pub fn initialize(api: *const abi.EngineApi, output: **const abi.ScriptDescriptor, descriptor: *const abi.ScriptDescriptor) abi.Status {
    if (api.abi_version != abi.abi_version or api.struct_size != @sizeOf(abi.EngineApi)) return .abi_mismatch;
    runtime.engine_api = api;
    output.* = descriptor;
    return .ok;
}
