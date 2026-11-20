// refcore_env.cpp: the host environment refsw3's core needs (conventions.md 7.3 L2; in refsw3-offline these come from
// refsw3-offline/main.cpp): the register block, video memory, f16, the fog / palette read hook, msgboxf, os_DebugBreak,
// pal_needs_update / fog_needs_update (TexCache.cpp). And the p2ref loaders of tb/ref/p2ref.h: video memory and
// registers from the files refsw3-offline's `save` writes (raw or gzipped: zlib's gzread reads both).
#include "types.h"
#include "hw/pvr/pvr_regs.h"
#include "hw/pvr/pvr_mem.h"

#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <zlib.h>

#include "p2ref.h"

namespace refcore {
static u8* vramStore = (u8*)calloc(1, VRAM_SIZE + 4096);
u8* emu_vram = vramStore;
}

u8 pvr_regs[pvr_RegSize];
bool pal_needs_update = true, fog_needs_update = true;

int msgboxf(const wchar* text, unsigned int type, ...)
{
    va_list args;
    va_start(args, type);
    vfprintf(stderr, text, args);
    va_end(args);
    fputc('\n', stderr);
    return 0;
}

void os_DebugBreak()
{
    fprintf(stderr, "p2ref: the renderer stopped\n");
    exit(3);
}

f32 f16(u16 v)
{
    u32 z = v << 16;
    f32 f;
    memcpy(&f, &z, 4);
    return f;
}

// refsw3-offline flags fog table and palette entries read but never written; a capture's register block counts as
// written in full (refsw3-offline's `regs`, `pvrdmp`), so there is nothing to flag here
void refsw3_offline_read(unsigned int) {}

namespace p2ref {

uint8_t* vram() { return refcore::emu_vram; }
uint8_t* regs() { return pvr_regs; }

static bool ReadAll(const char* path, std::vector<u8>& out, size_t want)
{
    gzFile f = gzopen(path, "rb");
    if (!f)
        return false;
    out.assign(want + 1, 0);
    size_t got = 0;
    for (;;) {
        int n = gzread(f, out.data() + got, (unsigned)std::min<size_t>(out.size() - got, 1u << 30));
        if (n <= 0)
            break;
        got += n;
        if (got == out.size())
            break;
    }
    gzclose(f);
    out.resize(got);
    return true;
}

bool load_vram(const char* path)
{
    std::vector<u8> b;
    if (!ReadAll(path, b, VRAM_SIZE) || b.size() != VRAM_SIZE) {
        fprintf(stderr, "p2ref: %s is not %u bytes of video memory\n", path, (unsigned)VRAM_SIZE);
        return false;
    }
    for (u32 i = 0; i < VRAM_SIZE; i += 4)
        memcpy(vrp(refcore::emu_vram, i), &b[i], 4);
    return true;
}

bool load_regs(const char* path)
{
    std::vector<u8> b;
    if (!ReadAll(path, b, 0x8000) || (b.size() != pvr_RegSize && b.size() != 0x8000)) {
        fprintf(stderr, "p2ref: %s is not a register block of %u bytes (or of the 32 KB of older builds)\n", path,
                (unsigned)pvr_RegSize);
        return false;
    }
    memcpy(pvr_regs, b.data(), pvr_RegSize);
    return true;
}

static bool Exists(const std::string& p)
{
    FILE* f = fopen(p.c_str(), "rb");
    if (f)
        fclose(f);
    return f != nullptr;
}

bool load_state(const char* dir)
{
    const std::string d = dir;
    const std::string v = Exists(d + "/vram.bin.gz") ? d + "/vram.bin.gz" : d + "/vram.bin";
    return load_vram(v.c_str()) && load_regs((d + "/pvr_regs.bin").c_str());
}

bool save_vram(const char* path)
{
    const size_t n = strlen(path);
    const bool gz = n > 3 && strcmp(path + n - 3, ".gz") == 0;
    gzFile f = gzopen(path, gz ? "wb1" : "wbT");
    if (!f)
        return false;
    bool ok = true;
    for (u32 i = 0; i < VRAM_SIZE && ok; i += 4)
        ok = gzwrite(f, vrp(refcore::emu_vram, i), 4) == 4;
    return gzclose(f) == Z_OK && ok;
}

uint32_t vram32(uint32_t addr) { return vri(refcore::emu_vram, addr); }
void set_vram32(uint32_t addr, uint32_t w) { *vrp(refcore::emu_vram, addr) = w; }

}   // namespace p2ref
