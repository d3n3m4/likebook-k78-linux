# Build all native binaries for Likebook Ares Note K78W Pure Linux + Linux host encoder.
#
# Requirements:
#   - clang + lld (for freestanding AArch64 cross-compilation without a cross-libc)
#   - gcc or clang (for x86_64 host display encoder)

CLANG ?= clang
HOST_CC ?= gcc

AARCH64_FLAGS = --target=aarch64-linux-gnu -O3 -ffreestanding -nostdlib \
                -fno-builtin -fno-stack-protector -fuse-ld=lld -Wl,--build-id=none

BIN_DIR = bin
KO_LIBS = koreader/libs

DEVICE_BINS = \
	$(BIN_DIR)/k78_ebc_banner \
	$(BIN_DIR)/k78_tablet_sender \
	$(BIN_DIR)/k78_upic_engine \
	$(BIN_DIR)/rk_reboot

DEVICE_LIBS = \
	$(KO_LIBS)/libk78ebc.so \
	$(KO_LIBS)/libk78stream.so

HOST_LIBS = \
	$(BIN_DIR)/libk78enc_x64.so

.PHONY: all device host clean

all: device host

device: $(DEVICE_BINS) $(DEVICE_LIBS)

host: $(HOST_LIBS)

$(BIN_DIR) $(KO_LIBS):
	mkdir -p $@

$(BIN_DIR)/k78_ebc_banner: src/k78_ebc_banner.c | $(BIN_DIR)
	$(CLANG) $(AARCH64_FLAGS) -static $< -o $@

$(BIN_DIR)/k78_tablet_sender: src/k78_tablet_sender.c | $(BIN_DIR)
	$(CLANG) $(AARCH64_FLAGS) -static $< -o $@

$(BIN_DIR)/k78_upic_engine: src/k78_upic_engine.c | $(BIN_DIR)
	$(CLANG) $(AARCH64_FLAGS) -static $< -o $@

$(BIN_DIR)/rk_reboot: src/rk_reboot.c | $(BIN_DIR)
	$(CLANG) $(AARCH64_FLAGS) -static $< -o $@

$(KO_LIBS)/libk78ebc.so: src/k78_ebc_neon.c | $(KO_LIBS)
	$(CLANG) $(AARCH64_FLAGS) -shared -fPIC $< -o $@

$(KO_LIBS)/libk78stream.so: src/k78_stream_neon.c | $(KO_LIBS)
	$(CLANG) $(AARCH64_FLAGS) -shared -fPIC $< -o $@

$(BIN_DIR)/libk78enc_x64.so: src/k78_enc_x64.c | $(BIN_DIR)
	$(HOST_CC) -O3 -march=native -shared -fPIC $< -o $@

clean:
	rm -f $(DEVICE_BINS) $(DEVICE_LIBS) $(HOST_LIBS)
	rmdir $(BIN_DIR) $(KO_LIBS) 2>/dev/null || true
