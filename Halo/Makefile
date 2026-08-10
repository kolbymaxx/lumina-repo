TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard
# Default rootless; CI / local builds override with THEOS_PACKAGE_SCHEME=roothide
THEOS_PACKAGE_SCHEME ?= rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Halo

Halo_FILES = src/Tweak.x \
	src/HAPrefs.m \
	src/HAGeometry.m \
	src/HAActivity.m \
	src/HACapsuleView.m \
	src/HAPresenter.m \
	src/HAMediaRemote.m \
	src/HASources.m

Halo_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -DDISABLE_ROOTLESS_COMPAT_WARNING=1
Halo_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore
# MediaRemote is resolved at runtime via dlopen — never linked.

include $(THEOS_MAKE_PATH)/tweak.mk

after-stage::
	@mkdir -p "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences"
	@cp -f layout/Library/PreferenceLoader/Preferences/Halo.plist \
		"$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/"
