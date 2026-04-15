// Forwarding header that exposes glslang's default resource-limits entry points
// to Swift through the Cglslang module, without symlinking the upstream
// `glslang/Public/resource_limits_c.h` (which uses a parent-relative quote-form
// `#include "../Include/glslang_c_interface.h"` that clang cannot resolve
// through our shim directory — see card 2's finding in
// docs/skins/07-shader-pipeline-plan.md §"Architectural lessons from cards 1
// and 2").
//
// The symbols declared below are compiled into the Cglslang target via
// `glslang/ResourceLimits/resource_limits_c.cpp` (listed in Package.swift's
// Cglslang source list). Re-declaring the prototypes here is sufficient for
// Swift to call them; the linker resolves them against the already-compiled
// objects.
#ifndef HOLOSCAPE_CGLSLANG_RESOURCE_LIMITS_H
#define HOLOSCAPE_CGLSLANG_RESOURCE_LIMITS_H

#include "glslang_c_interface.h"

#ifdef __cplusplus
extern "C" {
#endif

const glslang_resource_t* glslang_default_resource(void);
const char* glslang_default_resource_string(void);

#ifdef __cplusplus
}
#endif

#endif
