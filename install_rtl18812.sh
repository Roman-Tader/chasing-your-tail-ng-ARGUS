git submodule update --init --recursive
cd rtl8812au
sudo make dkms_install    # bevorzugt, installiert via DKMS
# Falls dkms_install fehlt:
sudo make
sudo make install
