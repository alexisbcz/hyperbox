export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

# Sign with your Apple Development certificate when you have one: macOS ties permissions (the microphone)
# to the signature, and an ad-hoc one changes with every build, so each rebuild would ask again.
IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | grep -m1 -o '"Apple Development[^"]*"')
SIGNING := $(if $(IDENTITY),CODE_SIGN_IDENTITY=$(IDENTITY) CODE_SIGN_STYLE=Manual)

run: build
	-osascript -e 'tell application id "dev.alexis.Hyperbox" to quit' 2>/dev/null
	while lsappinfo find bundleid=dev.alexis.Hyperbox | grep -q ASN; do sleep 0.2; done
	open -n build/Build/Products/Debug/Hyperbox.app

build:
	xcodegen generate -q
	xcodebuild -project Hyperbox.xcodeproj -scheme Hyperbox -derivedDataPath build -quiet build $(SIGNING)

dmg:
	scripts/build-dmg.sh

.PHONY: run build dmg
