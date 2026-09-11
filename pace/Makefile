APP := Pace.app
BUILD := .build/release

# Command Line Tools ship Swift Testing outside the default search path and
# without its Foundation cross-import overlay. With full Xcode these flags are
# unnecessary but harmless.
CLT_FW := /Library/Developer/CommandLineTools/Library/Developer/Frameworks
TESTFLAGS := $(shell [ -d $(CLT_FW) ] && echo "-Xswiftc -F$(CLT_FW) -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays -Xlinker -F$(CLT_FW) -Xlinker -rpath -Xlinker $(CLT_FW)")

.PHONY: build test app app-install app-zip icon run-sample clean

build:
	swift build -c release --product PaceApp

test:
	swift test $(TESTFLAGS)

Resources/AppIcon.icns: Resources/make_icon.swift
	swift Resources/make_icon.swift Resources/AppIcon.icns

icon: Resources/AppIcon.icns

# Menu-bar app bundle. Ad-hoc signed; a locally built .app is not quarantined,
# so it opens without Gatekeeper fuss. Signing with a Developer ID is only
# needed to hand the .app to someone else.
app: build Resources/AppIcon.icns
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BUILD)/PaceApp $(APP)/Contents/MacOS/PaceApp
	cp Resources/AppInfo.plist $(APP)/Contents/Info.plist
	cp Resources/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns
	codesign --force --deep --sign - $(APP) >/dev/null 2>&1 || true
	@echo "built $(APP) — run it with:  open $(APP)"

app-install: app
	@killall PaceApp 2>/dev/null || true
	rm -rf "/Applications/$(APP)"
	cp -R $(APP) /Applications/
	open "/Applications/$(APP)"
	@echo "installed + launched /Applications/$(APP) — look for the orange mark and three bars in your menu bar."

# For the other Mac: unzip, then  xattr -dr com.apple.quarantine Pace.app  and move it to /Applications.
app-zip: app
	rm -f $(HOME)/Downloads/Pace.zip
	ditto -c -k --keepParent $(APP) $(HOME)/Downloads/Pace.zip
	@echo "wrote ~/Downloads/Pace.zip"

# Run the debug build with the mockup's sample numbers, no network.
run-sample:
	swift build --product PaceApp
	PACE_DEBUG_STATE=sample .build/debug/PaceApp

clean:
	rm -rf .build $(APP)
