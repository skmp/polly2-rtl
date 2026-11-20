// ref_copies.h: refcore rules that no wrapper reaches (local lambdas, statics, template bodies), copied VERBATIM
// (PLAN 1.1 "copies", num 7.1). tools/check_ref_copies.sh re-extracts every copy from $(REFCORE) and fails on drift;
// every gate runs it.
//
// A copy is a block of lines between two marker lines:
//
//   // P2REF-COPY <id> <file under refcore> <anchor: the rest of the line>
//   ...the source lines, byte for byte...
//   // P2REF-END <id>
//
// The anchor is text that occurs on exactly one line of <file>, and that line is the copy's first line. The copy has
// as many lines as the block; they must equal the source's lines from the anchor's on. <id> is unique across all
// ref_copies*.h files. Code around the blocks (a wrapper function, the captures a lambda needs) is ours and is not
// checked.
//
// The copies and the milestone that adds each (PLAN 1.1): the setup part of RasterizeTriangle, CulledBySize /
// CulledByFacing (M2); the background key block of RenderCORE (M1); PtChunkTake and the PT loop (M7); the
// RenderParamTags loop (M5); MipSelect's K part (M9); the PixelFlush_tsp lambdas and the SupSample block (M10, M11);
// the put / scaler lambdas (M5, M12).
//
// M0: no copies yet.
#pragma once
