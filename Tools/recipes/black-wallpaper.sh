#!/bin/sh
# Makes every desktop plain black, and hides the desktop widgets.
# os: macOS
set -e
black="/System/Library/Desktop Pictures/Solid Colors/Black.png"
# Through AppKit, which needs no Automation permission, unlike asking Finder or System Events.
osascript -l JavaScript - "$black" <<'JS'
ObjC.import("AppKit");
function run(argv) {
    const url = $.NSURL.fileURLWithPath(argv[0]);
    const options = $.NSDictionary.dictionaryWithObjectForKey($.NSColor.blackColor, $.NSWorkspaceDesktopImageFillColorKey);
    const screens = $.NSScreen.screens;
    for (let i = 0; i < screens.count; i++) {
        if (!$.NSWorkspace.sharedWorkspace.setDesktopImageURLForScreenOptionsError(url, screens.objectAtIndex(i), options, null)) {
            throw new Error("Couldn't set the desktop picture.");
        }
    }
}
JS
defaults write com.apple.WindowManager StandardHideWidgets -bool true
defaults write com.apple.WindowManager StageManagerHideWidgets -bool true
killall WindowManager 2>/dev/null || true
echo "The desktop is black."
