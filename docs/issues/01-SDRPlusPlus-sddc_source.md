# `sddc_source` (RX888 / BBRF103) is broken on GCC 14+: 11 defects, 3 of them block configure/install

Hi, and thanks for SDR++.

I spent some time getting an **RX888 MkII** (`04b4:00f1` / `04b4:00f3`) working on Linux with the in-tree `sddc_source` module. It works now, but getting there required fixing **11 defects** in `source_modules/sddc_source` — three of which make the module impossible to build or install at all, and two of which are genuine out-of-bounds writes.

While doing a full-featured build I also hit **one unrelated defect in `dab_decoder`** (one missing `&`), appended at the end as **D-1**.

Context that makes this worse than it looks: on **GCC 14+ the default standard is `-std=c23`**, so the implicit pointer conversions and implicit function declarations in the C sources are no longer warnings — they are hard errors. On any current distro (Ubuntu 24.04+, Fedora 40+, Arch…), a plain `cmake .. -DOPT_BUILD_SDDC_SOURCE=ON` fails out of the box.

Environment where I hit this: **Ubuntu 26.04.1 LTS, kernel 7.0.0, GCC 15.2.0, x86_64**, commit `8c9f5ee`.

---

## A. Blockers — configure / install / compile hard-fail

### A-1. `configure_file()` references a file that does not exist, and uses the wrong source dir

`source_modules/sddc_source/libsddc/CMakeLists.txt`:

```cmake
configure_file(${CMAKE_SOURCE_DIR}/libsddc.pc.in ${CMAKE_BINARY_DIR}/libsddc.pc @ONLY)
```

Two problems:

1. **`libsddc.pc.in` does not exist anywhere in the repository.**
2. `${CMAKE_SOURCE_DIR}` is the *top-level* SDR++ source dir, not `libsddc/`. It happens to "work" only when `libsddc` is configured as the root project — which is exactly how it was tested.

Result: `configure_file()` fails and **the entire SDR++ configure step aborts**.

```
CMake Error at source_modules/sddc_source/libsddc/CMakeLists.txt:… (configure_file):
  File .../libsddc.pc.in does not exist
```

**Fix:** add the missing `libsddc.pc.in`, and use `${CMAKE_CURRENT_SOURCE_DIR}`.

### A-2. `${CMAKE_SOURCE_DIR}` misuse again, this time breaking `make install`

Same file:

```cmake
install(DIRECTORY ${CMAKE_SOURCE_DIR}/include/ DESTINATION include/libsddc)
```

When built as part of SDR++, `${CMAKE_SOURCE_DIR}/include/` resolves to the SDR++ root `include/` (or nothing), so **`cmake --install` aborts** and *no* module after it gets installed. Standalone builds of `libsddc` work fine — which is why this went unnoticed.

**Fix:** `${CMAKE_CURRENT_SOURCE_DIR}`.

> Note: `${CMAKE_SOURCE_DIR}` vs `${CMAKE_CURRENT_SOURCE_DIR}` appears **twice** in the same file, once breaking configure, once breaking install. Worth a grep across the tree.
### A-3. 13 implicit pointer conversions → hard errors under C23

`usb_interface.c` / `sddc.c`: passing `int16_t*` and `uint32_t*` directly to `libusb_bulk_transfer()` and friends, which take `unsigned char*`.

```
error: passing argument 2 of 'libusb_bulk_transfer' from incompatible pointer type
```

These are **arrays/`int16_t` payload buffers**, i.e. deliberately reinterpreted memory — so an explicit cast is the correct fix. Please **do not** "fix" this by downgrading `-std=`; that hides the problem for everyone else.

**Fix:** add explicit `(unsigned char*)` casts at the 13 call sites.

### A-4. Missing standard headers → implicit declarations → hard errors under C23

`fx3_boot.c` and `sddc.c` use `malloc`/`realloc`/`free`, `memcpy`/`memset`, and `usleep` without including `<stdlib.h>`, `<string.h>`, `<unistd.h>`.

Under C23 an implicit function declaration is an error, and the implicit return type is `int` — which on 64-bit is exactly the kind of thing that silently corrupts pointers. Includes must be added.

### A-5. `sddc_gpio_put()` called before declaration

`sddc.c` calls `sddc_gpio_put()` before it is defined, with no forward declaration. C23 error. Needs a prototype.

---

## B. Real memory-safety bugs

### B-1. `realloc()` return value discarded → out-of-bounds write on firmware images > 64 KB

`fx3_boot.c`:

```c
realloc(buffer, size);      /* return value thrown away */
```

The pointer is never updated, so the buffer is never actually grown. Any firmware chunk beyond the original allocation writes out of bounds. The success path also leaks the buffer (no `free`).

This is reachable in normal operation — `SDDC_FX3.img` is 146268 bytes, and it is uploaded in segments.

**Fix:** capture the return value, handle failure, and `free` on the success path.

### B-2. Function declared to return `int` has no `return` statement

`sddc.c`, `sddc_gpio_set()`. Returns an indeterminate value to callers that check it.

---

## C. Module builds but is unusable

### C-1. Firmware path hardcoded to the author's Windows machine

`sddc_source/src/main.cpp`, constructor:

```cpp
sddc_set_firmware_path("C:/Users/ryzerth/Downloads/SDDC_FX3 (1).img");
```

On Linux the firmware upload can therefore never succeed. There is no fallback, no environment variable, no error surfaced to the UI.

**Suggestion:** resolve in order — env var (e.g. `SDDC_FIRMWARE`) → installed system path → source-tree path — and surface a clear error if none is found.

### C-2. Device enumeration is commented out and replaced with a hardcoded serial

Same file, `refresh()`: the real enumeration is commented out and replaced with a fixed serial number `0009072C00C40C32`. So the UI shows a device that may not exist, and never shows the one that does.

**Fix:** restore enumeration of actually-present devices.

### C-3. `moduleInstances` never declares SDDC Source or SoapySDR Source

`core/src/core.cpp` — the default `config.json`'s `moduleInstances` array contains neither `"SDDC Source"` nor `"SoapySDR Source"`.

`main_window.cpp` auto-loads every `.so` in `modulesDirectory`, but a module only appears in the Source dropdown if it is listed in `moduleInstances`. Net effect: **both RX888 routes are blocked** — the module compiles, loads, and is then invisible.

**Fix:** add both instances to the default config.

### C-4. `sddc_rx` / `sddc_info` utilities inherit the same problems

`libsddc/utils/sddc_rx/src/main.cpp` and `sddc_info/src/main.cpp`:

- hardcoded author-local firmware path and hardcoded serial number
- `sddc_rx` is an infinite `while (true)` loop with no way to exit
- it **prints the error code as if it were a sample count**

**Fix:** same enumeration/path treatment as C-1/C-2, plus a sample limit (`--samples N`) and correct error handling.

---

## D. Unrelated, found while doing a full build

### D-1. `dab_decoder` — missing `&` makes the module uncompilable

`decoder_modules/dab_decoder/src/dab_dsp.h:185`:

```cpp
#if VOLK_VERSION >= 030100
    volk_32fc_s32fc_x2_rotator2_32fc((lv_32fc_t*)_in->readBuf, (lv_32fc_t*)_in->readBuf,
                                     phaseDelta, &phase, count);
```

In the VOLK ≥ 3.1 API the third argument is `const lv_32fc_t*` — a pointer to the **phase increment**. The code passes the value, so it fails to compile:

```
error: cannot convert 'lv_32fc_t' {aka 'std::complex<float>'} to
       'const lv_32fc_t*' {aka 'const std::complex<float>*'} in argument passing
```

Compare the correct usage in `core/src/dsp/channel/frequency_xlator.h:45`, which passes `&phaseDelta`.

**Fix:** `&phaseDelta`. Note the `#else` branch below it targets the pre-3.1 API, whose signature genuinely takes the value by copy — **do not** change that one too.

The rest of the module is fine; it only includes headers that actually exist. This looks like a straight copy-paste slip from the `frequency_xlator` code.

> Related, for anyone enabling everything: `kg_sstv_decoder` and `weather_sat_decoder` include headers that **do not exist anywhere in the tree** (`dsp/demodulator.h`, `dsp/window.h`, `dsp/resampling.h`, `dsp/processing.h`, `dsp/routing.h`, `dsp/deframing.h`). They cannot compile in any environment and are OFF by default — presumably known, but worth either fixing or dropping so the options don't look usable.

---

## What I did

I fixed all of the above locally, kept every change marked with a `FIXED:` comment, and wrote a from-scratch, root-free build + verification toolchain around it:

- **Repo:** `<REPO_URL>`
- `patches/sdrpp/*.patch` — one patch per file, so each defect can be reviewed individually
- `scripts/deps-full.sh` — deploys the full dependency set without root (`apt-get download` + `dpkg-deb -x`; nothing is written to `/usr`, the dpkg database is untouched)
- `scripts/build-sdrpp-full.sh` — full build; probes each module with `pkg-config` and turns it ON/OFF accordingly instead of hardcoding flags
- `scripts/verify-device.sh` — 7-stage, 11-check end-to-end verification

## Verification

After the fixes, both routes work on real hardware:

| | native `sddc_source` | `soapy_source` + SoapySDDC |
|---|---|---|
| Device enumerated | ✅ `04b4:00f1`, firmware v2.2, 5000 Mbps | ✅ |
| Throughput | **56.4 MB/s @ 32 MSPS**, 0.0 % zero samples | 8 Msps rate test passes |

```
### 阶段 5：抓样本验出流   [通过] 8/8 buffers, sustained 56.4 MB/s, 0.0% zero values
### 阶段 6：SoapySDDC      [通过] device found + streaming at 8 Msps
汇总: 通过 11 / 失败 0 / 注意 0
```

Two related details that cost me time, for anyone else debugging this:

1. **In DFU (`b4:00f3`) the reported USB speed is meaningless.** Per Cypress **AN76405**, FX3 in USB-boot mode has **SuperSpeed disabled in hardware** — so it always reports 480 Mbps, on any port or cable, and this says nothing about port/cable quality. Only after firmware load and re-enumeration to `04b4:00f1` does `speed` mean anything.
2. **`usbfs_memory_mb` defaults to 16 MB**, which drops samples at high rates. On Ubuntu `usbcore` is built into the kernel (not a module), so `/etc/modprobe.d/` does nothing — you need `systemd-tmpfiles` with `w /sys/module/usbcore/parameters/usbfs_memory_mb - - - - 1000` in **`/etc/tmpfiles.d/`**.

I'm happy to open a PR against `sddc_source` if that's useful — the changes are self-contained and every hunk is annotated. Please let me know if you'd prefer them split differently, or if some of these (e.g. the C23 casts) are already being handled elsewhere.
