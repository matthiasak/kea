# Kea build, test, iOS Simulator, and Xcode setup targets.
# Run `make help` to list all targets.

SHELL := /bin/bash
export PATH := $(HOME)/.local/bin:/opt/homebrew/bin:/usr/local/bin:$(PATH)

OPT            ?= Debug
IOS_MIN        ?= 18.4
IOS_SIM_TARGET ?= aarch64-ios.$(IOS_MIN)-simulator
IOS_DEV_TARGET ?= aarch64-ios.$(IOS_MIN)
SIM_DEVICE     ?=
ARGS           ?=
XCODE_FLAGS    ?= --latest --experimental-unxip
XCODE_MAS_ID   := 497799835

# Load .env OAuth client IDs for iOS zig builds just as build.sh does for macOS.
define RUN_ZIG_IOS
	set -euo pipefail; \
	[ -f .env ] && { set -a; . ./.env; set +a; }; \
	cd zig && \
	ZFLAG="$$(cd nanoui && sh tools/ios/zig-lib.sh)" && \
	zig build $$ZFLAG \
		-Dgdrive-client-id="$${KEA_GDRIVE_CLIENT_ID:-}" \
		-Dgdrive-client-secret="$${KEA_GDRIVE_CLIENT_SECRET:-}" \
		$(1)
endef

# Boot a matching iOS Simulator device ($1 = family regex, $2 = preferred regex) if needed.
define BOOT_SIM
	set -euo pipefail; \
	if ! xcrun --sdk iphonesimulator --show-sdk-path >/dev/null 2>&1; then \
		echo "error: iphonesimulator SDK missing. Run 'make xcode-install' then 'make xcode-setup'." >&2; \
		exit 1; \
	fi; \
	BOOTED="$$(xcrun simctl list devices booted | grep -E '\(Booted\)' || true)"; \
	WANT="$(SIM_DEVICE)"; \
	if [ -n "$$WANT" ]; then \
		if ! printf '%s\n' "$$BOOTED" | grep -Fq "$$WANT"; then \
			xcrun simctl shutdown all >/dev/null 2>&1 || true; \
			UDID="$$(xcrun simctl list devices available | grep -F "$$WANT" | grep -Eo '[0-9A-F-]{36}' | head -n1 || true)"; \
			[ -n "$$UDID" ] || { echo "error: simulator '$$WANT' not found (run 'xcrun simctl list devices available')" >&2; exit 1; }; \
			xcrun simctl boot "$$UDID"; \
			xcrun simctl bootstatus "$$UDID" -b >/dev/null; \
		fi; \
	elif ! printf '%s\n' "$$BOOTED" | grep -Eq "$(1)"; then \
		xcrun simctl shutdown all >/dev/null 2>&1 || true; \
		AVAIL="$$(xcrun simctl list devices available)"; \
		UDID="$$(printf '%s\n' "$$AVAIL" | grep -E "$(2)" | grep -Eo '[0-9A-F-]{36}' | head -n1 || true)"; \
		[ -n "$$UDID" ] || UDID="$$(printf '%s\n' "$$AVAIL" | grep -E "$(1)" | grep -Eo '[0-9A-F-]{36}' | head -n1 || true)"; \
		[ -n "$$UDID" ] || { echo "error: no available $(1) simulator runtime installed. Run 'xcodebuild -downloadPlatform iOS'." >&2; exit 1; }; \
		xcrun simctl boot "$$UDID"; \
		xcrun simctl bootstatus "$$UDID" -b >/dev/null; \
	fi; \
	XCODE_CONTENTS="$$(dirname "$$(xcode-select -p)")"; \
	for gui in "$$XCODE_CONTENTS/Developer/Applications/Simulator.app" "$$XCODE_CONTENTS/Applications/Simulator.app" "$$XCODE_CONTENTS/Applications/DeviceHub.app"; do \
		if [ -d "$$gui" ]; then open "$$gui"; break; fi; \
	done
endef

.PHONY: all help \
	macos macos-debug install run \
	ios-sim ios-device ios-obj ios-check \
	sim-boot-ipad sim-boot-iphone ios-run ios-run-ipad ios-run-iphone ios-watch \
	lines test ui-test e2e perf smooth snapshots check clean \
	xcode-check xcode-install xcode-xcodes xcode-setup

all: macos

help:
	@printf "Kea Build & Verification Targets:\n\n"
	@printf "  macOS:\n"
	@printf "    make [macos]          Build ReleaseFast bundle at build/Kea.app (does not touch /Applications)\n"
	@printf "    make macos-debug      Build Debug bundle at build/Kea.app\n"
	@printf "    make install          Build & install /Applications/Kea.app (quit Kea first)\n"
	@printf "    make run              Build Debug & launch Kea in an isolated --temp-profile\n\n"
	@printf "  iOS / iPadOS (OPT=%s, IOS_MIN=%s):\n" "$(OPT)" "$(IOS_MIN)"
	@printf "    make ios-sim          Build zig/zig-out/ios/Kea.app for iOS/iPadOS Simulator\n"
	@printf "    make ios-device       Build zig/zig-out/ios/Kea.app for physical iPhone/iPad (arm64)\n"
	@printf "    make ios-run          Boot Simulator (default iPad) & launch Kea (ARGS='...')\n"
	@printf "    make ios-run-ipad     Boot iPad Pro Simulator & launch Kea\n"
	@printf "    make ios-run-iphone   Boot iPhone Pro Simulator & launch Kea\n"
	@printf "    make ios-watch        Watch Zig sources & live-relaunch Kea in booted Simulator\n"
	@printf "    make ios-obj          Compile SDK-free Simulator & Device arm64 Mach-O objects\n"
	@printf "    make ios-check        Compile iOS Mach-O objects & audit 0 AppKit / 0 private SPIs\n\n"
	@printf "  Tests & Gates:\n"
	@printf "    make lines            Check <= 600 lines per .zig file in zig/nanoui and zig/\n"
	@printf "    make test             Run unit tests in zig/nanoui and zig/\n"
	@printf "    make ui-test          Run headless chrome suites (ui.Tester)\n"
	@printf "    make e2e              Run WebKit end-to-end tests (filter via KEA_E2E='...')\n"
	@printf "    make perf             Run chrome frame-time benchmark gate\n"
	@printf "    make smooth           Run 120 Hz on-screen smoothness suite (filter via KEA_SMOOTH=S2)\n"
	@printf "    make snapshots        Render named chrome states to PNG\n"
	@printf "    make check            Run lines + test + ui-test + ios-check\n"
	@printf "    make clean            Remove build/, zig/zig-out/, and zig/nanoui/zig-out/\n\n"
	@printf "  Xcode & Simulator Setup:\n"
	@printf "    make xcode-check      Verify Zig, Xcode, iOS SDKs, and Simulator runtimes\n"
	@printf "    make xcode-install    Download & install Xcode from Mac App Store (mas id %s)\n" "$(XCODE_MAS_ID)"
	@printf "    make xcode-xcodes     Download & install Xcode via xcodes + aria2c (XCODE_FLAGS='...')\n"
	@printf "    make xcode-setup      Select Xcode.app, accept license, and download iOS Simulator runtime\n"

# --- macOS ---

macos:
	./build.sh release test

macos-debug:
	./build.sh debug test

install:
	./build.sh release app

run: macos-debug
	./build/Kea.app/Contents/MacOS/Kea --temp-profile $(ARGS)

# --- iOS / iPadOS ---

ios-sim: lines
	@$(call RUN_ZIG_IOS,-Dtarget=$(IOS_SIM_TARGET) -Doptimize=$(OPT))
	@echo "built: zig/zig-out/ios/Kea.app ($(IOS_SIM_TARGET), $(OPT))"

ios-device: lines
	@$(call RUN_ZIG_IOS,-Dtarget=$(IOS_DEV_TARGET) -Doptimize=$(OPT))
	@echo "built: zig/zig-out/ios/Kea.app ($(IOS_DEV_TARGET), $(OPT))"

ios-obj:
	@$(call RUN_ZIG_IOS,ios-obj -Dtarget=$(IOS_SIM_TARGET) -Doptimize=$(OPT))
	@$(call RUN_ZIG_IOS,ios-obj -Dtarget=$(IOS_DEV_TARGET) -Doptimize=$(OPT))
	@ls -lh zig/zig-out/lib/Kea-ios.o

ios-check: ios-obj
	@python3 -c 'import re, subprocess; obj = "zig/zig-out/lib/Kea-ios.o"; \
	undef = {p[-1] for l in subprocess.check_output(["/usr/bin/nm", "-u", obj], text=True).splitlines() if (p := l.split())}; \
	bad_ext = sorted(undef & {"_posix_spawn", "_posix_spawnp", "_proc_pid_rusage", "_SecItemImport", "_SecTaskCreateFromSelf", "_SecTaskCopyValueForEntitlement", "_IOPSCopyPowerSourcesInfo", "_IOPSGetProvidingPowerSourceType", "_IONotificationPortCreate", "_CGWarpMouseCursorPosition", "_CGAssociateMouseAndMouseCursorPosition", "_CGSessionCopyCurrentDictionary", "_CGEventSourceSecondsSinceLastEventType", "_IOPMAssertionCreateWithName", "_IOPMAssertionRelease", "_IOPMAssertionDeclareUserActivity", "_SCDynamicStoreCopyComputerName"}); \
	assert not bad_ext, f"Forbidden macOS externs: {bad_ext}"; \
	cstr = {p[1] for sec in ("__cstring", "__objc_methname") for l in subprocess.check_output(["/usr/bin/otool", "-v", "-s", "__TEXT", sec, obj], text=True, errors="replace").splitlines() if len(p := l.split(None, 1)) == 2 and re.fullmatch(r"[0-9a-fA-F]{16}", p[0])}; \
	bad_ak = sorted(cstr & {"NSAlert", "NSOpenPanel", "NSSavePanel", "NSPasteboard", "NSWorkspace", "NSTask", "SFCertificatePanel", "NSAppearance", "NSPopUpButton", "NSVisualEffectView", "NSProgressIndicator", "NSSharingServicePicker", "NSPrintOperation", "NSRunningApplication", "NSSpellChecker", "NSHapticFeedbackManager", "NSIndexSpecifier"}); \
	assert not bad_ak, f"Forbidden AppKit classes: {bad_ak}"; \
	bad_spi = sorted(s for s in cstr if s.startswith(("_WK", "WKPage", "WKNotification", "_CFHostIsDomainTopLevel")) or s in {"_web_processIdentifier", "_inspector", "_printOperationWithPrintInfo:forFrame:", "_isPlayingAudio", "_pageExtendedBackgroundColor", "_setDrawsBackground:"}); \
	assert not bad_spi, f"Forbidden private SPIs: {bad_spi}"; \
	print(f"ios-check PASS: {len(undef)} undefined symbols audited, 0 macOS externs, 0 AppKit classes, 0 private SPIs")'

sim-boot-ipad:
	@$(call BOOT_SIM,iPad,iPad Pro)

sim-boot-iphone:
	@$(call BOOT_SIM,iPhone,iPhone .* Pro)

ios-run:
	@if ! xcrun simctl list devices booted 2>/dev/null | grep -q "(Booted)"; then \
		$(MAKE) --no-print-directory sim-boot-ipad; \
	fi
	@$(call RUN_ZIG_IOS,run -Dtarget=$(IOS_SIM_TARGET) -Doptimize=$(OPT) $(if $(ARGS),-- $(ARGS),))

ios-run-ipad: sim-boot-ipad
	@$(call RUN_ZIG_IOS,run -Dtarget=$(IOS_SIM_TARGET) -Doptimize=$(OPT) $(if $(ARGS),-- $(ARGS),))

ios-run-iphone: sim-boot-iphone
	@$(call RUN_ZIG_IOS,run -Dtarget=$(IOS_SIM_TARGET) -Doptimize=$(OPT) $(if $(ARGS),-- $(ARGS),))

ios-watch:
	@if ! xcrun simctl list devices booted 2>/dev/null | grep -q "(Booted)"; then \
		$(MAKE) --no-print-directory sim-boot-ipad; \
	fi
	@$(call RUN_ZIG_IOS,run --watch -Dtarget=$(IOS_SIM_TARGET) -Doptimize=$(OPT) $(if $(ARGS),-- $(ARGS),))

# --- Verification & Hygiene ---

lines:
	cd zig/nanoui && zig build lines
	cd zig && zig build lines

test:
	cd zig/nanoui && zig build test
	cd zig && zig build test

ui-test:
	cd zig && zig build ui-test

e2e:
	cd zig && zig build e2e

perf:
	cd zig && zig build perf

smooth:
	cd zig && zig build smooth

snapshots:
	cd zig && zig build snapshots

check: lines test ui-test ios-check

clean:
	rm -rf build zig/zig-out zig/nanoui/zig-out

# --- Xcode & Simulator Setup ---

xcode-check:
	@printf "%-22s %s\n" "zig:" "$$(zig version 2>/dev/null || echo MISSING)"
	@printf "%-22s %s\n" "xcode-select:" "$$(xcode-select -p 2>/dev/null || echo MISSING)"
	@XB="$$(xcodebuild -version 2>/dev/null | tr '\n' ' ' || true)"; printf "%-22s %s\n" "xcodebuild:" "$${XB:-MISSING (pointed at CommandLineTools)}"
	@printf "%-22s %s\n" "iphoneos SDK:" "$$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || echo MISSING)"
	@printf "%-22s %s\n" "iphonesimulator SDK:" "$$(xcrun --sdk iphonesimulator --show-sdk-path 2>/dev/null || echo MISSING)"
	@RT="$$(xcrun simctl list runtimes iOS 2>/dev/null | grep -E 'iOS ' | tr '\n' ' ' || true)"; printf "%-22s %s\n" "iOS runtimes:" "$${RT:-MISSING}"

xcode-install:
	@command -v mas >/dev/null 2>&1 || brew install mas
	@echo "Downloading & installing Xcode from Mac App Store (id $(XCODE_MAS_ID))..."
	@(mas get $(XCODE_MAS_ID) || mas install $(XCODE_MAS_ID)) || { \
		echo "mas needs an interactive TTY for sudo / App Store auth; opening Xcode in App Store.app..."; \
		mas open $(XCODE_MAS_ID) || open "macappstore://apps.apple.com/app/id$(XCODE_MAS_ID)"; \
		exit 1; \
	}
	@echo "Xcode installed. Run 'make xcode-setup' next to select Xcode and install the iOS Simulator runtime."

xcode-xcodes:
	@command -v xcodes >/dev/null 2>&1 || brew install xcodes aria2
	xcodes install $(XCODE_FLAGS)
	@echo "Xcode installed. Run 'make xcode-setup' next to select Xcode and install the iOS Simulator runtime."

xcode-setup:
	@XCODE_DEV=""; \
	for app in /Applications/Xcode.app /Applications/Xcode-beta.app /Applications/Xcode-*.app /Applications/Xcode_*.app /Applications/Xcode*.app; do \
		if [ -d "$$app/Contents/Developer" ]; then XCODE_DEV="$$app/Contents/Developer"; break; fi; \
	done; \
	if [ -z "$$XCODE_DEV" ]; then \
		echo "error: no /Applications/Xcode*.app found. Run 'make xcode-install' or 'make xcode-xcodes' first." >&2; \
		exit 1; \
	fi; \
	echo "Selecting $$XCODE_DEV (sudo password required)..."; \
	sudo xcode-select -s "$$XCODE_DEV"; \
	sudo xcodebuild -license accept; \
	sudo xcodebuild -runFirstLaunch; \
	rm -rf zig/.zig-cache zig/nanoui/.zig-cache; \
	echo "Downloading iOS Simulator platform runtime..."; \
	xcodebuild -downloadPlatform iOS; \
	$(MAKE) --no-print-directory xcode-check
