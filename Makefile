# ExoShelf: build, test, bundle and install the launcher for eXo's collections.
# Running plain `make` lists every target.

SWIFT      ?= swift
APPDIR     ?= $(HOME)/Applications
PREFIX     ?= /usr/local
BINDIR     ?= $(PREFIX)/bin
# Test bundles are code-signed, and iCloud Drive's extended attributes break
# signing, so tests build outside the (possibly synced) project folder.
TEST_BUILD ?= /tmp/exoshelf-build
APP         = build/ExoShelf.app
# Quoted: the project path may contain spaces.
BIN         = "$$($(SWIFT) build -c release --show-bin-path)"

.DEFAULT_GOAL := help
.PHONY: help build release test check app run install install-cli uninstall clean

help: ## list targets and variables
	@printf "ExoShelf: a native macOS launcher for eXo's DOS, Windows 3.x and ScummVM collections\n\n"
	@printf 'usage: make <target> [VARIABLE=value]\n\ntargets:\n'
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  %-14s %s\n", $$1, $$2}'
	@printf '\nvariables:\n'
	@printf '  %-14s %s\n' 'APPDIR' 'where install puts ExoShelf.app (default ~/Applications)'
	@printf '  %-14s %s\n' 'PREFIX' 'install-cli prefix (default /usr/local); the CLI goes to $$PREFIX/bin'
	@printf '  %-14s %s\n' 'TEST_BUILD' 'where tests are built (default /tmp/exoshelf-build)'

build: ## debug build of the app and the CLI
	$(SWIFT) build

release: ## optimized build
	$(SWIFT) build -c release

test: ## unit tests; no network
	$(SWIFT) test --scratch-path "$(TEST_BUILD)"

check: test ## same as test (GNU convention)

app: release ## assemble build/ExoShelf.app
	@rm -rf "$(APP)" build/AppIcon.iconset
	@mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp $(BIN)/ExoShelf "$(APP)/Contents/MacOS/ExoShelf"
	cp Resources/Info.plist "$(APP)/Contents/Info.plist"
	$(SWIFT) scripts/make-icon.swift build/AppIcon.iconset
	iconutil -c icns build/AppIcon.iconset -o "$(APP)/Contents/Resources/AppIcon.icns"
	codesign --force --sign - --timestamp=none "$(APP)"
	@echo "built $(APP)"

run: app ## build the app and open it
	open "$(APP)"

install: app ## copy ExoShelf.app into APPDIR
	@mkdir -p "$(APPDIR)"
	rm -rf "$(APPDIR)/ExoShelf.app"
	ditto "$(APP)" "$(APPDIR)/ExoShelf.app"
	@echo "installed $(APPDIR)/ExoShelf.app"

install-cli: release ## copy exoshelf-cli into BINDIR
	install -d "$(BINDIR)"
	install -m 755 $(BIN)/exoshelf-cli "$(BINDIR)/exoshelf-cli"

uninstall: ## remove the installed app and CLI (your games stay)
	rm -rf "$(APPDIR)/ExoShelf.app"
	rm -f "$(BINDIR)/exoshelf-cli"

clean: ## remove build products
	$(SWIFT) package clean
	rm -rf build "$(TEST_BUILD)"
