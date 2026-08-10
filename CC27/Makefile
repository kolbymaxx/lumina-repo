TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard Preferences

# Default rootless; CI / local builds override with THEOS_PACKAGE_SCHEME=roothide
THEOS_PACKAGE_SCHEME ?= rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = CC27

CC27_FILES = \
	src/Tweak.x \
	src/CC27Prefs.m \
	src/CC27Glass.m \
	src/CC27LayoutStore.m \
	src/CC27ModuleCatalog.m \
	src/CC27EditSession.m \
	src/CC27GalleryController.m \
	../SwiftPeek/src/SPDumpWriter.m \
	../SwiftPeek/src/SPPrefs.m

# SwiftPeek recon core, linked in-process. CC27 already runs inside SpringBoard,
# so it can produce SwiftPeek-format dumps without injecting a second dylib there
# — the SpringBoard filter guards on SwiftPeek itself stay untouched.
#
# Only these two are linked, on purpose:
#   SPFieldWalk.m  — FOVO walker, SIGSEGV'd on Music. Must never run in SpringBoard.
#   SPSwiftMeta.m  — Swift metadata; CC's UI is ObjC CCUI*, so it buys nothing.
# CC27 must also never call SPPrefBool: that reads SwiftPeek's own prefs domain.
# Recon is gated on CC27Prefs.reconDump instead.
CC27_CFLAGS = -fobjc-arc -Iheaders -Isrc -I../SwiftPeek/src -Wno-unused-variable -Wno-deprecated-declarations
CC27_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore CoreFoundation
# Private CC frameworks are resolved at runtime via NSClassFromString / Logos %hook.

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += prefs provider
include $(THEOS_MAKE_PATH)/aggregate.mk
