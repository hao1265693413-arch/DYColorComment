ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = Aweme

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DYColorComment
DYColorComment_FILES = DYColorComment.m
DYColorComment_CFLAGS = -fobjc-arc -Wall -Wextra -Wno-unused-parameter
DYColorComment_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk