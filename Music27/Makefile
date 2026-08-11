TARGET := iphone:clang:16.5:15.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = Music Preferences

# Default rootless; CI / local builds override with THEOS_PACKAGE_SCHEME=roothide
THEOS_PACKAGE_SCHEME ?= rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Music27

# SPKit: shared source, not a linked dependency. Each tweak compiles its own
# copy, so a change here cannot break an installed tweak that has not rebuilt.
# src/spkit is a symlink to ../SPKit — Theos puts object files under
# .theos/obj/<source path>, and a literal ../ there escapes the build directory.
Music27_FILES = \
	src/spkit/SPKRuntime.m \
	src/spkit/SPKOverlayWindow.m \
	src/Tweak.x \
	src/GlassTabBar.x \
	src/AlbumControls.x \
	src/NowPlayingGlass.x \
	src/ColorTheme.x \
	src/LibraryPins.x \
	src/Helpers.m \
	src/M27GlassChrome.m \
	src/M27FloatingDock.m \
	src/M27Prefs.m \
	src/M27ColorTheme.m \
	src/M27PinStore.m \
	src/M27PinnedHeaderView.m

Music27_CFLAGS = -fobjc-arc -Wno-unused-variable -Wno-deprecated-declarations \
	-I$(THEOS_PROJECT_DIR)/src/spkit -DSPK_CLASS_PREFIX=M27SPK
Music27_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore MediaPlayer CoreFoundation
# CoreFoundation used by M27Prefs CFPreferences fallback.

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += music27prefs
include $(THEOS_MAKE_PATH)/aggregate.mk
