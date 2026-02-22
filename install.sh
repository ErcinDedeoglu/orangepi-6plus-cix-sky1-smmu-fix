#!/bin/bash
# Install script for SMMU Event Queue Fix
# https://github.com/ErcinDedeoglu/orangepi-6plus-cix-sky1-smmu-fix

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "========================================="
echo " SMMU Event Queue Fix Installer"
echo " CIX Sky1 / Orange Pi 6 Plus"
echo "========================================="
echo

# Check root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: Please run as root (sudo ./install.sh)${NC}"
    exit 1
fi

# Check architecture
ARCH=$(uname -m)
if [ "$ARCH" != "aarch64" ]; then
    echo -e "${RED}Error: This fix is for ARM64 (aarch64) only. Detected: $ARCH${NC}"
    exit 1
fi

# Check if SMMU instance 0 exists
if ! grep -q '0b010000' /proc/iomem 2>/dev/null; then
    echo -e "${YELLOW}Warning: SMMU instance 0 (0x0b010000) not found in /proc/iomem${NC}"
    echo "This fix is designed for the CIX Sky1 / CD8180 SoC."
    read -rp "Continue anyway? [y/N] " response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 1
    fi
fi

# Step 1: Install devmem2
echo -n "[1/5] Checking for devmem2... "
if command -v devmem2 &>/dev/null; then
    echo -e "${GREEN}already installed${NC}"
else
    echo -n "installing... "
    apt-get install -y devmem2 > /dev/null 2>&1
    if command -v devmem2 &>/dev/null; then
        echo -e "${GREEN}done${NC}"
    else
        echo -e "${RED}failed${NC}"
        echo "Please install devmem2 manually: sudo apt-get install devmem2"
        exit 1
    fi
fi

# Step 2: Install the fix script
echo -n "[2/5] Installing fix script to /usr/local/sbin/... "
cp smmu-evtq-fix.sh /usr/local/sbin/smmu-evtq-fix.sh
chmod 755 /usr/local/sbin/smmu-evtq-fix.sh
echo -e "${GREEN}done${NC}"

# Step 3: Install systemd service
echo -n "[3/5] Installing systemd service... "
cp smmu-evtq-fix.service /etc/systemd/system/smmu-evtq-fix.service
systemctl daemon-reload
echo -e "${GREEN}done${NC}"

# Step 4: Enable the service
echo -n "[4/5] Enabling service for automatic startup... "
systemctl enable smmu-evtq-fix.service > /dev/null 2>&1
echo -e "${GREEN}done${NC}"

# Step 5: Apply the fix now
echo -n "[5/5] Applying fix now... "
IRQ_BEFORE=$(awk '/GICv3 107/ {print $2}' /proc/interrupts 2>/dev/null || echo "0")
/usr/local/sbin/smmu-evtq-fix.sh
sleep 2
IRQ_AFTER=$(awk '/GICv3 107/ {print $2}' /proc/interrupts 2>/dev/null || echo "0")
IRQ_DELTA=$((IRQ_AFTER - IRQ_BEFORE))

echo
echo "========================================="
echo -e " ${GREEN}Installation complete!${NC}"
echo "========================================="
echo
echo "Verification:"

# Verify CR0
CR0=$(devmem2 0x0b010020 w 2>/dev/null | awk '/Value at address/ {print $NF}')
if [ "$CR0" = "0x19" ]; then
    echo -e "  CR0 register:  ${GREEN}$CR0 (EVTQEN disabled)${NC}"
else
    echo -e "  CR0 register:  ${YELLOW}$CR0 (unexpected value)${NC}"
fi

# Verify IRQ
if [ "$IRQ_DELTA" -eq 0 ]; then
    echo -e "  IRQ delta:     ${GREEN}0 new interrupts in 2 seconds${NC}"
else
    echo -e "  IRQ delta:     ${YELLOW}$IRQ_DELTA new interrupts in 2 seconds${NC}"
fi

# Service status
if systemctl is-enabled smmu-evtq-fix.service &>/dev/null; then
    echo -e "  Service:       ${GREEN}enabled (will run on boot)${NC}"
else
    echo -e "  Service:       ${RED}not enabled${NC}"
fi

echo
echo "The fix will be automatically applied on every reboot."
echo "To check status:  sudo systemctl status smmu-evtq-fix.service"
echo "To uninstall:     sudo ./uninstall.sh"
