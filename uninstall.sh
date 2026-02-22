#!/bin/bash
# Uninstall script for SMMU Event Queue Fix
# https://github.com/ErcinDedeoglu/orangepi-6plus-cix-sky1-smmu-fix

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "========================================="
echo " SMMU Event Queue Fix Uninstaller"
echo " CIX Sky1 / Orange Pi 6 Plus"
echo "========================================="
echo

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: Please run as root (sudo ./uninstall.sh)${NC}"
    exit 1
fi

echo -n "[1/4] Stopping service... "
systemctl stop smmu-evtq-fix.service 2>/dev/null || true
echo -e "${GREEN}done${NC}"

echo -n "[2/4] Disabling service... "
systemctl disable smmu-evtq-fix.service 2>/dev/null || true
echo -e "${GREEN}done${NC}"

echo -n "[3/4] Removing files... "
rm -f /etc/systemd/system/smmu-evtq-fix.service
rm -f /usr/local/sbin/smmu-evtq-fix.sh
systemctl daemon-reload
echo -e "${GREEN}done${NC}"

echo -n "[4/4] Reloading systemd... "
systemctl daemon-reload
echo -e "${GREEN}done${NC}"

echo
echo "========================================="
echo -e " ${GREEN}Uninstallation complete${NC}"
echo "========================================="
echo
echo -e "${YELLOW}Note: The SMMU event queue is still disabled for this session.${NC}"
echo "It will be re-enabled on the next reboot (restoring the interrupt storm)."
echo "To re-enable it immediately: sudo devmem2 0x0b010020 w 0x1D"
