APP := Slant.app
CONFIG := release
BUNDLE := .build/$(APP)

.PHONY: build test clean install uninstall demo go start stop

build:
	swift build -c $(CONFIG)
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	cp .build/$(CONFIG)/SlantApp $(BUNDLE)/Contents/MacOS/SlantApp
	@for b in .build/$(CONFIG)/*.bundle; do \
		[ -e "$$b" ] && cp -R "$$b" $(BUNDLE)/Contents/Resources/ || true; \
	done
	@echo "Built $(BUNDLE)"

test:
	swift run -c debug SlantTests

clean:
	rm -rf .build

# One command from a fresh clone. Builds, installs, and opens the one settings
# pane macOS will not let an app open for itself.
go: install
	@echo ""
	@echo "  Slant is in /Applications."
	@echo ""
	@echo "  One manual step, because macOS requires it:"
	@echo "    1. In the pane that just opened, find Slant and REMOVE it with the - button"
	@echo "       (skip if it is not listed yet)"
	@echo "    2. Add it back with +, choosing /Applications/Slant.app"
	@echo "    3. Make sure its switch is on"
	@echo ""
	@echo "  Then:  make start"
	@echo ""
	@open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture" || true

# Launch the installed app. Uses `open` so macOS attributes the Screen Recording
# permission to Slant; running the binary straight from a shell attributes it to
# the terminal instead, and it will be refused however many times you grant it.
start:
	@open -a /Applications/$(APP)
	@echo "Slant is running in the menu bar. Close the lid slowly to see it."
	@echo "Stop it with: make stop"

# Copy to /Applications so macOS privacy permissions attach to a stable path.
# An unsigned app is tracked by path, so running it from .build/ would mean
# re-granting Screen Recording on every rebuild.
install: build
	rm -rf /Applications/$(APP)
	cp -R $(BUNDLE) /Applications/$(APP)
	codesign --force --deep --sign - /Applications/$(APP) 2>/dev/null || true
	@echo "Installed /Applications/$(APP)"

uninstall:
	rm -rf /Applications/$(APP)
	@echo "Removed /Applications/$(APP)"

# Runs the ALREADY-INSTALLED app without rebuilding or reinstalling.
# Reinstalling changes the code hash, which makes macOS revoke Screen Recording
# permission. Use this to re-run after granting, and `make install` only when
# the code actually changed.
demo:
	@echo "Demo runs 3 cycles then quits by itself."
	@echo "To stop it early:  pkill -f SlantApp"
	SLANT_DEMO=1 /Applications/$(APP)/Contents/MacOS/SlantApp

# Emergency stop, for when the overlay is covering the menu bar.
stop:
	-pkill -f SlantApp
	@echo "Slant stopped." 
