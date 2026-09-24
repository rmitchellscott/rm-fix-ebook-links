XOVI_REPO ?= $(HOME)/github/asivery/xovi
name = fix-ebook-links

VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo "dev")

XOVI_VERSION = $(shell echo "$(VERSION)" | sed 's/^v//' | awk -F'[.-]' '{if (NF >= 3 && $$1 ~ /^[0-9]+$$/) printf "%d", ($$1 * 65536) + ($$2 * 256) + $$3; else print "0"}')

CXX_AARCH64 ?= aarch64-linux-gnu-g++
CXX_ARMV7 ?= arm-linux-gnueabihf-g++
TARGET_CPU_AARCH64 ?= cortex-a53
TARGET_CPU_ARMV7 ?= cortex-a9
QT_VERSION ?= $(shell pkg-config --modversion Qt6Gui)
QT_INCLUDE ?= $(SDKTARGETSYSROOT)/usr/include
QT_CXXFLAGS = $(shell pkg-config --cflags Qt6Gui) \
	-I$(QT_INCLUDE)/QtCore/$(QT_VERSION) -I$(QT_INCLUDE)/QtCore/$(QT_VERSION)/QtCore \
	-I$(QT_INCLUDE)/QtGui/$(QT_VERSION) -I$(QT_INCLUDE)/QtGui/$(QT_VERSION)/QtGui
QT_LIBS = $(shell pkg-config --libs Qt6Gui)
CXXFLAGS = -D_GNU_SOURCE -fPIC -O2 -Wall -Wextra -std=c++17 -DVERSION=\"$(VERSION)\" $(QT_CXXFLAGS)
LDFLAGS =

BUILD_AARCH64 = build-aarch64
BUILD_ARMV7 = build-armv7

OBJECTS_AARCH64 = $(BUILD_AARCH64)/extension.o $(BUILD_AARCH64)/epublinks.o $(BUILD_AARCH64)/xovi.o
OBJECTS_ARMV7 = $(BUILD_ARMV7)/extension.o $(BUILD_ARMV7)/epublinks.o $(BUILD_ARMV7)/xovi.o

.PHONY: all clean clean-aarch64 clean-armv7 print-version

print-version:
	@echo "VERSION=$(VERSION)"
	@echo "XOVI_VERSION=$(XOVI_VERSION)"

all: $(name)-aarch64.so $(name)-armv7.so

# ARM64 (aarch64) build
$(name)-aarch64.so: $(OBJECTS_AARCH64)
	$(CXX_AARCH64) $(CXXFLAGS) -mcpu=$(TARGET_CPU_AARCH64) -shared -o $@ $^ $(LDFLAGS) $(QT_LIBS)

$(BUILD_AARCH64)/%.o: src/%.cpp $(BUILD_AARCH64)/xovi.h
	$(CXX_AARCH64) $(CXXFLAGS) -mcpu=$(TARGET_CPU_AARCH64) -I$(BUILD_AARCH64) -c $< -o $@

$(BUILD_AARCH64)/xovi.o: $(BUILD_AARCH64)/xovi.cpp $(BUILD_AARCH64)/xovi.h
	$(CXX_AARCH64) $(CXXFLAGS) -mcpu=$(TARGET_CPU_AARCH64) -I$(BUILD_AARCH64) -c $< -o $@

$(BUILD_AARCH64)/xovi.h: $(BUILD_AARCH64)/xovi.cpp
$(BUILD_AARCH64)/xovi.cpp: $(name).xovi
	@mkdir -p $(BUILD_AARCH64)
	python3 $(XOVI_REPO)/util/xovigen.py -a aarch64 -o $(BUILD_AARCH64)/xovi.cpp -H $(BUILD_AARCH64)/xovi.h $(name).xovi
	@sed -i.bak 's/const int EXTENSIONVERSION = [0-9]*/const int EXTENSIONVERSION = $(XOVI_VERSION)/' $(BUILD_AARCH64)/xovi.cpp && rm -f $(BUILD_AARCH64)/xovi.cpp.bak

# ARM32v7 (armv7) build
$(name)-armv7.so: $(OBJECTS_ARMV7)
	$(CXX_ARMV7) $(CXXFLAGS) -mcpu=$(TARGET_CPU_ARMV7) -shared -o $@ $^ $(LDFLAGS) $(QT_LIBS)

$(BUILD_ARMV7)/%.o: src/%.cpp $(BUILD_ARMV7)/xovi.h
	$(CXX_ARMV7) $(CXXFLAGS) -mcpu=$(TARGET_CPU_ARMV7) -I$(BUILD_ARMV7) -c $< -o $@

$(BUILD_ARMV7)/xovi.o: $(BUILD_ARMV7)/xovi.cpp $(BUILD_ARMV7)/xovi.h
	$(CXX_ARMV7) $(CXXFLAGS) -mcpu=$(TARGET_CPU_ARMV7) -I$(BUILD_ARMV7) -c $< -o $@

$(BUILD_ARMV7)/xovi.h: $(BUILD_ARMV7)/xovi.cpp
$(BUILD_ARMV7)/xovi.cpp: $(name).xovi
	@mkdir -p $(BUILD_ARMV7)
	python3 $(XOVI_REPO)/util/xovigen.py -a arm32 -o $(BUILD_ARMV7)/xovi.cpp -H $(BUILD_ARMV7)/xovi.h $(name).xovi
	@sed -i.bak 's/const int EXTENSIONVERSION = [0-9]*/const int EXTENSIONVERSION = $(XOVI_VERSION)/' $(BUILD_ARMV7)/xovi.cpp && rm -f $(BUILD_ARMV7)/xovi.cpp.bak

clean-aarch64:
	rm -f $(name)-aarch64.so $(BUILD_AARCH64)/*.o

clean-armv7:
	rm -f $(name)-armv7.so $(BUILD_ARMV7)/*.o

clean: clean-aarch64 clean-armv7
	rm -rf $(BUILD_AARCH64) $(BUILD_ARMV7)
