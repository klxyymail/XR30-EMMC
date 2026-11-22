#
# luci-app-autoupdate —— 从自有 GitHub 仓库检查固件更新
#
# 基于 luci-app-autoupdate（Hyy2001X 原创 / xztxy 改编）的 UI 框架重做核心逻辑：
# 原版硬绑定 AutoBuild-Actions 的固件命名规范（文件名内嵌 10 位时间戳 + 6 位哈希），
# 与本仓库的 ImmortalWrt 标准命名不兼容，故检测/比对/校验三处全部重写。
#
# 依赖去掉了原版的 jq + bc（约 300KB），改用它自带却没用上的 jsonfilter。
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-autoupdate
PKG_VERSION:=2.0.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-3.0
PKG_MAINTAINER:=klxyymail

LUCI_TITLE:=LuCI 固件更新（GitHub Release）
LUCI_DESCRIPTION:=从自有 GitHub 仓库检查新固件，可下载并提示手动刷写
LUCI_DEPENDS:=+uclient-fetch +wget-ssl +jsonfilter +luci-compat
LUCI_PKGARCH:=all

# feeds 已装时用 feeds/luci/luci.mk，否则回退到 package/feeds/luci
LUCI_MK:=$(TOPDIR)/feeds/luci/luci.mk
ifeq ($(wildcard $(LUCI_MK)),)
LUCI_MK:=$(TOPDIR)/package/feeds/luci/luci.mk
endif
include $(LUCI_MK)

$(eval $(call BuildPackage,$(PKG_NAME)))
