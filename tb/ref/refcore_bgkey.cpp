// refcore_bgkey.cpp: p2ref::bg_key's half that cannot see pvr_regs.h (its macro ISP_BACKGND_D is the name tb/fp's copy
// fp-bgkey, the background key block of RenderCORE, reads): L1, the refcore headers only.
#include "../fp/ref_copies.h"

pvrisp::StoredDepth p2ref_bgkey(uint32_t isp_backgnd_d) { return p2fpref::bgKey(isp_backgnd_d); }
