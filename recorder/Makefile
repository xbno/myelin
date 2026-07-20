PREFIX ?= $(HOME)/.local
BINDIR := $(PREFIX)/bin
SKILL_SRC := ../skills/live-recorder
SKILL_DST := $(HOME)/.claude/skills/live-recorder

APP := LiveRecorder.app

.PHONY: build install skill app app-install uninstall clean

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

# Menu-bar app bundle. Bundles the `recorder` binary inside so the app is
# self-contained. Ad-hoc signed so TCC (mic/system-audio/calendar) can attribute
# grants; a locally-built .app isn't quarantined, so it opens without Gatekeeper
# fuss. Proper Developer-ID signing/notarization is only needed to SHARE it.
app:
	swift build -c release --product recorder
	swift build -c release --product LiveRecorderApp
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp .build/release/LiveRecorderApp $(APP)/Contents/MacOS/LiveRecorderApp
	cp .build/release/recorder $(APP)/Contents/MacOS/recorder
	cp Resources/AppInfo.plist $(APP)/Contents/Info.plist
	codesign --force --deep --sign - $(APP) >/dev/null 2>&1 || true
	@echo "built $(APP) — run it with:  open $(APP)"

app-install: app
	@rm -rf "/Applications/$(APP)"
	cp -R $(APP) /Applications/
	@echo "installed /Applications/$(APP)"
	@echo "launch: open \"/Applications/$(APP)\"  (grant mic + system-audio + calendar on first record)"
	@echo "launch at login: System Settings > General > Login Items > +  /Applications/$(APP)"

uninstall:
	rm -f $(BINDIR)/recorder
	rm -rf $(SKILL_DST)

clean:
	swift package clean
