CLANG := xcrun clang
CFLAGS := -fobjc-arc -O2 -Wall -Wextra -mmacosx-version-min=14.0 -arch arm64 -arch x86_64
FOUNDATION := -framework Foundation -framework CoreFoundation
MOBILEDEVICE := /System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice
AIRTRAFFIC := /System/Library/PrivateFrameworks/AirTrafficHost.framework/AirTrafficHost

.PHONY: all clean

all: build/device_helper build/airtraffic_host

build:
	mkdir -p $@

build/device_helper: macos/helpers/device_helper.m macos/helpers/airlift_target.h macos/helpers/os_trace.h | build
	$(CLANG) $(CFLAGS) $(FOUNDATION) $(MOBILEDEVICE) $< -o $@
	codesign --force --sign - $@

build/airtraffic_host: macos/helpers/airtraffic_host.m | build
	$(CLANG) $(CFLAGS) $(FOUNDATION) $(AIRTRAFFIC) $< -o $@
	codesign --force --sign - $@

clean:
	rm -rf build
