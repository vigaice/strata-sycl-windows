// src/core/device_info_main.cpp - `strata-device` for the Windows SYCL component: the card list setup reads, as JSON.
//
// The CUDA and HIP builds have src/core/device_main.cpp, which prints the plan and the arena for a human.  The
// Windows Intel component has no engine-side plan to print before a model is loaded, and its setup asks a different
// question: which Intel adapter is behind each display adapter, so the selected card can be matched to the ordinal
// ONEAPI_DEVICE_SELECTOR wants.  setup_windows.py (devices()) reads this program's stdout as
//
//   {"devices": [{"index": 0, "name": "...", "memory_bytes": N, "integrated": false, "vendor_id": 32902,
//                 "device_id": 57867, "pci_address": "0000:03:00.0", "uuid": "<32 hex>",
//                 "usm_host": true, "usm_device": true, "alchemist": false}]}
//
// and fails the install when memory_bytes is not a positive int, or usm_host / usm_device is false: both are what
// the expert pools need.  Keep the keys and their order as they are - a missing key reads as "the engine cannot
// describe this card".
//
// `--list-devices` prints the same table one line per card for a human; `--selftest` allocates host and device USM
// and drops it again, which is the check setup runs after installing a package.
#include <sycl/sycl.hpp>

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace {

// JSON string escaping: the device name is driver text ("Intel(R) Arc(TM) B580 Graphics"), and a driver that prints
// a quote or a backslash must not break the document setup parses.
std::string json_string(const std::string& s) {
    std::string out;
    out.reserve(s.size() + 2);
    out.push_back('"');
    for (const char c : s) {
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if ((unsigned char) c < 0x20) {
                    char buf[8];
                    std::snprintf(buf, sizeof(buf), "\\u%04x", (unsigned) (unsigned char) c);
                    out += buf;
                } else {
                    out.push_back(c);
                }
        }
    }
    out.push_back('"');
    return out;
}

struct Card {
    unsigned index = 0;
    std::string name;
    std::uint64_t memory_bytes = 0;
    bool integrated = false;
    unsigned vendor_id = 0;
    unsigned device_id = 0;
    std::string pci_address;
    std::string uuid;
    bool usm_host = false;
    bool usm_device = false;
    bool alchemist = false;
};

// DG2 / Alchemist's PCI ids (0x5690-0x56C1 on the desktop cards, 0x4F80-0x4F9F on the mobile ones).  setup.py sets
// IGC_EnableDPEmulation and OverrideDefaultFP64Settings for these cards, and takes the field only when it is a bool.
bool is_alchemist(unsigned device_id) {
    return (device_id >= 0x5690 && device_id <= 0x56C1) || (device_id >= 0x4F80 && device_id <= 0x4F9F);
}

// Each field is asked for on its own: the extensions below are Intel's, and a driver that answers for the card but
// not for one key should still produce a card setup can read (the missing key then reads as its own default).
template <typename Fn>
auto ask(Fn fn) noexcept -> decltype(fn()) {
    try {
        return fn();
    } catch (...) {
        return decltype(fn()){};
    }
}

Card describe(const sycl::device& d, unsigned index) {
    Card c;
    c.index = index;
    c.name = ask([&] { return d.get_info<sycl::info::device::name>(); });
    c.memory_bytes = ask([&] { return (std::uint64_t) d.get_info<sycl::info::device::global_mem_size>(); });
    c.integrated = ask([&] { return (bool) d.get_info<sycl::info::device::host_unified_memory>(); });
    c.usm_host = ask([&] { return (bool) d.get_info<sycl::info::device::usm_host_allocations>(); });
    c.usm_device = ask([&] { return (bool) d.get_info<sycl::info::device::usm_device_allocations>(); });
    c.vendor_id = ask([&] { return (unsigned) d.get_info<sycl::info::device::vendor_id>(); });
    namespace iinfo = sycl::ext::intel::info::device;
    c.device_id = ask([&] { return (unsigned) d.get_info<iinfo::device_id>(); });
    c.alchemist = is_alchemist(c.device_id);
    // "0000:03:00.0": the runtime already spells it the way setup.py's intel_pci_address() parses, and the way a
    // user sees it in Device Manager.
    c.pci_address = ask([&] { return d.get_info<iinfo::pci_address>(); });
    // Intel's UUID is 16 bytes; setup.py's intel_uuid() takes the 32 hex digits, lower case.
    const auto uuid = ask([&] { return d.get_info<iinfo::uuid>(); });
    static const char* kHex = "0123456789abcdef";
    for (const unsigned char b : uuid) {
        c.uuid.push_back(kHex[b >> 4]);
        c.uuid.push_back(kHex[b & 0xf]);
    }
    return c;
}

// The card appears twice without a selector on this machine: oneAPI ships ur_adapter_level_zero.dll and
// ur_adapter_level_zero_v2.dll, each a SYCL platform of its own, and sycl::device::get_devices() unions them - the
// same B580 listed twice with the same UUID and PCI address.  setup.py's select_device() refuses a card it cannot
// identify uniquely (len(matches) != 1), so this program reports each card once, numbered the way
// ONEAPI_DEVICE_SELECTOR numbers them: 0..n-1 inside one platform (measured: level_zero:1 selects nothing here,
// level_zero:0 selects the card).  Walking the platforms gives both at once - the first platform with a GPU answers,
// and the second adapter is never asked.
std::vector<sycl::device> gpu_devices() {
    std::vector<sycl::device> out;
    try {
        for (const sycl::platform& p : sycl::platform::get_platforms()) {
            auto devs = p.get_devices(sycl::info::device_type::gpu);
            if (devs.empty()) continue;
            out = std::move(devs);
            break;
        }
    } catch (...) {
        out.clear();
    }
    if (!out.empty()) return out;
    // No platform answered: the flat list, de-duplicated by the caller.
    try {
        for (const sycl::device& d : sycl::device::get_devices(sycl::info::device_type::gpu)) out.push_back(d);
    } catch (...) {
        // A host with no Level Zero runtime answers with an exception rather than an empty list: no cards, not a crash.
    }
    return out;
}

// The same card reached through two adapters, or through two platforms, is one card: keep the first, renumber so the
// indexes stay the ONEAPI_DEVICE_SELECTOR ordinals.  A UUID of all zeros (a driver that has none) falls back to the
// PCI address, then to the name.
std::vector<Card> unique_cards(std::vector<Card> cards) {
    std::vector<Card> out;
    std::vector<std::string> seen;
    for (Card& c : cards) {
        const std::string key = c.uuid.find_first_not_of('0') != std::string::npos
                                    ? c.uuid
                                    : (c.pci_address.empty() ? c.name : c.pci_address + "|" + c.name);
        bool duplicate = false;
        for (const std::string& s : seen) duplicate = duplicate || s == key;
        if (duplicate) continue;
        seen.push_back(key);
        c.index = (unsigned) out.size();
        out.push_back(std::move(c));
    }
    return out;
}

bool selftest() {
    const auto gpus = gpu_devices();
    if (gpus.empty()) {
        std::fprintf(stderr, "strata-device: no GPU the runtime can open\n");
        return false;
    }
    try {
        sycl::queue q(gpus.front(), sycl::property::queue::in_order());
        int* host = sycl::malloc_host<int>(1, q);
        int* device = sycl::malloc_device<int>(1, q);
        if (host == nullptr || device == nullptr) {
            std::fprintf(stderr, "strata-device: USM allocation failed (host %p, device %p)\n", (void*) host,
                         (void*) device);
            if (host) sycl::free(host, q);
            if (device) sycl::free(device, q);
            return false;
        }
        *host = 41;
        q.memcpy(device, host, sizeof(int)).wait_and_throw();
        q.single_task([device] { *device += 1; }).wait_and_throw();
        q.memcpy(host, device, sizeof(int)).wait_and_throw();
        const bool ok = *host == 42;
        sycl::free(host, q);
        sycl::free(device, q);
        if (!ok) std::fprintf(stderr, "strata-device: the readback was %d, expected 42\n", *host);
        return ok;
    } catch (const std::exception& e) {
        std::fprintf(stderr, "strata-device: %s\n", e.what());
        return false;
    }
}

void usage() {
    std::printf("usage: strata-device [--list-devices] [--selftest] [--help]\n"
                "  (no argument)   the card list as JSON, the form setup reads\n"
                "  --list-devices  the same cards, one line each, numbered as ONEAPI_DEVICE_SELECTOR numbers them\n"
                "  --selftest      allocate USM on the first card, round-trip one int, free it\n");
}

}  // namespace

int main(int argc, char** argv) {
    bool list = false;
    bool selftest_flag = false;
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--list-devices") == 0) list = true;
        else if (std::strcmp(argv[i], "--selftest") == 0) selftest_flag = true;
        else if (std::strcmp(argv[i], "--help") == 0 || std::strcmp(argv[i], "-h") == 0) {
            usage();
            return 0;
        } else {
            std::fprintf(stderr, "unknown argument: %s\n", argv[i]);
            usage();
            return 2;
        }
    }
    if (selftest_flag) {
        if (!selftest()) return 1;
        std::printf("strata-device selftest OK\n");
        return 0;
    }

    const auto gpus = gpu_devices();
    std::vector<Card> cards;
    cards.reserve(gpus.size());
    for (std::size_t i = 0; i < gpus.size(); ++i) cards.push_back(describe(gpus[i], (unsigned) i));

    if (list) {
        if (cards.empty()) std::printf("(no GPU device)\n");
        for (const Card& c : cards) {
            std::printf("device %u: %s\n", c.index, c.name.c_str());
            std::printf("  %.3f GiB (%llu B), integrated %s, vendor 0x%04x, device 0x%04x, %s%s\n",
                        (double) c.memory_bytes / (1024.0 * 1024 * 1024), (unsigned long long) c.memory_bytes,
                        c.integrated ? "yes" : "no", c.vendor_id, c.device_id, c.pci_address.c_str(),
                        c.alchemist ? ", alchemist" : "");
        }
        return 0;
    }

    std::printf("{\"devices\":[");
    for (std::size_t i = 0; i < cards.size(); ++i) {
        const Card& c = cards[i];
        if (i != 0) std::printf(",");
        std::printf("{\"index\":%u,\"name\":%s,\"memory_bytes\":%llu,\"integrated\":%s,\"vendor_id\":%u,"
                    "\"device_id\":%u,\"pci_address\":%s,\"uuid\":%s,\"usm_host\":%s,\"usm_device\":%s,"
                    "\"alchemist\":%s}",
                    c.index, json_string(c.name).c_str(), (unsigned long long) c.memory_bytes,
                    c.integrated ? "true" : "false", c.vendor_id, c.device_id,
                    json_string(c.pci_address).c_str(), json_string(c.uuid).c_str(), c.usm_host ? "true" : "false",
                    c.usm_device ? "true" : "false", c.alchemist ? "true" : "false");
    }
    std::printf("]}\n");
    std::fflush(stdout);
    return 0;
}
