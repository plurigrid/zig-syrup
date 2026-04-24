# Cyton reverse-engineering prep

This note gives you a current software snapshot for the OpenBCI Cyton stack
and a repeatable local health-check path before you start any lower-level
capture, protocol work, or firmware inspection.

## Current upstream snapshot

As of April 14, 2026, the OpenBCI stack has a mix of recent application-side
updates and much older radio firmware.

- **OpenBCI GUI**:
  - Latest GitHub prerelease is `v7.0.0-alpha1`, published on November 21,
    2025. The release text says it is for debugging and technical support, and
    not for research or production use.
  - Earlier packaged GUI lines are `v6.0.0-beta.1`, published on September 28,
    2023, and `v5.2.2`, published on August 21, 2023.
- **Cyton board firmware library**:
  - Latest tag is `v3.1.5`.
  - The tagged commit landed on July 24, 2025.
  - The visible change at that tag is mostly library metadata cleanup, not a
    dramatic protocol change.
- **Cyton dongle radio firmware**:
  - Latest tag is `v2.0.4`.
  - The tagged commit landed on August 11, 2017.
  - For practical purposes, the radio side looks stable rather than actively
    moving.
- **BrainFlow**:
  - Latest upstream release is `5.21.0`, published on February 28, 2026.
  - The local host tools only require `brainflow>=5.10.0`, so there is room
    to upgrade later if you need newer board definitions or bug fixes.

## Update stance

For reverse-engineering work, don't flash Cyton or radio firmware just because
newer tags exist. OpenBCI's firmware documentation warns that bad firmware
uploads can brick hardware, and it recommends flashing only if you are an
experienced user or acting at OpenBCI support's request.

The safest prep split is:

1. Keep the Cyton board and dongle firmware unchanged unless the existing
   versions block the work.
2. Treat GUI updates as optional tooling updates, not hardware updates.
3. Consider a BrainFlow upgrade only after the low-level serial path is known
   good.

## Local health check

Use the local low-level checker before any reverse-engineering session. It
talks to the dongle directly over serial, so it remains useful even when the
GUI is not involved.

### Run the health check

From `tools/openbci_host`, run:

```bash
python3 cyton_health_check.py
```

If the dongle and board are out of sync on radio channel, run:

```bash
python3 cyton_health_check.py --autoscan-if-down
```

If you already know the dongle path, run:

```bash
python3 cyton_health_check.py --port /dev/cu.usbserial-XXXX
```

### What the checker does

The checker performs these steps:

1. Detects the most likely Cyton dongle serial port.
2. Queries radio `STATUS`.
3. Queries `GET CHANNEL`.
4. Optionally scans channels `0-25` with dongle override if the system is
   down.
5. Requests board version text with `v`.
6. Queries Daisy status with `D`.
7. Captures a short raw binary packet window.
8. Estimates packet rate, dropped packets, and per-channel signal quality.

### What a pass looks like

A healthy Cyton session usually shows:

- `system_up: true`
- a visible host and device channel
- a version response from the board
- non-zero packet count during the stream phase
- packet rate near `250 Hz`
- most channels classified as `CLEAN` or `OK`

### What to do if it fails

If the check fails, work through these fixes in order:

1. Verify the dongle switch position and make sure the dongle is plugged in
   before powering the board.
2. Confirm the board switch is in `PC` mode, not `OFF` or `BLE`.
3. Recharge or swap the battery.
4. Re-run with `--autoscan-if-down`.
5. Re-seat reference, ground, and any noisy electrodes.
6. Close the GUI or any other process that may already own the serial port.

## Official GUI cross-check

If you want to compare the local script with the official tool flow, use the
OpenBCI GUI radio panel and verify:

- **STATUS** reports `Success: System is Up`
- **GET CHANNEL** reports the same host and device channel
- **AUTOSCAN** recovers the board if the host and device are out of sync

## Sources

- [Cyton getting started guide](https://docs.openbci.com/GettingStarted/Boards/CytonGS/)
- [Firmware development guide](https://docs.openbci.com/ForDevelopers/FirmwareDevelopment/)
- [OpenBCI GUI releases](https://github.com/OpenBCI/OpenBCI_GUI/releases)
- [Cyton firmware tags](https://github.com/OpenBCI/OpenBCI_Cyton_Library/tags)
- [Cyton radio tags](https://github.com/OpenBCI/OpenBCI_Radios/tags)
- [BrainFlow releases](https://github.com/brainflow-dev/brainflow/releases)

## Next steps

After the health check passes, the next clean move is to capture one short raw
session, save the JSON report next to the capture, and only then start any
packet-level instrumentation or firmware-side experimentation.
