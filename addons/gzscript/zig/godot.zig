pub const abi = @import("abi.zig");
const adapter = @import("adapter.zig");
const classes = @import("class.zig");
const properties = @import("property.zig");
const runtime = @import("runtime.zig");

pub const ScriptAdapter = adapter.ScriptAdapter;
pub const property = properties.property;
pub const Property = properties.Property;
pub const InitContext = runtime.InitContext;
pub const Object = runtime.Object;
pub const log = runtime.log;
pub const Vector2 = classes.Vector2;
pub const Node = classes.Node;
pub const Node2D = classes.Node2D;
pub const Sprite2D = classes.Sprite2D;
pub const Control = classes.Control;

pub fn initialize(api: *const abi.EngineApi, output: **const abi.ScriptDescriptor, descriptor: *const abi.ScriptDescriptor) abi.Status {
    if (api.abi_version != abi.abi_version or api.struct_size != @sizeOf(abi.EngineApi)) return .abi_mismatch;
    runtime.engine_api = api;
    output.* = descriptor;
    return .ok;
}
