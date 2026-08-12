TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard
# Default rootless; CI / local builds override with THEOS_PACKAGE_SCHEME=roothide
THEOS_PACKAGE_SCHEME ?= rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Glyph

Glyph_FILES = src/Tweak.x \
	src/GLPrefs.m \
	src/GLThemeStore.m \
	src/GLIconCache.m

Glyph_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -DDISABLE_ROOTLESS_COMPAT_WARNING=1
Glyph_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk

after-stage::
	@mkdir -p "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences"
	@cp -f layout/Library/PreferenceLoader/Preferences/Glyph.plist \
		"$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/"
