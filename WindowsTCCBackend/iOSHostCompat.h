#pragma once

/*
 * TinyCC's PE writer optionally invokes cv2pdb.exe through system().
 * iOS explicitly marks system() unavailable because apps cannot spawn
 * arbitrary child processes. XTool does not need that optional PDB helper,
 * so replace only the host-process launch with a deterministic failure.
 *
 * <stdlib.h> is included before defining the macro so Apple's declaration is
 * parsed normally; later TinyCC source calls are redirected to this stub.
 */
#include <stdlib.h>

static inline int xtool_ios_disabled_system(const char *command) {
    (void)command;
    return -1;
}

#define system(command) xtool_ios_disabled_system(command)
