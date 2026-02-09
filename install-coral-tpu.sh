#!/bin/bash
# install-coral-tpu.sh
# Automates Coral TPU driver install on Debian/Proxmox/Mint (kernel 6.1+)
# Includes patches for modern kernels (6.12+) with DMA_BUF namespace requirements

set -e

echo "=== Step 1: Install prerequisites ==="
sudo apt update
sudo apt install -y git devscripts dh-dkms dkms build-essential "linux-headers-$(uname -r)"

echo "=== Step 2: Clone and build gasket driver ==="
cd ~
if [ ! -d "gasket-driver" ]; then
  git clone https://github.com/google/gasket-driver.git
fi
cd gasket-driver
debuild -us -uc -tc -b
cd ..
sudo dpkg -i gasket-dkms_1.0-18_all.deb || true

echo "=== Step 3: Apply kernel patches ==="
cd /usr/src/gasket-1.0/

# Patch gasket_core.c - fix llseek
sudo sed -i 's/\.llseek = no_llseek,/\.llseek = noop_llseek,/' gasket_core.c

# Patch gasket_page_table.c - Add DMA_BUF namespace import if not present
if ! grep -q "#ifdef MODULE_IMPORT_NS" gasket_page_table.c; then
  echo "Patching gasket_page_table.c for DMA_BUF namespace..."
  # Remove existing MODULE_IMPORT_NS(DMA_BUF) line if present
  sudo sed -i '/^MODULE_IMPORT_NS(DMA_BUF);/d' gasket_page_table.c
  # Add conditional DMA_BUF import at the end of the file
  echo -e "\n#ifdef MODULE_IMPORT_NS\nMODULE_IMPORT_NS(DMA_BUF);\n#endif" | sudo tee -a gasket_page_table.c > /dev/null
fi

# Patch gasket_core.c - Add DMA_BUF namespace import if not present
if ! grep -q "MODULE_IMPORT_NS(DMA_BUF)" gasket_core.c; then
  echo "Patching gasket_core.c for DMA_BUF namespace..."
  echo -e "\n#ifdef MODULE_IMPORT_NS\nMODULE_IMPORT_NS(DMA_BUF);\n#endif" | sudo tee -a gasket_core.c > /dev/null
fi

# Patch apex_driver.c - Add DMA_BUF namespace import if not present
if ! grep -q "MODULE_IMPORT_NS(DMA_BUF)" apex_driver.c; then
  echo "Patching apex_driver.c for DMA_BUF namespace..."
  echo -e "\n#ifdef MODULE_IMPORT_NS\nMODULE_IMPORT_NS(DMA_BUF);\n#endif" | sudo tee -a apex_driver.c > /dev/null
fi

echo "=== Step 4: Rebuild and install DKMS module ==="
if ! sudo dkms build -m gasket -v 1.0 -k "$(uname -r)"; then
  echo "❌ DKMS build failed. Showing DKMS status and recent kernel messages:"
  sudo dkms status
  echo ""
  echo "Recent kernel messages (dmesg):"
  sudo dmesg | tail -50
  exit 1
fi

if ! sudo dkms install -m gasket -v 1.0 -k "$(uname -r)"; then
  echo "❌ DKMS install failed. Showing DKMS status:"
  sudo dkms status
  exit 1
fi

echo "=== Step 5: Load modules ==="
sudo modprobe gasket
sudo modprobe apex

echo "=== Step 6: Quick Verification ==="
if lsmod | grep -q apex && [ -e /dev/apex_0 ]; then
  echo "✅ Coral TPU driver loaded successfully!"
  echo "   - apex module is active"
  echo "   - /dev/apex_0 device node present"
  echo ""
  echo "PCI Device Information:"
  lspci -d 1ac1: 2>/dev/null || echo "   (lspci not available or no Coral device detected via PCI)"
  echo ""
  echo "Module Information:"
  lsmod | grep -E "gasket|apex"
else
  echo "❌ TPU driver not fully loaded."
  echo ""
  echo "Debugging Information:"
  echo "DKMS Status:"
  sudo dkms status
  echo ""
  echo "Loaded Modules:"
  lsmod | grep -E "gasket|apex" || echo "   No gasket/apex modules loaded"
  echo ""
  echo "Device Nodes:"
  ls -la /dev/apex* 2>/dev/null || echo "   No /dev/apex* devices found"
  echo ""
  echo "Recent Kernel Messages:"
  sudo dmesg | tail -30
  exit 1
fi

echo "=== Done! ==="
