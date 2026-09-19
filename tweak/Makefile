TARGET := iphone:clang:latest:16.0
ARCHS := arm64
FINALPACKAGE := 1

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := spotifyglass

SG_VERSION := $(shell sed -n 's/^Version: //p' control)

# Every source under Sources/, so a new feature needs no Makefile edit. Features/Flags/SGFlagList.m
# is generated from the IPA by scripts/extract-flags.py.
spotifyglass_FILES := $(shell find Sources -name '*.m' -o -name '*.x' -o -name '*.swift' | sort)
spotifyglass_CFLAGS := -fobjc-arc -ISources -DSG_VERSION=\"$(SG_VERSION)\"
spotifyglass_FRAMEWORKS := UIKit QuartzCore UniformTypeIdentifiers MediaPlayer CoreImage ImageIO CoreGraphics AVFoundation CoreMedia AudioToolbox JavaScriptCore VideoToolbox Network
spotifyglass_SWIFTFLAGS := -swift-version 5
# Runtime swizzling instead of Substrate so the dylib has no extra dependency inside the IPA.
spotifyglass_LOGOS_DEFAULT_GENERATOR := internal

include $(THEOS_MAKE_PATH)/tweak.mk
