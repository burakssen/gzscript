#include "register_types.hpp"

#include "gz_build_manager.hpp"
#include "gz_language.hpp"
#include "gz_resource_format.hpp"
#include "gz_script.hpp"

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/resource_loader.hpp>
#include <godot_cpp/classes/resource_saver.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/memory.hpp>

using namespace godot;

namespace {
GzLanguage *language = nullptr;
GzBuildManager *build_manager = nullptr;
Ref<GzResourceLoader> resource_loader;
Ref<GzResourceSaver> resource_saver;
} // namespace

void initialize_gzscript_module(ModuleInitializationLevel level) {
  if (level == MODULE_INITIALIZATION_LEVEL_EDITOR) {
    return;
  }

  if (level != MODULE_INITIALIZATION_LEVEL_SCENE) {
    return;
  }

  GDREGISTER_CLASS(GzBuildManager);
  GDREGISTER_CLASS(GzLanguage);
  GDREGISTER_CLASS(GzScript);
  GDREGISTER_CLASS(GzResourceLoader);
  GDREGISTER_CLASS(GzResourceSaver);

  build_manager = memnew(GzBuildManager);
  language = memnew(GzLanguage);
  Engine::get_singleton()->register_singleton("GzBuildManager", build_manager);
  Engine::get_singleton()->register_script_language(language);

  resource_loader.instantiate();
  resource_saver.instantiate();
  ResourceLoader::get_singleton()->add_resource_format_loader(resource_loader,
                                                              true);
  ResourceSaver::get_singleton()->add_resource_format_saver(resource_saver,
                                                             true);
}

void uninitialize_gzscript_module(ModuleInitializationLevel level) {
  if (level == MODULE_INITIALIZATION_LEVEL_EDITOR) {
    return;
  }

  if (level != MODULE_INITIALIZATION_LEVEL_SCENE) {
    return;
  }

  if (ResourceSaver *rs = ResourceSaver::get_singleton()) {
    rs->remove_resource_format_saver(resource_saver);
  }
  if (ResourceLoader *rl = ResourceLoader::get_singleton()) {
    rl->remove_resource_format_loader(resource_loader);
  }
  resource_saver.unref();
  resource_loader.unref();

  if (Engine *engine = Engine::get_singleton()) {
    engine->unregister_script_language(language);
    engine->unregister_singleton("GzBuildManager");
  }
  if (language) {
    memdelete(language);
    language = nullptr;
  }
  if (build_manager) {
    memdelete(build_manager);
    build_manager = nullptr;
  }
}

extern "C" {
GDExtensionBool GDE_EXPORT
gzscript_library_init(GDExtensionInterfaceGetProcAddress get_proc_address,
                      GDExtensionClassLibraryPtr library,
                      GDExtensionInitialization *initialization) {
  GDExtensionBinding::InitObject init(get_proc_address, library,
                                      initialization);
  init.register_initializer(initialize_gzscript_module);
  init.register_terminator(uninitialize_gzscript_module);
  init.set_minimum_library_initialization_level(
      MODULE_INITIALIZATION_LEVEL_SCENE);
  return init.init();
}
}
