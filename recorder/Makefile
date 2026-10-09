PREFIX ?= $(HOME)/.local
BINDIR := $(PREFIX)/bin
SKILL_SRC := ../skills/live-recorder
SKILL_DST := $(HOME)/.claude/skills/live-recorder
APP := LiveRecorder.app
# The checkout this app is built from. Baked into the bundle as the value the
# first-launch "Where should recordings go?" dialog is prefilled with — it is a
# suggestion, never the setting itself. The setting lives in
# ~/.config/live-recorder/recordings-dir and only the user writes it.
REPO_ROOT := $(shell git rev-parse --show-toplevel 2>/dev/null || (cd .. && pwd))

.PHONY: build install skill-zip app app-install uninstall clean

build:
	swift build -c release

install: build
	mkdir -p $(BINDIR)
	install .build/release/recorder $(BINDIR)/recorder
	@echo "installed $(BINDIR)/recorder"
	@case ":$$PATH:" in *:"$(BINDIR)":*) ;; *) echo "NOTE: add $(BINDIR) to your PATH";; esac

# Zip the skill for sharing (upload at claude.ai → Settings → Capabilities →
# Skills, or copy to another installation) and sync it into the local Claude Code CLI
# skills dir. Zip root must be the skill folder itself. The CLI sync only
# touches SKILL.md + scripts/*.py — never state/ (per-session cursors) or
# __pycache__, so it doesn't clobber local pull state.
skill-zip:
	rm -f $(HOME)/Downloads/live-recorder-skill.zip
	cd $(SKILL_SRC)/.. && zip -r -X $(HOME)/Downloads/live-recorder-skill.zip \
		live-recorder -x "*.DS_Store"
	@echo "wrote ~/Downloads/live-recorder-skill.zip"
	mkdir -p $(SKILL_DST)/scripts
	cp $(SKILL_SRC)/SKILL.md $(SKILL_DST)/SKILL.md
	cp $(SKILL_SRC)/scripts/*.py $(SKILL_DST)/scripts/
	@echo "synced $(SKILL_DST) (Claude Code CLI)"

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
	/usr/libexec/PlistBuddy -c \
		"Add :LRDefaultRecordingsDir string $(REPO_ROOT)/recordings" \
		$(APP)/Contents/Info.plist
	codesign --force --deep --sign - $(APP) >/dev/null 2>&1 || true
	@echo "built $(APP) — run it with:  open $(APP)"

app-install: app
	@killall LiveRecorderApp 2>/dev/null || true
	@killall recorder 2>/dev/null || true
	@rm -rf "/Applications/$(APP)"
	cp -R $(APP) /Applications/
	open "/Applications/$(APP)"
	@echo "installed + launched /Applications/$(APP) — look for the waveform in your menu bar."
	@echo "first launch asks where recordings go (default: $(REPO_ROOT)/recordings)."
	@echo "first Start prompts for Microphone + System Audio; naming prompts for Calendar."
	@echo "menu has a 'Launch at Login' toggle (no System Settings trip needed)."

uninstall:
	rm -f $(BINDIR)/recorder

clean:
	swift package clean
