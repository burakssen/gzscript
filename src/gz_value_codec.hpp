#pragma once

#include "abi/gzscript_abi.h"

#include <godot_cpp/variant/char_string.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/variant.hpp>

namespace gzscript {

godot::String from_view(GzStringView value);
godot::Variant to_variant(const GzValue &value, bool *valid = nullptr);
GzValue from_variant(const godot::Variant &value,
                     godot::CharString *string_storage = nullptr,
                     bool *valid = nullptr);
godot::Variant::Type variant_type(uint32_t type);

} // namespace gzscript
