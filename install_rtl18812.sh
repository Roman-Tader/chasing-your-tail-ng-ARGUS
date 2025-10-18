#!/usr/bin/env bash

set -euo pipefail

git submodule update --init --recursive

cd rtl8812au

# Determine the driver version from dkms.conf so we can manage existing installs.
driver_version=$(grep -E '^PACKAGE_VERSION' dkms.conf | sed -E 's/^[^=]+="?([^"]+)"?/\1/')

if dkms status | grep -q "8812au/${driver_version},"; then
    echo "Found existing 8812au DKMS installation for version ${driver_version}; removing before reinstall."
    sudo dkms remove -m 8812au -v "${driver_version}" --force
fi

sudo make dkms_install    # bevorzugt, installiert via DKMS
# Falls dkms_install fehlt:
sudo make
sudo make install
