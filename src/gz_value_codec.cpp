#include "gz_value_codec.hpp"

#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/core/object.hpp>

using namespace godot;

namespace gzscript {

namespace {
void set_valid(bool *valid, bool value) {
  if (valid)
    *valid = value;
}
} // namespace

String from_view(GzStringView value) {
  return String::utf8(value.ptr, static_cast<int64_t>(value.len));
}

Variant to_variant(const GzValue &value, bool *valid) {
  set_valid(valid, true);
  switch (value.type) {
  case GZ_VALUE_NIL:
    return {};
  case GZ_VALUE_BOOL:
    return value.data.boolean;
  case GZ_VALUE_INT:
    return value.data.integer;
  case GZ_VALUE_FLOAT:
    return value.data.floating;
  case GZ_VALUE_STRING:
    return from_view(value.data.string);
  case GZ_VALUE_VECTOR2:
    return Vector2(value.data.vector2.x, value.data.vector2.y);
  case GZ_VALUE_OBJECT:
    return ObjectDB::get_instance(value.data.object_id);
  case GZ_VALUE_VECTOR3:
    return Vector3(value.data.vector3.x, value.data.vector3.y,
                   value.data.vector3.z);
  case GZ_VALUE_COLOR:
    return Color(value.data.color.r, value.data.color.g, value.data.color.b,
                 value.data.color.a);
  case GZ_VALUE_TRANSFORM2D:
    return Transform2D(value.data.transform2d.x.x, value.data.transform2d.x.y,
                       value.data.transform2d.y.x, value.data.transform2d.y.y,
                       value.data.transform2d.origin.x,
                       value.data.transform2d.origin.y);
  case GZ_VALUE_TRANSFORM3D:
    return Transform3D(
        Basis(Vector3(value.data.transform3d.basis[0].x,
                      value.data.transform3d.basis[0].y,
                      value.data.transform3d.basis[0].z),
              Vector3(value.data.transform3d.basis[1].x,
                      value.data.transform3d.basis[1].y,
                      value.data.transform3d.basis[1].z),
              Vector3(value.data.transform3d.basis[2].x,
                      value.data.transform3d.basis[2].y,
                      value.data.transform3d.basis[2].z)),
        Vector3(value.data.transform3d.origin.x,
                value.data.transform3d.origin.y,
                value.data.transform3d.origin.z));
  case GZ_VALUE_RECT2:
    return Rect2(value.data.rect2.position.x, value.data.rect2.position.y,
                 value.data.rect2.size.x, value.data.rect2.size.y);
  default:
    set_valid(valid, false);
    return {};
  }
}

GzValue from_variant(const Variant &value, CharString *string_storage,
                     bool *valid) {
  GzValue result{};
  set_valid(valid, true);
  switch (value.get_type()) {
  case Variant::NIL:
    break;
  case Variant::BOOL:
    result.type = GZ_VALUE_BOOL;
    result.data.boolean = value;
    break;
  case Variant::INT:
    result.type = GZ_VALUE_INT;
    result.data.integer = value;
    break;
  case Variant::FLOAT:
    result.type = GZ_VALUE_FLOAT;
    result.data.floating = value;
    break;
  case Variant::STRING:
    if (!string_storage) {
      set_valid(valid, false);
      break;
    }
    *string_storage = String(value).utf8();
    result.type = GZ_VALUE_STRING;
    result.data.string = {string_storage->get_data(),
                          static_cast<size_t>(string_storage->length())};
    break;
  case Variant::VECTOR2: {
    Vector2 vector = value;
    result.type = GZ_VALUE_VECTOR2;
    result.data.vector2 = {static_cast<float>(vector.x),
                           static_cast<float>(vector.y)};
    break;
  }
  case Variant::OBJECT: {
    Object *object = value;
    result.type = GZ_VALUE_OBJECT;
    result.data.object_id = object ? object->get_instance_id() : 0;
    break;
  }
  case Variant::VECTOR3: {
    Vector3 vector = value;
    result.type = GZ_VALUE_VECTOR3;
    result.data.vector3 = {static_cast<float>(vector.x),
                           static_cast<float>(vector.y),
                           static_cast<float>(vector.z)};
    break;
  }
  case Variant::COLOR: {
    Color color = value;
    result.type = GZ_VALUE_COLOR;
    result.data.color = {color.r, color.g, color.b, color.a};
    break;
  }
  case Variant::TRANSFORM2D: {
    Transform2D transform = value;
    result.type = GZ_VALUE_TRANSFORM2D;
    result.data.transform2d = {
        {static_cast<float>(transform[0].x),
         static_cast<float>(transform[0].y)},
        {static_cast<float>(transform[1].x),
         static_cast<float>(transform[1].y)},
        {static_cast<float>(transform[2].x),
         static_cast<float>(transform[2].y)}};
    break;
  }
  case Variant::TRANSFORM3D: {
    Transform3D transform = value;
    result.type = GZ_VALUE_TRANSFORM3D;
    result.data.transform3d = {
        {{static_cast<float>(transform.basis[0].x),
          static_cast<float>(transform.basis[0].y),
          static_cast<float>(transform.basis[0].z)},
         {static_cast<float>(transform.basis[1].x),
          static_cast<float>(transform.basis[1].y),
          static_cast<float>(transform.basis[1].z)},
         {static_cast<float>(transform.basis[2].x),
          static_cast<float>(transform.basis[2].y),
          static_cast<float>(transform.basis[2].z)}},
        {static_cast<float>(transform.origin.x),
         static_cast<float>(transform.origin.y),
         static_cast<float>(transform.origin.z)}};
    break;
  }
  case Variant::RECT2: {
    Rect2 rect = value;
    result.type = GZ_VALUE_RECT2;
    result.data.rect2 = {{static_cast<float>(rect.position.x),
                          static_cast<float>(rect.position.y)},
                         {static_cast<float>(rect.size.x),
                          static_cast<float>(rect.size.y)}};
    break;
  }
  default:
    set_valid(valid, false);
  }
  return result;
}

Variant::Type variant_type(uint32_t type) {
  switch (type) {
  case GZ_VALUE_BOOL:
    return Variant::BOOL;
  case GZ_VALUE_INT:
    return Variant::INT;
  case GZ_VALUE_FLOAT:
    return Variant::FLOAT;
  case GZ_VALUE_STRING:
    return Variant::STRING;
  case GZ_VALUE_VECTOR2:
    return Variant::VECTOR2;
  case GZ_VALUE_OBJECT:
    return Variant::OBJECT;
  case GZ_VALUE_VECTOR3:
    return Variant::VECTOR3;
  case GZ_VALUE_COLOR:
    return Variant::COLOR;
  case GZ_VALUE_TRANSFORM2D:
    return Variant::TRANSFORM2D;
  case GZ_VALUE_TRANSFORM3D:
    return Variant::TRANSFORM3D;
  case GZ_VALUE_RECT2:
    return Variant::RECT2;
  default:
    return Variant::NIL;
  }
}

} // namespace gzscript
