#!/bin/bash
set -x

# =========================================================
# 基础变量（防止 banner 里 $OP_author 为空）
# =========================================================
OP_author="kubulama"

# =========================================================
# 内核 vermagic（保持你原逻辑）
# =========================================================
sed -ie 's/^\(.\).*vermagic$/\1cp $(TOPDIR)\/.vermagic $(LINUX_DIR)\/.vermagic/' include/kernel-defaults.mk
grep HASH target/linux/generic/kernel-6.12 | awk -F'HASH-' '{print $2}' | awk '{print $1}' | md5sum | awk '{print $1}' > .vermagic

# =========================================================
# 私有 feeds
# =========================================================
git clone -b packages --depth=1 --single-branch https://github.com/shiyu1314/openwrt-feeds package/xd
git clone -b porxy   --depth=1 --single-branch https://github.com/shiyu1314/openwrt-feeds package/porxy

# smartdns 依赖清理（你原逻辑，保留）
[ -f package/xd/smartdns/Makefile ] && sed -i -E \
  -e 's/[[:space:]]*PACKAGE_smartdns-ui:rust-bindgen\/host//g' \
  -e 's/[[:space:]]*rust-bindgen\/host//g' \
  -e 's/[[:space:]]*PACKAGE_smartdns-ui://g' \
  package/xd/smartdns/Makefile

# daed：使用官方 runfiles，避免 CI 编译爆炸（你原逻辑，保留）
rm -rf package/porxy/daed package/porxy/luci-app-daed

# 清理不需要的官方应用（你原逻辑，保留）
rm -rf feeds/luci/applications/{luci-app-dockerman,luci-app-samba4,luci-app-aria2,luci-app-diskman}
rm -rf feeds/packages/net/{samba4,v2ray-geodata,mosdns,sing-box,aria2,ariang,adguardhome}

# 移除 attendedsysupgrade（你原逻辑，保留）
sed -i '/luci-app-attendedsysupgrade/d' \
    feeds/luci/collections/luci/Makefile \
    feeds/luci/collections/luci-light/Makefile \
    feeds/luci/collections/luci-ssl/Makefile \
    feeds/luci/collections/luci-ssl-openssl/Makefile

# =========================================================
# Luci patch（你原逻辑，保留）
# =========================================================
pushd feeds/luci || exit 1
for patch in *.patch; do
    [ -f "$patch" ] || continue
    echo "Applying $patch ..."
    patch -p1 --no-backup-if-mismatch < "$patch" || {
        echo "ERROR: Failed to apply $patch"
        popd
        exit 1
    }
done
popd

# =========================================================
# JCG Q30 PRO 设备支持（你原逻辑，保留）
# =========================================================
filogic_mk="target/linux/mediatek/image/filogic.mk"
if ! grep -q "Device/jcg_q30-pro" "$filogic_mk"; then
    awk '
        /define Device\/openwrt_one/ && !inserted {
            print ""
            print "define Build/jcg-q30-pro-sysupgrade-bin"
            print "\tsh $(TOPDIR)/scripts/sysupgrade-tar.sh \\"
            print "\t\t--board $(if $(BOARD_NAME),$(BOARD_NAME),$(DEVICE_NAME)) \\"
            print "\t\t--kernel $@ \\"
            print "\t\t--rootfs $(IMAGE_ROOTFS) \\"
            print "\t\t$@.tar"
            print "\tmv $@.tar $@"
            print "endef"
            print ""
            print "define Device/jcg_q30-pro"
            print "  DEVICE_VENDOR := JCG"
            print "  DEVICE_MODEL := Q30 PRO"
            print "  DEVICE_DTS := mt7981b-jcg-q30-pro"
            print "  DEVICE_DTS_DIR := ../dts"
            print "  UBINIZE_OPTS := -E 5"
            print "  BLOCKSIZE := 128k"
            print "  PAGESIZE := 2048"
            print "  KERNEL_IN_UBI := 1"
            print "  UBOOTENV_IN_UBI := 1"
            print "  IMAGES := sysupgrade.bin sysupgrade.itb"
            print "  KERNEL := kernel-bin | gzip | \\"
            print "\tpad-to 64k"
            print "  IMAGE/sysupgrade.bin := append-kernel | \\"
            print "\tfit gzip $$(KDIR)/image-$$(firstword $$(DEVICE_DTS)).dtb | \\"
            print "\tjcg-q30-pro-sysupgrade-bin | append-metadata"
            print "  IMAGE/sysupgrade.itb := append-kernel | \\"
            print "\tfit gzip $$(KDIR)/image-$$(firstword $$(DEVICE_DTS)).dtb external-static-with-rootfs | append-metadata"
            print "  DEVICE_PACKAGES :="
            print "  ARTIFACTS := preloader.bin bl31-uboot.fip"
            print "  ARTIFACT/preloader.bin := mt7981-bl2 spim-nand-ddr3"
            print "  ARTIFACT/bl31-uboot.fip := mt7981-bl31-uboot jcg_q30-pro"
            print "endef"
            print "TARGET_DEVICES += jcg_q30-pro"
            print ""
            inserted = 1
        }
        { print }
    ' "$filogic_mk" > "$filogic_mk.tmp"
    mv "$filogic_mk.tmp" "$filogic_mk"
fi

# 跳过 Q30 PRO DTS patch（你原逻辑，保留）
for patch in *.patch; do
    [ -f "$patch" ] || continue
    [ "$patch" = "005-mediatek-filogic-add-jcg-q30-pro.patch" ] && continue
    echo "Applying $patch ..."
    patch -p1 --no-backup-if-mismatch < "$patch" || {
        echo "ERROR: Failed to apply $patch"
        exit 1
    }
done

# =========================================================
# Rust / Golang / 核心组件替换（你原逻辑，保留）
# =========================================================
RUST_VERSION=1.95.0
RUST_HASH=62b67230754da642a264ca0cb9fc08820c54e2ed7b3baba0289876d4cdb48c08
sed -ri "s/(PKG_VERSION:=)[^\"]*/\1$RUST_VERSION/;s/(PKG_HASH:=)[^\"]*/\1$RUST_HASH/" feeds/packages/lang/rust/Makefile

rm -rf package/system/fstools
git clone --depth=1 https://github.com/sbwml/package_system_fstools -b openwrt-25.12 package/system/fstools

rm -rf package/utils/util-linux
git clone --depth=1 https://github.com/sbwml/package_utils_util-linux -b openwrt-25.12 package/utils/util-linux

rm -rf feeds/packages/libs/nghttp3
git clone --depth=1 https://github.com/sbwml/package_libs_nghttp3 package/libs/nghttp3

rm -rf feeds/packages/libs/ngtcp2
git clone --depth=1 https://github.com/sbwml/package_libs_ngtcp2 package/libs/ngtcp2

rm -rf feeds/packages/net/curl
git clone --depth=1 https://github.com/sbwml/feeds_packages_net_curl feeds/packages/net/curl

# uwsgi 调优（你原逻辑，保留）
sed -i '$a cgi-timeout = 600' feeds/packages/net/uwsgi/files-luci-support/luci-*.ini
sed -i '/limit-as/c\limit-as = 5000' feeds/packages/net/uwsgi/files-luci-support/luci-webui.ini
sed -i "s/procd_set_param stderr 1/procd_set_param stderr 0/g" feeds/packages/net/uwsgi/files/uwsgi.init
sed -i 's/threads = 1/threads = 2/g' feeds/packages/net/uwsgi/files-luci-support/luci-webui.ini
sed -i 's/processes = 3/processes = 4/g' feeds/packages/net/uwsgi/files-luci-support/luci-webui.ini
sed -i 's/cheaper = 1/cheaper = 2/g' feeds/packages/net/uwsgi/files-luci-support/luci-webui.ini

# rpcd / rpc.js 超时修复（你原逻辑，保留）
sed -i 's/option timeout 30/option timeout 60/g' package/system/rpcd/files/rpcd.config
sed -i 's#20) \* 1000#60) \* 1000#g' feeds/luci/modules/luci-base/htdocs/luci-static/resources/rpc.js

# luci-compat 描述清理（你原逻辑，保留）
sed -i '/<br \/>/d' feeds/luci/modules/luci-compat/luasrc/view/cbi/full_valuefooter.htm'

# golang 26.x（你原逻辑，保留）
rm -rf feeds/packages/lang/golang
git clone --depth=1 https://github.com/sbwml/packages_lang_golang -b 26.x feeds/packages/lang/golang

# =========================================================
# 【关键】第三方 LuCI 应用（你新增部分，已修正）
# =========================================================
# iStore 软件中心
rm -rf package/luci-app-store
git clone --depth=1 https://github.com/linkease/istore.git package/luci-app-store

# 集客 AC 控制器
rm -rf package/luci-app-gecoosac
git clone --depth=1 https://github.com/laipeng668/luci-app-gecoosac package/luci-app-gecoosac

# tcpdump 抓包插件（修正为 shallow clone）
rm -rf package/luci-app-tcpdump
git clone --depth=1 https://github.com/KFERMercer/luci-app-tcpdump.git package/luci-app-tcpdump

# =========================================================
# feeds 更新 & 安装（必须在插件 clone 之后）
# =========================================================
./scripts/feeds update -a
./scripts/feeds install -a

# =========================================================
# 【关键】强制关闭 nginx（去 nginx，防冲突）
# =========================================================
sed -i '/CONFIG_PACKAGE_nginx=y/s/y/=n/g' .config
sed -i '/CONFIG_PACKAGE_luci-nginx=y/s/y/=n/g' .config
sed -i '/CONFIG_PACKAGE_nginx-ssl=y/s/y/=n/g' .config

# =========================================================
# 【关键】iStore + 依赖写入 .config
# =========================================================
cat >> .config << EOF
CONFIG_PACKAGE_luci-app-store=y
CONFIG_PACKAGE_luci-compat=y
CONFIG_PACKAGE_xz-utils=y
CONFIG_PACKAGE_curl=y
CONFIG_PACKAGE_luci-app-gecoosac=y
CONFIG_PACKAGE_luci-app-tcpdump=y
CONFIG_PACKAGE_tcpdump=y
EOF

make defconfig

# =========================================================
# ttyd 自动登录 root（你原逻辑，移到 .config 稳定后）
# =========================================================
sed -i 's|/bin/login|/bin/login -f root|g' feeds/packages/utils/ttyd/files/ttyd.config

# =========================================================
# Banner & Release 信息（你原逻辑，变量已定义）
# =========================================================
rm -rf package/base-files/files/etc/banner

sed -i "s/%D %V %C/%D %V $(TZ=UTC-8 date +%Y.%m.%d)/" package/base-files/files/etc/openwrt_release
sed -i "s/%R/by $OP_author/" package/base-files/files/etc/openwrt_release

date=$(date +"%Y-%m-%d")

cat >> package/base-files/files/etc/banner << EOF

  _______                     ________        __
 |       |.-----.-----.-----.|  |  |  |.----.|  |_
 |   -   ||  _  |  -__|     ||  |  |  ||   _||   _|
 |_______||   __|_____|__|__||________||__|  |____|
          |__|
 -----------------------------------------------------
         %D ${date} by $OP_author
 -----------------------------------------------------
EOF
