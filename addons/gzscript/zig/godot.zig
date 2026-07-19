pub const abi = @import("abi.zig");
const adapter = @import("adapter.zig");
const properties = @import("property.zig");
const runtime = @import("runtime.zig");

pub const ScriptAdapter = adapter.ScriptAdapter;
pub const property = properties.property;
pub const Property = properties.Property;
pub const InitContext = runtime.InitContext;
pub const Object = runtime.Object;
pub const Vector2 = abi.Vector2;
pub const Node = extern struct { owner: u64 };
pub const Node2D = extern struct { owner: u64 };
pub const Sprite2D = extern struct { owner: u64 };
pub const Control = extern struct { owner: u64 };
pub const log = runtime.log;

pub fn initialize(api: *const abi.EngineApi, output: **const abi.ScriptDescriptor, descriptor: *const abi.ScriptDescriptor) abi.Status {
    if (api.abi_version != abi.abi_version or api.struct_size != @sizeOf(abi.EngineApi)) return .abi_mismatch;
    runtime.engine_api = api;
    output.* = descriptor;
    return .ok;
}
