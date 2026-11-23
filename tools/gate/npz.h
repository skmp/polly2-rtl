// npz.h: dreamcast-tests' archived console sets read in place by C++ testbenches (PLAN 1.2 section 2): a numpy .npz
// (a zip of .npy arrays, stored or deflated: zlib) and the small top-level fields of a .cases.json. Header only; link
// with -lz.
//
//   p2npz::Npz z;  z.open(path)            the zip's central directory (zip64 not supported: the sets are small)
//   z.array(name, &arr)                     "<name>.npy": dtype ('<f8', '<f4', '<i8', '<i4', '<u4', '|b1', '|u1'), shape,
//                                           the raw little-endian data; arr.f64(i), arr.i64(i), arr.u8(i)
//   p2npz::JsonTop j;  j.parse(text)        the top-level object's scalar members as text (strings unquoted, numbers
//                                           as written); nested values are skipped. j.str(key, dflt), j.num(key, dflt)
#pragma once
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <string>
#include <vector>
#include <zlib.h>

namespace p2npz {

inline bool ReadFile(const std::string& path, std::vector<uint8_t>* out)
{
    FILE* f = fopen(path.c_str(), "rb");
    if (!f)
        return false;
    fseek(f, 0, SEEK_END);
    const long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    out->resize(n > 0 ? (size_t)n : 0);
    const bool ok = n >= 0 && fread(out->data(), 1, out->size(), f) == out->size();
    fclose(f);
    return ok;
}

struct Array {
    std::string dtype;
    std::vector<int64_t> shape;
    std::vector<uint8_t> data;
    size_t count() const
    {
        size_t n = 1;
        for (int64_t s : shape)
            n *= (size_t)s;
        return n;
    }
    int itemSize() const { return dtype.size() >= 3 ? atoi(dtype.c_str() + 2) : 0; }
    double f64(size_t i) const
    {
        if (dtype == "<f8") { double v; memcpy(&v, &data[8 * i], 8); return v; }
        if (dtype == "<f4") { float v; memcpy(&v, &data[4 * i], 4); return v; }
        return (double)i64(i);
    }
    int64_t i64(size_t i) const
    {
        if (dtype == "<i8") { int64_t v; memcpy(&v, &data[8 * i], 8); return v; }
        if (dtype == "<i4") { int32_t v; memcpy(&v, &data[4 * i], 4); return v; }
        if (dtype == "<u4") { uint32_t v; memcpy(&v, &data[4 * i], 4); return v; }   // (M10: the sets' tzbits)
        if (dtype == "|b1" || dtype == "|u1") return data[i];
        return (int64_t)f64(i);
    }
    uint8_t u8(size_t i) const { return data[i]; }
};

struct Npz {
    std::vector<uint8_t> file;
    struct Entry { uint32_t method, csize, usize, local; };
    std::map<std::string, Entry> entries;
    std::string error;

    static uint32_t U16(const uint8_t* p) { return p[0] | p[1] << 8; }
    static uint32_t U32(const uint8_t* p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }

    bool open(const std::string& path)
    {
        entries.clear();
        if (!ReadFile(path, &file) || file.size() < 22)
            return fail("cannot read " + path);
        // the end of central directory record: the last "PK\5\6"
        size_t e = file.size() - 22;
        for (;; e--) {
            if (U32(&file[e]) == 0x06054b50)
                break;
            if (e == 0 || file.size() - e > 65557)
                return fail("no end of central directory in " + path);
        }
        const uint32_t n = U16(&file[e + 10]), off = U32(&file[e + 16]);
        size_t p = off;
        for (uint32_t k = 0; k < n; k++) {
            if (p + 46 > file.size() || U32(&file[p]) != 0x02014b50)
                return fail("bad central directory in " + path);
            Entry en;
            en.method = U16(&file[p + 10]);
            en.csize = U32(&file[p + 20]);
            en.usize = U32(&file[p + 24]);
            const uint32_t nl = U16(&file[p + 28]), xl = U16(&file[p + 30]), cl = U16(&file[p + 32]);
            en.local = U32(&file[p + 42]);
            if (en.csize == 0xFFFFFFFFu || en.usize == 0xFFFFFFFFu || en.local == 0xFFFFFFFFu)
                return fail("zip64 entry in " + path);
            entries[std::string((const char*)&file[p + 46], nl)] = en;
            p += 46 + nl + xl + cl;
        }
        return true;
    }
    bool has(const std::string& name) const { return entries.count(name + ".npy") != 0; }
    bool raw(const std::string& file_name, std::vector<uint8_t>* out)
    {
        auto it = entries.find(file_name);
        if (it == entries.end())
            return fail("no " + file_name);
        const Entry& en = it->second;
        if (en.local + 30 > file.size() || U32(&file[en.local]) != 0x04034b50)
            return fail("bad local header of " + file_name);
        const size_t data = en.local + 30 + U16(&file[en.local + 26]) + U16(&file[en.local + 28]);
        if (data + en.csize > file.size())
            return fail("truncated " + file_name);
        out->resize(en.usize);
        if (en.method == 0) {
            memcpy(out->data(), &file[data], en.usize);
            return true;
        }
        if (en.method != 8)
            return fail("compression method " + std::to_string(en.method) + " of " + file_name);
        z_stream zs;
        memset(&zs, 0, sizeof zs);
        if (inflateInit2(&zs, -15) != Z_OK)
            return fail("inflateInit2");
        zs.next_in = &file[data];
        zs.avail_in = en.csize;
        zs.next_out = out->data();
        zs.avail_out = en.usize;
        const int st = inflate(&zs, Z_FINISH);
        inflateEnd(&zs);
        if (st != Z_STREAM_END || zs.total_out != en.usize)
            return fail("inflate " + file_name);
        return true;
    }
    bool array(const std::string& name, Array* a)
    {
        std::vector<uint8_t> b;
        if (!raw(name + ".npy", &b))
            return false;
        if (b.size() < 10 || memcmp(b.data(), "\x93NUMPY", 6))
            return fail(name + ": not .npy");
        const int major = b[6];
        const size_t hl = major == 1 ? U16(&b[8]) : U32(&b[8]);
        const size_t h0 = major == 1 ? 10 : 12;
        if (h0 + hl > b.size())
            return fail(name + ": header");
        const std::string h((const char*)&b[h0], hl);
        auto field = [&](const char* key) -> std::string {
            size_t p = h.find(std::string("'") + key + "'");
            if (p == std::string::npos)
                return "";
            p = h.find(':', p);
            return p == std::string::npos ? "" : h.substr(p + 1);
        };
        std::string d = field("descr");
        size_t q1 = d.find('\''), q2 = d.find('\'', q1 + 1);
        if (q1 == std::string::npos || q2 == std::string::npos)
            return fail(name + ": descr");
        a->dtype = d.substr(q1 + 1, q2 - q1 - 1);
        if (field("fortran_order").find("False") == std::string::npos)
            return fail(name + ": fortran order");
        std::string s = field("shape");
        size_t o = s.find('('), c = s.find(')');
        a->shape.clear();
        for (const char* p = s.c_str() + o + 1; p < s.c_str() + c;) {
            char* e;
            const long long v = strtoll(p, &e, 10);
            if (e == p) {
                p++;
                continue;
            }
            a->shape.push_back(v);
            p = e;
        }
        a->data.assign(b.begin() + h0 + hl, b.end());
        if (a->data.size() < a->count() * (size_t)a->itemSize())
            return fail(name + ": short data");
        return true;
    }
    bool fail(const std::string& e)
    {
        error = e;
        return false;
    }
};

// the top-level object's scalar members (strings and numbers), as text
struct JsonTop {
    std::map<std::string, std::string> v;
    bool parse(const std::string& t)
    {
        size_t i = 0;
        auto ws = [&] { while (i < t.size() && strchr(" \t\r\n", t[i])) i++; };
        auto str = [&](std::string* out) -> bool {
            if (t[i] != '"') return false;
            i++;
            std::string s;
            while (i < t.size() && t[i] != '"') {
                if (t[i] == '\\' && i + 1 < t.size()) i++;
                s += t[i++];
            }
            i++;
            if (out) *out = s;
            return true;
        };
        auto skip = [&](auto& self) -> void {      // a value of any kind
            ws();
            if (t[i] == '"') { str(nullptr); return; }
            if (t[i] == '{' || t[i] == '[') {
                const char close = t[i] == '{' ? '}' : ']';
                i++;
                for (;;) {
                    ws();
                    if (t[i] == close) { i++; return; }
                    self(self);
                    ws();
                    if (t[i] == ':') { i++; self(self); ws(); }
                    if (t[i] == ',') i++;
                }
            }
            while (i < t.size() && !strchr(",}] \t\r\n", t[i])) i++;
        };
        ws();
        if (i >= t.size() || t[i] != '{')
            return false;
        i++;
        for (;;) {
            ws();
            if (t[i] == '}')
                return true;
            std::string key;
            if (!str(&key))
                return false;
            ws();
            if (t[i++] != ':')
                return false;
            ws();
            if (t[i] == '"') {
                std::string s;
                str(&s);
                v[key] = s;
            } else if (t[i] == '{' || t[i] == '[') {
                skip(skip);
            } else {
                const size_t a = i;
                while (i < t.size() && !strchr(",} \t\r\n", t[i])) i++;
                v[key] = t.substr(a, i - a);
            }
            ws();
            if (t[i] == ',')
                i++;
        }
    }
    std::string str(const std::string& k, const std::string& d) const
    {
        auto it = v.find(k);
        return it == v.end() ? d : it->second;
    }
    double num(const std::string& k, double d) const
    {
        auto it = v.find(k);
        return it == v.end() || it->second.empty() ? d : atof(it->second.c_str());
    }
};

}   // namespace p2npz
