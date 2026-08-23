APP_NAME := vAirPrinter
BUILD_DIR := build
ARCH_FLAGS := -arch arm64 -arch x86_64
APP := $(BUILD_DIR)/$(APP_NAME).app
CONTENTS := $(APP)/Contents
MACOS := $(CONTENTS)/MacOS
HELPERS := $(CONTENTS)/Helpers
RESOURCES := $(CONTENTS)/Resources

.PHONY: all run clean

all: $(APP)

$(APP): src/main.m src/AppDelegate.m src/AppDelegate.h src/PDFPassthrough.m src/PrintForwarder.m src/PrintForwarder.h Info.plist assets/icon.png
	mkdir -p "$(MACOS)" "$(HELPERS)" "$(RESOURCES)"
	clang $(ARCH_FLAGS) -fobjc-arc -Wall -Wextra -Werror -mmacosx-version-min=13.0 -framework Cocoa -framework UserNotifications -lcups \
		src/main.m src/AppDelegate.m src/PrintForwarder.m -o "$(MACOS)/$(APP_NAME)"
	clang $(ARCH_FLAGS) -fobjc-arc -Wall -Wextra -Werror -mmacosx-version-min=13.0 -framework Foundation -framework CoreGraphics -lcups \
		src/PDFPassthrough.m src/PrintForwarder.m -o "$(HELPERS)/PDFPassthrough"
	cp Info.plist "$(CONTENTS)/Info.plist"
	cp "assets/icon.png" "$(RESOURCES)/AppIcon.png"
	xattr -c "$(RESOURCES)/AppIcon.png"
	codesign --force --sign - "$(HELPERS)/PDFPassthrough"
	codesign --force --sign - "$(APP)"

run: all
	open "$(APP)"

clean:
	rm -rf "$(BUILD_DIR)"
