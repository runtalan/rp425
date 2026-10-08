# rp425-driver

A small, vendor-free macOS driver for the **Rongta RP425** 4" thermal label printer.

The printer identifies itself over USB as `0FE6:8800`,
`CMD:ZPL;MODEL:RP425(ZPL 203DPI)`, firmware `RP425,V1.11`. It speaks ZPL, so the
driver is:

| Piece | What it does |
|---|---|
| `src/rastertorp425.c` | CUPS filter. Turns CUPS raster into one ZPL label per page (`^GFA` graphic, ZPL run-length compressed, typically 5–15 % of raw size). |
| `ppd/RP425.ppd` | Label sizes (4×6 default, 4×8 down to 1.5×1, metric sizes, custom up to 4.1" × 100") and options. |
| `src/rp425.swift` | `rp425` CLI that talks to the printer over USB (IOUSBHost). Doesn't need CUPS. |

macOS's built-in `usb` backend handles transport, so no backend or kext is needed.

## Install

```sh
make                 # universal (arm64 + x86_64) binaries in build/
make test            # checks the filter's compression round-trips bit-exactly
sudo make install    # filter -> /Library/Printers/RP425, PPD, /usr/local/bin/rp425
sudo make queue      # adds a CUPS queue named "RP425" for the USB printer
```

Or add it in System Settings → Printers & Scanners: pick the RP425, then
"Select Software…" → **Rongta RP425 ZPL**.

Uninstall with `sudo make uninstall`.

## Printing

```sh
lp -d RP425 label.pdf                              # 4x6 by default
lp -d RP425 -o PageSize=w288h144 label.pdf         # 4x2
lp -d RP425 -o Darkness=20 -o PrintSpeed=3 label.pdf
lp -d RP425 -o Dither=FloydSteinberg photo.png
lp -d RP425 -o raw label.zpl                       # your own ZPL, untouched
```

Options (`lpoptions -p RP425 -l` lists them all):

| Option | Values | ZPL |
|---|---|---|
| `PageSize` | `w288h432` (4×6), `w288h576`, `w288h288`, `w288h144`, … `Custom.WxHin` | `^PW` / `^LL` |
| `MediaTracking` | `Default`, `Gap`, `Mark`, `Continuous` | `^MN` |
| `Darkness` | `Default`, `0`–`30` | `~SD` |
| `PrintSpeed` | `Default`, `2`–`6` in/s | `^PR` |
| `Dither` | `Threshold` (sharp barcodes), `FloydSteinberg` (photos) | – |
| `Threshold` | `64` … `192` | – |
| `TopOffset` / `LeftOffset` | ±3 mm in 1 mm steps (dots) | `^LT` / `^LS` |
| `Rotate180` | `False`, `True` | `^POI` |
| `Compression` | `ZPL`, `None` | – |

`Default` leaves the printer's own setting alone. ZPL settings such as `^MN` stay in
effect until the printer is power-cycled.

## Settings UI

```sh
make ui     # or: python3 ui/server.py [--queue RP425] [--port 8425]
```

Opens a local page (127.0.0.1 only) with every option from the queue's PPD: label size
(including custom sizes), media tracking, darkness, speed, dither/threshold, offsets,
rotation and compression. "Save as my defaults" writes them to `~/.cups/lpoptions`.
The page also runs the `rp425` actions (calibrate, feed, config label, cancel) and can
print a file with the values currently on screen. It needs only the system Python.

## The `rp425` tool

```sh
rp425 info          # USB device ID and firmware
rp425 calibrate     # re-measure label/gap length (~JC); do this after changing stock
rp425 feed          # feed one label (~PH)
rp425 config        # print the configuration label (~WC)
rp425 send x.zpl    # raw ZPL straight to USB, bypassing CUPS (`-` reads stdin)
rp425 cancel        # flush the printer's buffer (~JA)
rp425 status        # ~HS, on firmware that answers it
```

`rp425` opens the USB interface directly, so it can't run while a CUPS job is
using the printer.

## Settings UI

```sh
make ui        # or: python3 ui/rp425-ui.py [--printer RP425] [--port 8425]
```

Opens a page on `127.0.0.1:8425` with every option from the table above, plus the
`rp425` actions (test label, feed, calibrate, config label, flush), a raw-ZPL box, and a
custom label size. Changes are saved as your own defaults for the queue
(`lpoptions`, in `~/.cups/lpoptions`, no root needed); "Reset to defaults" removes them.
It uses only the Python standard library and talks to the printer through CUPS, so the
printer actions that use USB directly (`feed`, `calibrate`, `config`, `info`) fail while
a CUPS job is holding the printer.

## Firmware quirks found while probing (V1.11)

- `MFG` in the 1284 device ID is empty and the model is sent as `MODEL` rather than
  `MDL`, so macOS lists the printer as "Unknown" and probably won't auto-select this
  driver. Choose it by hand, or use `sudo make queue`.
- It answers `~HI`, but not `~HS`, `~HQES`, `~HD`, `^HH`, or the USB printer-class
  `GET_PORT_STATUS` request (stalls). So there's no paper-out/head-open status over USB.
- Bulk-IN reads that time out leave the pipe out of sync for the next process;
  `rp425` clears both pipes on open.

## Development

`make test-print` encodes `test/mkpdf.swift`'s test label and sends it straight to
the printer without installing anything. `build/rastertorp425 1 user title 1 "" file.ras`
runs the filter by hand. Get a raster file with
`cupsfilter -p ppd/RP425.ppd -m application/vnd.cups-raster in.pdf > in.ras`.
