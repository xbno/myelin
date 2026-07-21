PREFIX ?= $(HOME)/.local
BINDIR := $(PREFIX)/bin
SKILL_SRC := ../skills/live-recorder
SKILL_DST := $(HOME)/.claude/skills/live-recorder

APP := LiveRecorder.app

.PHONY: build install skill skill-zip app app-install uninstall clean

build:
	swift build -c release

install: build
	mkdir -p $(BINDIR)
	install .build/release/recorder $(BINDIR)/recorder
	@echo "installed $(BINDIR)/recorder"
	@case ":$$PATH:" in *:"$(BINDIR)":*) ;; *) echo "NOTE: add $(BINDIR) to your PATH";; esac

skill:
	mkdir -p $(SKILL_DST)
	cp -R $(SKILL_SRC)/SKILL.md $(SKILL_SRC)/scripts $(SKILL_DST)/
	@echo "installed Claude skill → $(SKILL_DST)"

# Zip the skill for sharing (upload at claude.ai → Settings → Capabilities →
# Skills, or hand to a user). Zip root must be the skill folder itself.
skill-zip:
	rm -f $(HOME)/Downloads/live-recorder-skill.zip
	cd $(SKILL_SRC)/.. && zip -r -X $(HOME)/Downloads/live-recorder-skill.zip \
		live-recorder -x "*.DS_Store"
	@echo "wrote ~/Downloads/live-recorder-skill.zip"

# Menu-bar app bundle. Bundles the `recorder` binary inside so the app is
# self-contained. Ad-hoc signed so TCC (mic/system-audio/calendar) can attribute
# grants; a locally-built .app isn't quarantined, so it opens without Gatekeeper
# fuss. Proper Developer-ID signing/notarization is only needed to SHARE it.
app:
	swift build -c release --product recorder
	swift build -c release --product LiveRecorderApp
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp .build/release/LiveRecorderApp $(APP)/Contents/MacOS/LiveRecorderApp
	cp .build/release/recorder $(APP)/Contents/MacOS/recorder
	cp Resources/AppInfo.plist $(APP)/Contents/Info.plist
	cp Resources/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns
	codesign --force --deep --sign - $(APP) >/dev/null 2>&1 || true
	@echo "built $(APP) — run it with:  open $(APP)"

app-install: app
	@killall LiveRecorderApp 2>/dev/null || true
	@killall recorder 2>/dev/null || true
	@rm -rf "/Applications/$(APP)"
	cp -R $(APP) /Applications/
	open "/Applications/$(APP)"
	@echo "installed + launched /Applications/$(APP) — look for the waveform in your menu bar."
	@echo "first Start prompts for Microphone + System Audio; naming prompts for Calendar."
	@echo "menu has a 'Launch at Login' toggle (no System Settings trip needed)."

uninstall:
	rm -f $(BINDIR)/recorder
	rm -rf $(SKILL_DST)

clean:
	swift package clean
