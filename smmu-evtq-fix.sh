#!/bin/bash
# SMMU Event Queue Disable Fix for CIX Sky1 (Orange Pi 6 Plus)
#
# Problem: The CIX Sky1 UEFI firmware has broken IORT stream table mappings
# that only cover 25 of 32 SID bits. This causes every PCIe DMA transaction
# to generate an SMMU event 0x07 (C_BAD_STREAMID), firing ~130 IRQs/sec on
# CPU0. Over time this starves the network stack, causing SSH/network hangs.
#
# Fix: Disable the SMMU event queue by clearing bit 2 (EVTQEN) in the CR0
# register of SMMU instance 0. The event queue is only used for error logging,
# not DMA data flow. Since all events are false alarms from broken firmware,
# disabling the queue has no functional impact.
#
# SMMU instance 0 base: 0x0b010000
# CR0 register offset:  0x20
# CR0 address:          0x0b010020
# EVTQEN:               bit 2
#
# References:
# - ARM SMMU v3 Architecture Specification (ARM IHI 0070)
# - BredOS Orion O6 wiki (documents PCIe instability on CIX Sky1)
# - https://github.com/ErcinDedeoglu/orangepi-6plus-cix-sky1-smmu-fix

set -euo pipefail

SMMU_CR0_ADDR="0x0b010020"
EVTQEN_BIT=2
EVTQEN_MASK=$((1 << EVTQEN_BIT))  # 0x04

# Read current CR0 value
CURRENT=$(devmem2 "$SMMU_CR0_ADDR" w | awk '/Value at address/ {print $NF}')
CURRENT_DEC=$((CURRENT))

if (( CURRENT_DEC & EVTQEN_MASK )); then
    # EVTQEN is set -- clear it
    NEW_VAL=$(printf "0x%02X" $(( CURRENT_DEC & ~EVTQEN_MASK )))
    devmem2 "$SMMU_CR0_ADDR" w "$NEW_VAL" > /dev/null
    echo "smmu-evtq-fix: CR0 $CURRENT -> $NEW_VAL (EVTQEN cleared)"
else
    echo "smmu-evtq-fix: CR0 $CURRENT -- EVTQEN already clear, nothing to do"
fi
