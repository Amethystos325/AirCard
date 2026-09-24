CLANG := xcrun clang
ROOT := ../..
CFLAGS := -fobjc-arc -O2 -Wall -Wextra -mmacosx-version-min=14.0 -arch arm64 -arch x86_64
FOUNDATION := -framework Foundation -framework CoreFoundation
MOBILEDEVICE := /System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice
AIRTRAFFIC := /System/Library/PrivateFrameworks/AirTrafficHost.framework/AirTrafficHost

.PHONY: all clean

all: $(ROOT)/build/device_helper $(ROOT)/build/airtraffic_host

$(ROOT)/build:
	mkdir -p $@

$(ROOT)/build/device_helper: helpers/device_helper.m helpers/airlift_target.h helpers/os_trace.h | $(ROOT)/build
	$(CLANG) $(CFLAGS) $(FOUNDATION) $(MOBILEDEVICE) $< -o $@
	codesign --force --sign - $@

$(ROOT)/build/airtraffic_host: helpers/airtraffic_host.m | $(ROOT)/build
	$(CLANG) $(CFLAGS) $(FOUNDATION) $(AIRTRAFFIC) $< -o $@
	codesign --force --sign - $@

clean:
	rm -f $(ROOT)/build/device_helper $(ROOT)/build/airtraffic_host
