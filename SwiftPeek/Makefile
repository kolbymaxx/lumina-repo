TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = Music SpringBoard
# Default rootless; CI / local builds override with THEOS_PACKAGE_SCHEME=roothide
THEOS_PACKAGE_SCHEME ?= rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SwiftPeek

# ObjC only — a Swift-linked tweak dylib was enough to break Music UI on device.
SwiftPeek_FILES = src/SPAttach.m \
	src/SPPrefs.m \
	src/SPSwiftMeta.m \
	src/SPDumpWriter.m \
	src/SPFieldWalk.m \
	src/SPRenderPeek.m \
	src/SPIconPeek.m

SwiftPeek_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function -DDISABLE_ROOTLESS_COMPAT_WARNING=1
SwiftPeek_FRAMEWORKS = UIKit Foundation CoreGraphics

include $(THEOS_MAKE_PATH)/tweak.mk

after-stage::
	@mkdir -p "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences"
	@cp -f layout/Library/PreferenceLoader/Preferences/SwiftPeek.plist \
		"$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/"
