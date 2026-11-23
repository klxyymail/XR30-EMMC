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
# 基础变量（防止 $OP_author 为空导致 banner 异常）
# =========================================================
OP_author="kubulama"

# =========================================================
# 内核 vermagic
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

# mihomo-alpha/meta 存在 Kconfig 循环依赖（互相 depends on），
# 会让内核 syncconfig 失败、target/linux failed to build。我们不用 mihomo，
# 直接删掉（daede/daed 不受影响）。
rm -rf package/porxy/mihomo-alpha package/porxy/mihomo-meta
echo "OK: 已删除 mihomo（规避 Kconfig 递归依赖）"

# 清理不需要的官方应用
rm -rf feeds/luci/applications/{luci-app-dockerman,luci-app-samba4,luci-app-aria2,luci-app-diskman}
rm -rf feeds/packages/net/{samba4,v2ray-geodata,mosdns,sing-box,aria2,ariang,adguardhome}

# drop attendedsysupgrade（覆盖所有 luci collection 文件）
sed -i '/luci-app-attendedsysupgrade/d' \
    feeds/luci/collections/luci-nginx/Makefile \
    feeds/luci/collections/luci-ssl-openssl/Makefile \
    feeds/luci/collections/luci-ssl/Makefile \
    feeds/luci/collections/luci/Makefile

# 原版：把默认 uhttpd 替换为 luci-nginx（保留原版逻辑）
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
    if [ "$patch" = "001-rust-disable-ci-mode.patch" ]; then
        echo "Skipping $patch: 上游 rust Makefile 已变更，改用 sed 注入 --ci false"
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

# =========================================================
# 【关键修复】EN8811H DEBUGFS 子选项未声明导致 syncconfig 失败
# 内核 6.12.116 新增 CONFIG_AIR_EN8811H_PHY_DEBUGFS（依赖
# AIR_EN8811H_PHY=m），但 OpenWrt 的 KernelPackage/phy-airoha-en8811h
# 只声明了 KCONFIG:=CONFIG_AIR_EN8811H_PHY，漏掉该子选项，
# 导致它不进 .config.set、syncconfig 认成 (NEW) 报错，
# target/linux failed to build。
# 这里把子选项补进 KCONFIG 声明，OpenWrt 就会把它写入 .config.set。
# =========================================================
NETDEV_MK="package/kernel/linux/modules/netdevices.mk"
if [ -f "$NETDEV_MK" ] && grep -q "CONFIG_AIR_EN8811H_PHY$" "$NETDEV_MK"; then
    sed -i 's|KCONFIG:=CONFIG_AIR_EN8811H_PHY$|KCONFIG:=CONFIG_AIR_EN8811H_PHY CONFIG_AIR_EN8811H_PHY_DEBUGFS|' "$NETDEV_MK"
    echo "OK: 已把 AIR_EN8811H_PHY_DEBUGFS 加入 KCONFIG 声明"
fi

# 禁用 rust 的 CI 模式（把警告当错误会导致编译失败）。
# 原 001-rust-disable-ci-mode.patch 因上游新增 RUSTC_TARGET_RUSTFLAGS 行、行号
# 从 72 变 88 而失效，改用 sed 在 --build-dir 行后插入 --ci false，不依赖行号。
RUST_MK="feeds/packages/lang/rust/Makefile"
if grep -q -- '--build-dir' "$RUST_MK" && ! grep -q -- '--ci false' "$RUST_MK"; then
    sed -i '/--build-dir/a\		--ci false \\' "$RUST_MK"
    echo "OK: rust --ci false 已注入"
fi

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

# curl - fix passwall `time_pretransfer` check
rm -rf feeds/packages/net/curl
git clone --depth=1 https://github.com/sbwml/feeds_packages_net_curl feeds/packages/net/curl

# =========================================================
# nginx（原版保留，最新版）
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
# 【新增】第三方 LuCI 应用（iStore + 集客AC + tcpdump + Harbor File）
# =========================================================
# iStore 软件中心
# 锁定到已验证可编译的 commit（Makefile 版本 0.2.1-r1，与成功固件 #18 一致），
# 避免裸拉 master 漂移导致某天上游改动让固件编译失败。
rm -rf package/luci-app-store
git clone https://github.com/linkease/istore.git package/luci-app-store
git -C package/luci-app-store checkout a97ace34f2da358a015b094d326bba2697697f2e

# 集客 AC 控制器
rm -rf package/luci-app-gecoosac
git clone --depth=1 https://github.com/laipeng668/luci-app-gecoosac package/luci-app-gecoosac

# tcpdump 抓包插件
rm -rf package/luci-app-tcpdump
git clone --depth=1 https://github.com/KFERMercer/luci-app-tcpdump.git package/luci-app-tcpdump

# Harbor File 文件管理器
rm -rf package/luci-app-harbor-file
git clone --depth=1 https://github.com/destan19/luci-app-harbor-file.git package/luci-app-harbor-file

# =========================================================
# feeds 更新 & 安装（必须在插件 clone 之后）
# =========================================================
./scripts/feeds update -a
./scripts/feeds install -a

# =========================================================
# 【关键修复】删除 weechat（上游 Makefile 有递归依赖 bug）
# 新版官方 feeds 引入了 weechat，其 Kconfig 存在
# luci-app-weechat -> weechat-full -> weechat-minimal -> luci-app-weechat
# 的循环依赖，会让 make defconfig / 内核 syncconfig 直接失败
# （target/linux failed to build）。我们不用 weechat，直接从源码树删除。
# 必须在 feeds install -a 之后删，否则会被重新装回。
# =========================================================
rm -rf feeds/packages/net/weechat feeds/luci/applications/luci-app-weechat
echo "OK: 已删除 weechat（规避 Kconfig 递归依赖）"

# =========================================================
# 【关键修复】强制关闭 nginx（去 nginx，防冲突）
# 原版默认启用了 luci-nginx，必须在这里关掉
# =========================================================
sed -i '/CONFIG_PACKAGE_nginx=y/s/y/=n/g' .config
sed -i '/CONFIG_PACKAGE_luci-nginx=y/s/y/=n/g' .config
sed -i '/CONFIG_PACKAGE_nginx-ssl=y/s/y/=n/g' .config

# =========================================================
# 【关键修复】iStore + 依赖写入 .config
# =========================================================
cat >> .config << EOF
CONFIG_PACKAGE_luci-app-store=y
CONFIG_PACKAGE_luci-compat=y
CONFIG_PACKAGE_xz-utils=y
CONFIG_PACKAGE_curl=y
CONFIG_PACKAGE_luci-app-gecoosac=y
CONFIG_PACKAGE_luci-app-tcpdump=y
CONFIG_PACKAGE_tcpdump=y
CONFIG_PACKAGE_luci-app-harbor-file=y
CONFIG_PACKAGE_luci-i18n-harbor-file-zh-cn=y
EOF

make defconfig

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

# =========================================================
# 【关键修复】Banner 使用 'EOF' 防止单引号引发语法错误
# 这是原版编译失败的根本原因
# =========================================================
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

# 替换占位符（此时 shell 变量正常展开）
sed -i "s/DATE_PLACEHOLDER/$DATE_TAG/" package/base-files/files/etc/banner
sed -i "s/AUTHOR_PLACEHOLDER/$OP_author/" package/base-files/files/etc/banner


# ============================================================
# 固件更新插件（luci-app-autoupdate）
# 源码放在本仓库 package/ 下，复制到 OpenWrt 源码树参与编译。
# 依赖 jsonfilter / uclient-fetch / luci-compat 均为基础或已配置项。
# ============================================================
if [ -d "$GITHUB_WORKSPACE/package/luci-app-autoupdate" ]; then
    rm -rf package/luci-app-autoupdate
    cp -r "$GITHUB_WORKSPACE/package/luci-app-autoupdate" package/
    chmod +x package/luci-app-autoupdate/root/usr/bin/AutoUpdate \
             package/luci-app-autoupdate/root/etc/init.d/autoupdate \
             package/luci-app-autoupdate/root/etc/uci-defaults/40_luci-app-autoupdate
    echo "OK: luci-app-autoupdate installed into source tree"
else
    echo "WARN: package/luci-app-autoupdate not found" >&2
fi
