# Windows: `usb_device_open()` gives up 500 ms after firmware upload — cold start fails with `usb_device@0 not found`

Hi,

Cold-starting an **RX888 MkII** with the SoapySDDC plugin fails reliably on Linux:

```
normal FW binary executable image with checksum
FX3 bootloader version: 0x000000A9
writing image...
transfer execution to Program Entry at 0x40012cfc
ERROR - usb_device@0 not found          <-- right here
```

Firmware upload clearly **succeeded** — the log says the execution was transferred — and then the device is reported as missing. That is extremely misleading and it is a one-line-strategy problem, not a hardware problem.

## Root cause

`Core/arch/linux/usb_device.c`, in `usb_device_open()`:

```c
/* rescan USB to get a new device handle */
libusb_close(dev_handle);
usleep(500 * 1000L);                                    /* fixed 500 ms     */
dev_handle = find_usb_device(index, ctx, &device, &needs_firmware);  /* scan once */
```

Two independent problems:

1. **500 ms is not enough.** After the FX3 boots the uploaded firmware it re-enumerates (ReNumeration, `04b4:00f3` → `04b4:00f1`). On this machine that takes longer than 500 ms, and the device even **comes back on a different bus** (Bus 003 → Bus 004).

2. **The scan is done exactly once, and against a cached list.** `libusb_get_device_list()` returns libusb's internally cached device list. It is not refreshed by wall-clock time alone — you have to pump hotplug events (`libusb_handle_events*()`) before re-listing. So even if the device has already re-appeared, a single scan taken right after a bare `usleep()` will miss it.

The combination means the retry can never succeed by luck; it has to be a real poll loop.

## Suggested fix

Replace the single sleep-and-scan with a bounded poll that pumps hotplug events each round:

```c
/* Poll for the runtime (non-bootloader) device: the FX3 needs an
 * unpredictable amount of time to re-enumerate after the firmware starts,
 * and libusb_get_device_list() only reflects hotplug events we have pumped. */
static int wait_for_runtime_device(libusb_context* ctx, int timeout_ms) {
    const int step_ms = 250;
    for (int waited = 0; waited < timeout_ms; waited += step_ms) {
        struct timeval zero_tv = {0, 0};
        libusb_handle_events_timeout_completed(ctx, &zero_tv, NULL);  /* pump hotplug */
        /* … re-scan, return on a device with needs_firmware == 0 … */
        usleep(step_ms * 1000L);
    }
    return 0;
}
```

In my testing a 250 ms step with a 20 s ceiling resolves it on the first or second iteration.

For reference, the in-tree `libsddc` solves the same problem differently — `SDDC_INIT_SEARCH_DELAY_MS = 1000` **and then re-lists**. That is why the native path always worked and only this one broke. Two libraries, same hardware, different wait strategy: one works, one doesn't.

## Verification after the fix (+60 / −2 lines in `usb_device.c`)

| Scenario | Result |
|---|---|
| Cold start (DFU → upload → stream) | ✅ `7.87992 Msps / 63.0393 MBps` |
| Warm start (device already in runtime mode) | ✅ `7.77687 Msps / 62.215 MBps` |
| `libsddc` used first, then SoapySDDC immediately after | ✅ passes |

Tested on Ubuntu 26.04.1 LTS / kernel 7.0.0 / GCC 15.2.0, device `04b4:00f1`, firmware v2.2.

## Patch

The change is in `<REPO_URL>` under `patches/extio_sddc/ALL-ExtIO_sddc.patch`, and there is a standalone end-to-end verification script (`scripts/verify-device.sh`) that exercises the cold-start path.

One more thing worth documenting for anyone using SoapySDDC: the factory name is registered as **uppercase `SDDC`** (`Registry registerSDDC("SDDC", …)`), and SoapySDR's `driver=` match is case-sensitive:

```
SoapySDRUtil --probe="driver=sddc"   # Error probing device: no match   <-- looks like a missing device
SoapySDRUtil --probe="driver=SDDC"   # works, prints full device capabilities
```

That one costs people a lot of time debugging a device that is plugged in fine. Happy to send a PR for the `usb_device.c` fix if you'd like it.
