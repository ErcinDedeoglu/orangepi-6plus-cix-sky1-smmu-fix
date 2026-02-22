# ARM SMMU v3 Event Queue Fix for CIX Sky1 / CD8180 SoC

**Fix for system freezes, SSH hangs, and network unresponsiveness on Orange Pi 6 Plus, Radxa Orion O6, and other CIX Sky1-based boards**

## TL;DR

The CIX Sky1 (CD8180) SoC has a **firmware bug in its UEFI ACPI IORT tables** that causes an ARM SMMU v3 interrupt storm (~130 IRQs/sec on CPU0). Over time, this starves the network stack, causing SSH to become unresponsive, network connectivity to drop, and eventually requiring a hard power cycle.

This repository provides a **targeted fix** that disables the SMMU event queue -- stopping the interrupt storm while keeping all PCIe devices and DMA fully functional.

```bash
# Quick install (run as root)
git clone https://github.com/ErcinDedeoglu/orangepi-6plus-cix-sky1-smmu-fix.git
cd orangepi-6plus-cix-sky1-smmu-fix
sudo ./install.sh
```

---

## Table of Contents

- [Symptoms](#symptoms)
- [Affected Boards](#affected-boards)
- [Root Cause Analysis](#root-cause-analysis)
  - [The SMMU Event Storm](#the-smmu-event-storm)
  - [Why It Happens -- Broken IORT Stream Tables](#why-it-happens----broken-iort-stream-tables)
  - [SMMU Hardware Details](#smmu-hardware-details)
  - [Affected PCIe Devices](#affected-pcie-devices)
- [Community Reports -- Same Root Cause, Different Symptoms](#community-reports----same-root-cause-different-symptoms)
- [What We Tried (and What Failed)](#what-we-tried-and-what-failed)
- [The Fix](#the-fix)
  - [What It Does](#what-it-does)
  - [Why It's Safe](#why-its-safe)
  - [Installation](#installation)
  - [Manual Application](#manual-application)
  - [Verification](#verification)
  - [Uninstallation](#uninstallation)
- [Technical Deep Dive](#technical-deep-dive)
  - [ARM SMMU v3 Architecture](#arm-smmu-v3-architecture)
  - [CR0 Register Layout](#cr0-register-layout)
  - [The Interrupt Path](#the-interrupt-path)
  - [Why CPU0 Gets Starved](#why-cpu0-gets-starved)
- [Test Environment](#test-environment)
- [For Orange Pi / CIX Engineers](#for-orange-pi--cix-engineers)
- [License](#license)

---

## Symptoms

If you're experiencing any of these on a CIX Sky1-based board, this fix is likely relevant:

- **System becomes unresponsive** after minutes, hours, or days of operation
- **SSH sessions freeze** -- no response, eventual timeout
- **Network connectivity drops** -- can't ping the board, but it's still running
- **Requires hard power cycle** to recover (soft reboot may not work)
- **System works fine for a while** then gradually degrades
- **PCIe devices cause instability** -- especially at Gen4 speeds
- **High CPU0 usage** from interrupt handling (visible in `top` or `/proc/interrupts`)
- **dmesg flooded** with `arm-smmu-v3` event 0x07 messages

### How to Confirm

Run this command to check if you have the SMMU interrupt storm:

```bash
# Check if IRQ 13 (arm-smmu-v3-evtq) is incrementing rapidly
watch -n 1 'grep arm-smmu-v3-evtq /proc/interrupts'
```

If the counter for `arm-smmu-v3-evtq` on `GICv3 107` is increasing by ~130 per second, you have this bug.

You can also check dmesg:

```bash
dmesg | grep -c 'event 0x07'
```

If this returns a large number (thousands+), the SMMU is continuously logging bogus events.

---

## Affected Boards

This issue affects **all boards using the CIX Sky1 (CD8180) SoC** with stock UEFI firmware:

| Board | SoC | Status |
|-------|-----|--------|
| **Orange Pi 6 Plus** | CIX Sky1 / CD8180 | Confirmed affected (BIOS v1.3 and v1.4) |
| **Radxa Orion O6** | CIX Sky1 / CD8180 | Reported PCIe freezes (same root cause) |
| **FunKey CIX P1** | CIX Sky1 / CD8180 | Likely affected (same SoC/firmware) |
| Any future CIX Sky1 board | CIX Sky1 / CD8180 | Likely affected until firmware is fixed |

---

## Root Cause Analysis

### The SMMU Event Storm

The ARM System Memory Management Unit (SMMU) v3 is the IOMMU on ARM platforms -- it translates DMA addresses for PCIe devices, similar to Intel's VT-d.

On the CIX Sky1 SoC, the SMMU's **event queue** continuously receives error events from every PCIe DMA transaction. Each event triggers an interrupt (IRQ 13, GICv3 107) on CPU0. At ~130 events per second, this creates a sustained interrupt storm that:

1. **Consumes CPU0 cycles** handling bogus interrupts
2. **Floods the kernel log** with SMMU event messages
3. **Competes with network softirqs** that are also pinned to CPU0
4. **Eventually starves the network stack**, causing TCP timeouts and SSH hangs
5. **Leads to complete unresponsiveness** requiring a hard power cycle

### Why It Happens -- Broken IORT Stream Tables

The UEFI firmware defines **IORT (IO Remapping Table)** entries in ACPI that tell the SMMU how to map PCIe device Stream IDs to translation contexts. The CIX Sky1 firmware has a critical defect:

- The SMMU instance 0 uses a **2-level stream table** that is configured to cover only **25 out of 32 bits** of the Stream ID space
- PCIe devices present Stream IDs that **fall outside this truncated mapping**
- Every DMA transaction from these devices generates an **event 0x07 (C_BAD_STREAMID)** -- the SMMU doesn't recognize the device
- Despite the errors, DMA still works because `arm-smmu-v3.disable_bypass=0` allows unmapped transactions to pass through

The events are pure noise -- they indicate a firmware configuration error, not actual DMA problems. But the kernel faithfully processes each event, fires the IRQ handler, logs the error, and wastes CPU cycles.

### SMMU Hardware Details

The CIX Sky1 has **two SMMU v3 instances**:

| Instance | Base Address | MMIO Range | IRQ | Function |
|----------|-------------|------------|-----|----------|
| **SMMU 0** | `0x0b010000` | `0x0b010000 - 0x0b02ffff` | IRQ 13 (GICv3 107) | **PCIe IOMMU -- the offender** |
| SMMU 1 | `0x0b1b0000` | `0x0b1b0000 - 0x0b1cffff` | IRQ 17 (GICv3 141) | Other peripherals -- quiet, zero events |

Key registers for SMMU instance 0:

| Register | Address | Description |
|----------|---------|-------------|
| CR0 | `0x0b010020` | Control Register 0 -- contains EVTQEN (bit 2) |
| CR0ACK | `0x0b010024` | CR0 acknowledgement register |
| STRTAB_BASE | `0x0b010080` | Stream table base address |
| STRTAB_BASE_CFG | `0x0b010088` | Stream table configuration |
| EVTQ_BASE | `0x0b0100a0` | Event queue base address |
| EVTQ_PROD | `0x0b0100a8` | Event queue producer index |
| EVTQ_CONS | `0x0b0100ac` | Event queue consumer index |

### Affected PCIe Devices

All PCIe devices on the CIX Sky1 generate SMMU events because the IORT mapping is broken at the firmware level. Observed Stream IDs:

| Stream ID | PCI BDF | Device | Description |
|-----------|---------|--------|-------------|
| `0x0100` | `01:00.0` | Intel BE200 [8086:272b] | Wi-Fi 7 (802.11be) |
| `0x6100` | `61:00.0` | Realtek RTL8126 [10ec:8126] | 5GbE Ethernet -- **highest event rate** |
| `0x3100` | `31:00.0` | Realtek RTL8126 [10ec:8126] | 5GbE Ethernet |
| `0x9100` | `91:00.0` | WD SN5000 [15b7:5045] | NVMe SSD |
| `0xc100` | `c1:00.0` | WD SN5000 [15b7:5045] | NVMe SSD |

---

## Community Reports -- Same Root Cause, Different Symptoms

Multiple sources document the same underlying issue, though none have traced it to the SMMU event queue level:

### 1. BredOS Wiki -- Orion O6

The [BredOS wiki for the Orion O6](https://wiki.bredos.org/devices/orion-o6/) explicitly states:

> - "**PCIe: Freezes the entire system sometimes**"
> - "Some testers have found that the **system becomes unstable when a device operating at PCIe Gen. 4 speeds** is connected"

Their workaround: Updated their own **custom UEFI firmware** and recommend **limiting PCIe link speed to Gen 3**.

The BredOS team building their own UEFI firmware fork strongly suggests they identified ACPI/IORT issues in the stock CIX firmware.

### 2. Radxa Forum -- PCIe Instability

Radxa forum users report:
- PCIe devices causing **boot failures**
- **GPU detection failures** on the x8 PCIe slot
- **System instability** with certain PCIe cards
- An **EC firmware bug** where PCIe ports retained power even when the board was powered off (acknowledged by Radxa)

### 3. Jeff Geerling's SBC Review

Jeff Geerling's review of CIX Sky1-based boards documents:
- **PCIe issues** with certain devices
- **USB problems**
- General **stability concerns**

### 4. Armbian Forum

The Armbian project labels CIX Sky1 support as **alpha**, with community reports of:
- System instability
- PCIe-related crashes
- Network connectivity issues

### What Nobody Has Publicly Documented Until Now

- The specific **SMMU event 0x07 (C_BAD_STREAMID)** interrupt storm
- The **~130 IRQ/sec on CPU0** from broken IORT stream table mappings
- That this eventually **starves the network stack** and causes SSH/network hangs
- The **2-level stream table covering only 25/32 SID bits** as the root configuration error
- A **targeted fix** that addresses the root cause without disabling PCIe or downgrading link speed

Other users are experiencing the same symptoms (freezes, PCIe instability) but attributing them to vague "PCIe Gen4 issues" or "firmware bugs" without identifying the specific mechanism.

---

## What We Tried (and What Failed)

During our investigation, we tested several approaches before arriving at the current fix:

### 1. `iommu.passthrough=1` kernel parameter

**Result: System wouldn't boot (black screen)**

This puts all devices into IOMMU passthrough mode, bypassing the SMMU entirely. However, the CIX Sky1's GPU also goes through the SMMU, and passthrough mode broke display initialization.

### 2. Per-device IOMMU identity domain mode

**Result: Crashed the system**

We tried changing individual IOMMU group types to `identity` (bypass) mode:
1. Unbind the device driver
2. Change `/sys/kernel/iommu_groups/<N>/type` to `identity`
3. Rebind the driver

This worked for the Wi-Fi adapter but **crashed the system** when attempted on the Realtek Ethernet controller (the biggest event source). The driver unbind/rebind sequence appears to be unsafe for this platform.

### 3. Moving the IRQ to a different CPU

**Result: Interrupt moved, but still fires at same rate**

```bash
echo 1 > /proc/irq/13/smp_affinity_list
```

The IRQ successfully moved to CPU1, but the event queue still fires at ~130/sec. This just moves the problem to a different CPU -- doesn't solve it.

### 4. BIOS update (v1.3 to v1.4)

**Result: No change to SMMU issue**

We updated the Orange Pi 6 Plus BIOS from v1.3 to v1.4 (released January 2026). The SMMU event storm continued at the same rate -- the IORT tables were not fixed in this update.

---

## The Fix

### What It Does

The fix disables the SMMU event queue on instance 0 by clearing bit 2 (**EVTQEN**) in the **CR0 register** at physical address `0x0b010020`.

This is done by writing directly to the SMMU's memory-mapped register using `devmem2`:

```
CR0 value: 0x1D (binary: 0001 1101) -- EVTQEN is set (bit 2 = 1)
                                          |
                                          v
CR0 value: 0x19 (binary: 0001 1001) -- EVTQEN cleared (bit 2 = 0)
```

### Why It's Safe

1. **The event queue is only for error logging**, not DMA data flow. Disabling it is like turning off a fire alarm that's been triggered by steam -- the actual kitchen continues working fine.

2. **DMA continues working normally**. The `arm-smmu-v3.disable_bypass=0` boot parameter (default on these boards) ensures that DMA transactions from unmapped Stream IDs pass through without translation. This is the actual data path -- it's unaffected by the event queue state.

3. **All PCIe devices remain fully functional** -- Wi-Fi, Ethernet, NVMe, GPU -- all continue to operate normally after the fix.

4. **The kernel SMMU driver stays in sync**. The `arm-smmu-v3` driver's event queue thread (`irq/13-arm-smmu`) simply never gets woken up because the hardware no longer generates the interrupt. The thread remains idle -- no kernel modifications needed.

5. **You only lose SMMU error reporting**, which in this case is 100% noise from firmware bugs. There are no legitimate SMMU errors being masked.

6. **Instantly reversible**. A reboot restores the default firmware state. The fix must be re-applied each boot (which the included systemd service handles automatically).

### Installation

```bash
git clone https://github.com/ErcinDedeoglu/orangepi-6plus-cix-sky1-smmu-fix.git
cd orangepi-6plus-cix-sky1-smmu-fix
sudo ./install.sh
```

The install script will:
1. Install `devmem2` if not already present
2. Copy `smmu-evtq-fix.sh` to `/usr/local/sbin/`
3. Install the systemd service
4. Enable the service for automatic startup
5. Run the fix immediately
6. Verify the fix is working

### Manual Application

If you prefer to apply the fix manually without the systemd service:

```bash
# Install devmem2
sudo apt-get install -y devmem2

# Read current CR0 value (should show 0x1D)
sudo devmem2 0x0b010020 w

# Clear EVTQEN (bit 2): 0x1D -> 0x19
sudo devmem2 0x0b010020 w 0x19

# Verify (should show 0x19)
sudo devmem2 0x0b010020 w
```

> **Note:** The fix does not persist across reboots. You must re-apply it after every reboot, or use the provided systemd service.

### Verification

After applying the fix, verify it's working:

```bash
# 1. Check the CR0 register (should be 0x19, not 0x1D)
sudo devmem2 0x0b010020 w

# 2. Watch IRQ 13 -- should NOT be incrementing
watch -n 1 'grep arm-smmu-v3-evtq /proc/interrupts'

# 3. Check the systemd service status
sudo systemctl status smmu-evtq-fix.service

# 4. Check journal for the fix message
journalctl -u smmu-evtq-fix.service
```

Expected output after fix:
- CR0 reads `0x19`
- IRQ 13 counter stays frozen (0 new interrupts)
- Service shows `active (exited)` with success status
- Journal shows `smmu-evtq-fix: CR0 0x1D -> 0x19 (EVTQEN cleared)`

### Uninstallation

```bash
sudo ./uninstall.sh
```

Or manually:

```bash
sudo systemctl disable smmu-evtq-fix.service
sudo rm /etc/systemd/system/smmu-evtq-fix.service
sudo rm /usr/local/sbin/smmu-evtq-fix.sh
sudo systemctl daemon-reload
```

After uninstalling, the next reboot will restore the default firmware behavior (with the SMMU event storm).

---

## Technical Deep Dive

### ARM SMMU v3 Architecture

The ARM SMMU v3 (System Memory Management Unit) is specified in [ARM IHI 0070](https://developer.arm.com/documentation/ihi0070/latest). It provides address translation and access control for DMA-capable devices (primarily PCIe) on ARM platforms.

Key components:
- **Stream Table**: Maps device Stream IDs to Stream Table Entries (STEs) that define translation contexts
- **Command Queue**: Used by software to send commands to the SMMU hardware
- **Event Queue**: Hardware reports errors (translation faults, configuration errors) to software via this queue
- **Interrupt**: The SMMU signals the event queue via a dedicated interrupt (evtq IRQ)

### CR0 Register Layout

The SMMU CR0 register at offset `0x20` from the SMMU base address controls the main enable bits:

```
Bit  Name      Description
---  --------  ----------------------------------
 0   SMMUEN    SMMU enable (global on/off)
 1   PRIQEN    PRI (Page Request Interface) queue enable
 2   EVTQEN    Event queue enable  <-- THIS IS WHAT WE CLEAR
 3   CMDQEN    Command queue enable
 4   ATSCHK    ATS (Address Translation Service) check enable
```

On the CIX Sky1, the default CR0 value after firmware initialization is `0x1D`:

```
0x1D = 0001 1101
       |||| ||||
       |||| |||+-- bit 0: SMMUEN  = 1 (SMMU enabled)
       |||| ||+--- bit 1: PRIQEN  = 0 (PRI queue disabled)
       |||| |+---- bit 2: EVTQEN  = 1 (Event queue ENABLED) <-- problem
       |||| +----- bit 3: CMDQEN  = 1 (Command queue enabled)
       |||+------- bit 4: ATSCHK  = 1 (ATS check enabled)
```

Our fix clears bit 2, changing the value to `0x19`:

```
0x19 = 0001 1001
       |||| ||||
       |||| |||+-- bit 0: SMMUEN  = 1 (SMMU still enabled)
       |||| ||+--- bit 1: PRIQEN  = 0 (unchanged)
       |||| |+---- bit 2: EVTQEN  = 0 (Event queue DISABLED) <-- fixed
       |||| +----- bit 3: CMDQEN  = 1 (Command queue still enabled)
       |||+------- bit 4: ATSCHK  = 1 (ATS check still enabled)
```

### The Interrupt Path

```
 PCIe Device DMA Transaction
         |
         v
 +---------------------+
 |    SMMU Instance 0   |
 |   (0x0b010000)       |
 |                      |
 |  Stream Table Lookup |
 |  (25-bit, truncated) |
 |         |            |
 |         v            |
 |  SID not found!      |
 |  (C_BAD_STREAMID)    |
 |         |            |
 |         v            |
 |  Write event 0x07    |---- <-- DMA still passes through
 |  to Event Queue      |        (disable_bypass=0)
 |         |            |
 |         v            |
 |  Fire IRQ 13         |
 |  (GICv3 107, Edge)   |
 +---------------------+
           |
           v
 +---------------------+
 |       CPU 0          |
 |                      |
 |  arm-smmu-v3-evtq    |
 |  IRQ handler         |
 |    |                 |
 |    +-- Read event    |
 |    +-- Log to dmesg  |  ~130 times per second
 |    +-- Advance cons  |
 |    +-- Return        |
 |                      |
 |  Network softirqs    | <-- starved by IRQ handling
 |  (also on CPU0)      |
 +---------------------+
           |
           v
   SSH hangs, network drops,
   system appears frozen
```

### Why CPU0 Gets Starved

The ARM GIC (Generic Interrupt Controller) v3 delivers the SMMU evtq interrupt to CPU0 by default. While 130 IRQ/sec doesn't sound like much, each interrupt involves:

1. Context switch to IRQ handler
2. MMIO read from the event queue (slow -- device memory)
3. Kernel log formatting and output (dmesg)
4. Event queue consumer index update (another MMIO write)
5. Return from interrupt

The MMIO operations are particularly expensive on ARM platforms. Combined with the kernel's `PREEMPT` scheduling and the fact that network softirqs (NET_RX, NET_TX) are typically processed on the same CPU that receives the hardware interrupt, the sustained interrupt load gradually degrades network processing on CPU0.

Over time (minutes to hours depending on network load), TCP retransmission timers expire, keepalive probes fail, and SSH connections drop. The system is still running -- it just can't process network traffic efficiently.

---

## Test Environment

This fix was developed and tested on:

| Component | Details |
|-----------|---------|
| **Board** | Orange Pi 6 Plus |
| **SoC** | CIX Sky1 / CD8180 (12-core ARM, 32GB RAM) |
| **BIOS** | v1.4 (January 30, 2026) -- also tested on v1.3 |
| **Kernel** | 6.6.89-cix #90 SMP PREEMPT (December 30, 2025) |
| **OS** | Ubuntu 24.04 (Noble Numbat) aarch64 |
| **Root FS** | btrfs on NVMe RAID 0 (2x WD SN5000 1.8TB) |
| **Boot** | SD card EFI (GRUB) -> NVMe root |
| **PCIe devices** | Intel BE200 Wi-Fi 7, 2x Realtek RTL8126 5GbE, 2x WD SN5000 NVMe |

### Before Fix

```
$ grep arm-smmu-v3-evtq /proc/interrupts
 13:   61937   0   0   0   0   0   0   0   0   0   0   0   GICv3 107 Edge   arm-smmu-v3-evtq
```

~130 new interrupts per second, all on CPU0. System would become unresponsive after hours of operation.

### After Fix

```
$ grep arm-smmu-v3-evtq /proc/interrupts
 13:       1   0   0   0   0   0   0   0   0   0   0   0   GICv3 107 Edge   arm-smmu-v3-evtq
```

**1 total interrupt** (the initial event before the systemd service runs). Zero new interrupts. System stable.

---

## For Orange Pi / CIX Engineers

If you're from Orange Pi, CIX Semiconductor, or working on the CIX Sky1 UEFI firmware, here's what needs to be fixed properly:

### The Problem

The **IORT (IO Remapping Table)** in the UEFI firmware for SMMU instance 0 (`0x0b010000`) defines a **2-level stream table that only covers 25 bits of the 32-bit Stream ID space**. PCIe devices on this platform present Stream IDs that require the full 32-bit range.

### What Needs to Change

1. **Expand the stream table** to cover the full Stream ID range used by PCIe devices on this platform, OR
2. **Add proper STE (Stream Table Entry) mappings** for all PCIe root ports and their downstream devices, OR
3. **Configure the SMMU to use identity mapping** (bypass) for PCIe devices at the firmware level, which would prevent event generation entirely

### Relevant ACPI Tables

- **IORT** (IO Remapping Table) -- defines SMMU nodes and their Stream ID mappings to PCIe root complexes
- The Named Component and RC (Root Complex) nodes need correct ID mappings that cover all Stream IDs presented by hardware

### Stream IDs Observed

```
0x0100 -- PCI 01:00.0 (Intel BE200 Wi-Fi)
0x3100 -- PCI 31:00.0 (Realtek RTL8126 Ethernet)
0x6100 -- PCI 61:00.0 (Realtek RTL8126 Ethernet)
0x9100 -- PCI 91:00.0 (WD SN5000 NVMe)
0xC100 -- PCI c1:00.0 (WD SN5000 NVMe)
```

All generate event 0x07 (C_BAD_STREAMID) because the stream table cannot resolve them.

### Impact

This firmware bug affects **every CIX Sky1 board** with PCIe devices. It causes:
- ~130 spurious interrupts/sec on CPU0
- System instability under sustained network load
- SSH/network hangs requiring hard power cycles
- Poor user experience and negative community perception of the platform

The community is currently working around this with various hacks (limiting PCIe to Gen3, custom firmware forks, disabling PCIe devices). A proper IORT fix in the official firmware would resolve all of these issues.

---

## License

MIT License -- see [LICENSE](LICENSE)

---

## Contributing

If you're experiencing similar issues on other CIX Sky1-based boards:

1. **Test this fix** and report your results in an issue
2. **Share your IORT table** (`sudo acpidump -b && iasl -d iort.dat`) -- this helps map the firmware differences between boards
3. **Report your board and BIOS version** so we can track which firmware versions are affected

If you have access to CIX Sky1 UEFI firmware source or build tools, help fixing the IORT tables at the firmware level would be the ideal long-term solution.
