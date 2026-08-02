#!/bin/bash

function git_sparse_clone() {
  branch="$1" repourl="$2" && shift 2
  git clone --depth=1 -b $branch --single-branch --filter=blob:none --sparse $repourl
  repodir=$(echo $repourl | awk -F '/' '{print $(NF)}')
  cd $repodir && git sparse-checkout set $@
  mv -f $@ ../
  cd .. && rm -rf $repodir
}

set -x

# =========================================================
# 基础变量
# =========================================================
OP_author="kubulama"

# =========================================================
# 内核 vermagic（固定，防止 kmod 版本不匹配）
# =========================================================
sed -ie 's/^\(.\).*vermagic$/\1cp $(TOPDIR)\/.vermagic $(LINUX_DIR)\/.vermagic/' include/kernel-defaults.mk
grep HASH target/linux/generic/kernel-6.12 | awk -F'HASH-' '{print $2}' | awk '{print $1}' | md5sum | awk '{print $1}' > .vermagic

# =========================================================
# 私有 feeds
# =========================================================
git clone -b packages --depth 1 --single-branch https://github.com/shiyu1314/openwrt-feeds package/xd
git clone -b porxy --depth 1 --single-branch https://github.com/shiyu1314/openwrt-feeds package/porxy

# smartdns 依赖清理
[ -f package/xd/smartdns/Makefile ] && sed -i -E \
  -e 's/[[:space:]]*PACKAGE_smartdns-ui:rust-bindgen\/host//g' \
  -e 's/[[:space:]]*rust-bindgen\/host//g' \
  -e 's/[[:space:]]*PACKAGE_smartdns-ui://g' \
  package/xd/smartdns/Makefile

# daed：使用官方 runfiles，避免 CI 编译爆炸
rm -rf package/porxy/daed package/porxy/luci-app-daed

# 清理不需要的官方应用
rm -rf feeds/luci/applications/{luci-app-dockerman,luci-app-samba4,luci-app-aria2,luci-app-diskman}
rm -rf feeds/packages/net/{samba4,v2ray-geodata,mosdns,sing-box,aria2,ariang,adguardhome}

# drop attendedsysupgrade
sed -i '/luci-app-attendedsysupgrade/d' \
    feeds/luci/collections/luci-nginx/Makefile \
    feeds/luci/collections/luci-ssl-openssl/Makefile \
    feeds/luci/collections/luci-ssl/Makefile \
    feeds/luci/collections/luci/Makefile

# 原版：把默认 uhttpd 替换为 luci-nginx
sed -i 's/+uhttpd /+luci-nginx /g' feeds/luci/collections/luci/Makefile
sed -i 's/+uhttpd-mod-ubus //' feeds/luci/collections/luci/Makefile
sed -i 's/+uhttpd /+luci-nginx /g' feeds/luci/collections/luci-light/Makefile
sed -i "s/+luci /+luci-nginx /g" feeds/luci/collections/luci-ssl-openssl/Makefile
sed -i "s/+luci /+luci-nginx /g" feeds/luci/collections/luci-ssl/Makefile
sed -i 's/+uhttpd +uhttpd-mod-ubus /+luci-nginx /g' feeds/packages/net/wg-installer/Makefile
sed -i '/uhttpd-mod-ubus/d' feeds/luci/collections/luci-light/Makefile
sed -i 's/+luci-nginx \\$/+luci-nginx/' feeds/luci/collections/luci-light/Makefile

# =========================================================
# 应用 luci patches
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
# JCG Q30 PRO 设备支持
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

# 应用其他 patches（跳过 JCG Q30 PRO DTS patch）
for patch in *.patch; do
    [ -f "$patch" ] || continue
    if [ "$patch" = "005-mediatek-filogic-add-jcg-q30-pro.patch" ]; then
        echo "Skipping $patch: JCG Q30 PRO profile is managed by sh/op.sh"
        continue
    fi
    echo "Applying $patch ..."
    patch -p1 --no-backup-if-mismatch < "$patch" || {
        echo "ERROR: Failed to apply $patch"
        exit 1
    }
done

# =========================================================
# Rust / 核心组件替换
# =========================================================
RUST_VERSION=1.95.0
RUST_HASH=62b67230754da642a264ca0cb9fc08820c54e2ed7b3baba0289876d4cdb48c08
sed -ri "s/(PKG_VERSION:=)[^\"]*/\1$RUST_VERSION/;s/(PKG_HASH:=)[^\"]*/\1$RUST_HASH/" feeds/packages/lang/rust/Makefile

# fstools
rm -rf package/system/fstools
git clone --depth=1 https://github.com/sbwml/package_system_fstools -b openwrt-25.12 package/system/fstools

# util-linux
rm -rf package/utils/util-linux
git clone --depth=1 https://github.com/sbwml/package_utils_util-linux -b openwrt-25.12 package/utils/util-linux

# nghttp3
rm -rf feeds/packages/libs/nghttp3
git clone --depth=1 https://github.com/sbwml/package_libs_nghttp3 package/libs/nghttp3

# ngtcp2
rm -rf feeds/packages/libs/ngtcp2
git clone --depth=1 https://github.com/sbwml/package_libs_ngtcp2 package/libs/ngtcp2

# curl
rm -rf feeds/packages/net/curl
git clone --depth=1 https://github.com/sbwml/feeds_packages_net_curl feeds/packages/net/curl

# =========================================================
# nginx
# =========================================================
rm -rf feeds/packages/net/nginx
git clone --depth=1 https://github.com/sbwml/feeds_packages_net_nginx feeds/packages/net/nginx -b openwrt-25.12
sed -i 's/procd_set_param stdout 1/procd_set_param stdout 0/g;s/procd_set_param stderr 1/procd_set_param stderr 0/g' feeds/packages/net/nginx/files/nginx.init

# nginx - ubus
sed -i 's/ubus_parallel_req 2/ubus_parallel_req 6/g' feeds/packages/net/nginx/files-luci-support/60_nginx-luci-support
sed -i '/ubus_parallel_req/a\        ubus_script_timeout 300;' feeds/packages/net/nginx/files-luci-support/60_nginx-luci-support

# nginx-util
sed -i '/\/etc\/nginx\/uci.conf.template/d' feeds/packages/net/nginx-util/Makefile

# =========================================================
# uwsgi 调优
# =========================================================
sed -i '$a cgi-timeout = 600' feeds/packages/net/uwsgi/files-luci-support/luci-*.ini
sed -i '/limit-as/c\limit-as = 5000' feeds/packages/net/uwsgi/files-luci-support/luci-webui.ini
sed -i "s/procd_set_param stderr 1/procd_set_param stderr 0/g" feeds/packages/net/uwsgi/files/uwsgi.init
sed -i 's/threads = 1/threads = 2/g' feeds/packages/net/uwsgi/files-luci-support/luci-webui.ini
sed -i 's/processes = 3/processes = 4/g' feeds/packages/net/uwsgi/files-luci-support/luci-webui.ini
sed -i 's/cheaper = 1/cheaper = 2/g' feeds/packages/net/uwsgi/files-luci-support/luci-webui.ini

# =========================================================
# rpcd / rpc.js 超时修复
# =========================================================
sed -i 's/option timeout 30/option timeout 60/g' package/system/rpcd/files/rpcd.config
sed -i 's#20) \* 1000#60) \* 1000#g' feeds/luci/modules/luci-base/htdocs/luci-static/resources/rpc.js

# luci-compat 描述清理
sed -i '/<br \/>/d' feeds/luci/modules/luci-compat/luasrc/view/cbi/full_valuefooter.htm

# =========================================================
# golang 26.x
# =========================================================
rm -rf feeds/packages/lang/golang
git clone --depth=1 https://github.com/sbwml/packages_lang_golang -b 26.x feeds/packages/lang/golang

# =========================================================
# 【第三方插件统一拉取（先删旧残留）】
# =========================================================

# ---- OpenAppFilter v6.1.8（含 luci-app-oaf + appfilter + kmod-oaf）----
rm -rf package/OpenAppFilter
git clone --depth 1 -b v6.1.8 https://github.com/destan19/OpenAppFilter package/OpenAppFilter

# ---- mufeng05 turboacc（官方25.12/fw4适配，自动匹配6.12内核）----
rm -rf package/luci-app-turboacc package/turboacc
curl -sSL https://raw.githubusercontent.com/mufeng05/turboacc/main/add_turboacc.sh -o add_turboacc.sh
bash add_turboacc.sh
rm -f add_turboacc.sh

# ---- iStore 软件中心 ----
rm -rf package/luci-app-store
git clone --depth=1 https://github.com/linkease/istore.git package/luci-app-store

# ---- 集客 AC 控制器 ----
rm -rf package/luci-app-gecoosac
git clone --depth=1 https://github.com/laipeng668/luci-app-gecoosac package/luci-app-gecoosac

# ---- tcpdump 抓包插件 ----
rm -rf package/luci-app-tcpdump
git clone --depth=1 https://github.com/KFERMercer/luci-app-tcpdump.git package/luci-app-tcpdump

# ---- ZeroTier（kiddin9 feed，跟进25.x新UCI，和iStore同源）----
rm -rf package/luci-app-zerotier package/zerotier
git clone --depth=1 https://github.com/kiddin9/openwrt-packages.git tmp_kiddin9
[ -d tmp_kiddin9/luci-app-zerotier ] && cp -r tmp_kiddin9/luci-app-zerotier package/luci-app-zerotier
[ -d tmp_kiddin9/zerotier ] && cp -r tmp_kiddin9/zerotier package/zerotier
rm -rf tmp_kiddin9

# =========================================================
# feeds 更新 & 安装（必须在所有插件 clone 之后）
# =========================================================
./scripts/feeds update -a
./scripts/feeds install -a

# =========================================================
# 【关键修复】强制关闭 nginx（去 nginx，防冲突）
# =========================================================
sed -i '/CONFIG_PACKAGE_nginx=y/s/y/=n/g' .config
sed -i '/CONFIG_PACKAGE_luci-nginx=y/s/y/=n/g' .config
sed -i '/CONFIG_PACKAGE_nginx-ssl=y/s/y/=n/g' .config

# =========================================================
# 【强制勾选】全部插件 + 全中文语言包
# 先删旧项，再追加，防止重复/被 defconfig 覆盖
# =========================================================
# ---- 清理旧配置 ----
sed -i '/CONFIG_PACKAGE_luci-app-store=/d' .config
sed -i '/CONFIG_PACKAGE_luci-compat=/d' .config
sed -i '/CONFIG_PACKAGE_xz-utils=/d' .config
sed -i '/CONFIG_PACKAGE_curl=/d' .config
sed -i '/CONFIG_PACKAGE_luci-i18n-base-zh-cn=/d' .config
sed -i '/CONFIG_PACKAGE_luci-app-gecoosac=/d' .config
sed -i '/CONFIG_PACKAGE_luci-app-tcpdump=/d' .config
sed -i '/CONFIG_PACKAGE_tcpdump=/d' .config
# OpenAppFilter
sed -i '/CONFIG_PACKAGE_luci-app-oaf=/d' .config
sed -i '/CONFIG_PACKAGE_appfilter=/d' .config
sed -i '/CONFIG_PACKAGE_kmod-oaf=/d' .config
sed -i '/CONFIG_PACKAGE_luci-i18n-oaf-zh-cn=/d' .config
# turboacc
sed -i '/CONFIG_PACKAGE_luci-app-turboacc=/d' .config
sed -i '/CONFIG_PACKAGE_turboacc=/d' .config
sed -i '/CONFIG_PACKAGE_luci-i18n-turboacc-zh-cn=/d' .config
# ZeroTier
sed -i '/CONFIG_PACKAGE_luci-app-zerotier=/d' .config
sed -i '/CONFIG_PACKAGE_zerotier=/d' .config
sed -i '/CONFIG_PACKAGE_luci-i18n-zerotier-zh-cn=/d' .config

# ---- 追加全部配置（全中文）----
cat >> .config << 'PKGEOF'
# === iStore & 基础依赖 ===
CONFIG_PACKAGE_luci-app-store=y
CONFIG_PACKAGE_luci-compat=y
CONFIG_PACKAGE_xz-utils=y
CONFIG_PACKAGE_curl=y
CONFIG_PACKAGE_luci-i18n-base-zh-cn=y

# === 集客AC / tcpdump ===
CONFIG_PACKAGE_luci-app-gecoosac=y
CONFIG_PACKAGE_luci-app-tcpdump=y
CONFIG_PACKAGE_tcpdump=y

# === OpenAppFilter（OAF）===
CONFIG_PACKAGE_luci-app-oaf=y
CONFIG_PACKAGE_appfilter=y
CONFIG_PACKAGE_kmod-oaf=y
CONFIG_PACKAGE_luci-i18n-oaf-zh-cn=y

# === turboacc（fw4 / 25.12 专用，中文）===
CONFIG_PACKAGE_luci-app-turboacc=y
CONFIG_PACKAGE_turboacc=y
CONFIG_PACKAGE_luci-i18n-turboacc-zh-cn=y

# === ZeroTier（25.x 新 UCI，中文）===
CONFIG_PACKAGE_luci-app-zerotier=y
CONFIG_PACKAGE_zerotier=y
CONFIG_PACKAGE_luci-i18n-zerotier-zh-cn=y
PKGEOF

make defconfig

# =========================================================
# 【二次强制锁】defconfig 后再锁一遍，防止依赖清理把它关掉
# =========================================================
for p in \
  luci-app-store luci-compat xz-utils curl luci-i18n-base-zh-cn \
  luci-app-gecoosac luci-app-tcpdump tcpdump \
  luci-app-oaf appfilter kmod-oaf luci-i18n-oaf-zh-cn \
  luci-app-turboacc turboacc luci-i18n-turboacc-zh-cn \
  luci-app-zerotier zerotier luci-i18n-zerotier-zh-cn; do
    sed -i "s|^# CONFIG_PACKAGE_${p} is not set|CONFIG_PACKAGE_${p}=y|" .config
    sed -i "s|^CONFIG_PACKAGE_${p}=n|CONFIG_PACKAGE_${p}=y|" .config
done

# =========================================================
# ttyd 自动登录 root
# =========================================================
sed -i 's|/bin/login|/bin/login -f root|g' feeds/packages/utils/ttyd/files/ttyd.config

# =========================================================
# Banner & Release 信息
# =========================================================
rm -rf package/base-files/files/etc/banner

sed -i "s/%D %V %C/%D %V $(TZ=UTC-8 date +%Y.%m.%d)/" package/base-files/files/etc/openwrt_release
sed -i "s/%R/by $OP_author/" package/base-files/files/etc/openwrt_release

DATE_TAG="$(TZ=UTC-8 date +%Y-%m-%d)"

cat >> package/base-files/files/etc/banner << 'EOF'

  _______                     ________        __
 |       |.-----.-----.-----.|  |  |  |.----.|  |_
 |   -   ||  _  |  -__|     ||  |  |  ||   _||   _|
 |_______||   __|_____|__|__||________||__|  |____|
          |__|
 -----------------------------------------------------
         %D DATE_PLACEHOLDER by AUTHOR_PLACEHOLDER
 -----------------------------------------------------
EOF

sed -i "s/DATE_PLACEHOLDER/$DATE_TAG/" package/base-files/files/etc/banner
sed -i "s/AUTHOR_PLACEHOLDER/$OP_author/" package/base-files/files/etc/banner

# =========================================================
# 【编译前自检】确认所有插件已强制勾选
# =========================================================
echo "===== 插件编译状态自检 ====="
for p in \
  luci-app-store luci-app-oaf luci-app-turboacc luci-app-zerotier \
  kmod-oaf turboacc zerotier; do
    val=$(grep "^CONFIG_PACKAGE_${p}=y" .config | head -1)
    if [ -n "$val" ]; then
        echo "  ✅ $p = y"
    else
        echo "  ❌ $p NOT SET"
    fi
done
echo "============================="
