// sdk/src/engine/ms_keying.h
//
// In-process implementation of the C2 capability: keying the background out
// of an animated GIF.
//
// The Windows build drives the same pipeline through the ffmpeg CLI
// (sdk/src/gif_keying/gif_keying.cpp). HarmonyOS cannot spawn arbitrary
// executables, so the OHOS build runs the identical filter graph inside the
// process through ms_inproc_exec.h.
//
// The filter string itself is produced by the *unmodified* mask_builder.cpp
// that the Windows build uses, so both platforms execute byte-for-byte the
// same filter graph.

#ifndef MS_KEYING_H
#define MS_KEYING_H

#include <string>

#include "../../include/media_studio.h"
#include "ms_pipeline.h"

namespace ms {

// Fills the default keying options, mirroring ms_keying_options_init() in
// sdk/src/gif_keying/gif_keying.cpp.
void keying_options_init(MsKeyingOptions* opts);

// GIF -> animated GIF with the background keyed out.
//
// Pipeline (identical to sdk/src/gif_keying/gif_keying.cpp):
//   A  input.gif -> tmp.mkv   the keying chain from mask_builder.cpp,
//                             ffv1 level 3, yuva420p
//   C1 tmp.mkv   -> pal.png   palettegen
//   C2 tmp.mkv+pal -> out.gif paletteuse, loop 0
int gif_keying_inproc(const std::string& input_path,
                      const std::string& output_path,
                      const MsKeyingOptions& opts,
                      MsKeyingResult* result,
                      PipelineProgressFn progress, void* user_data);

}  // namespace ms

#endif  // MS_KEYING_H
