PREFIX ?= $(HOME)/.local
BINDIR := $(PREFIX)/bin
SKILL_SRC := ../skills/live-recorder
SKILL_DST := $(HOME)/.claude/skills/live-recorder

.PHONY: build install skill uninstall clean

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

uninstall:
	rm -f $(BINDIR)/recorder
	rm -rf $(SKILL_DST)

clean:
	swift package clean
