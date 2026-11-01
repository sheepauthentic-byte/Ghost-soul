TARGET = sheepct_all_features.dylib
CC = clang++
CFLAGS = -std=c++20 -arch arm64 -isysroot $(shell xcrun --sdk iphoneos --show-sdk-path) -miphoneos-version-min=14.0
LDFLAGS = -dynamiclib -undefined dynamic_lookup \
          -framework Foundation -framework UIKit -framework QuartzCore -framework Metal -framework MetalKit

SOURCES = main.mm

all:
	$(CC) $(CFLAGS) $(SOURCES) $(LDFLAGS) -o $(TARGET)
	codesign -s - --entitlements entitlements.plist $(TARGET)
	@echo "Build complete: $(TARGET)"

clean:
	rm -f $(TARGET)
