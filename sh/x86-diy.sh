#!/bin/bash
# ============================================================================
#  x86/64 版 DIY 脚本（对应原仓库的 sh/op.sh）
#
#  相对原版做了三处调整：
#    1. 去掉 filogic.mk 注入（JCG Q30 PRO 设备支持）——MT7981 专属，x86 无关
#    2. 去掉 feeds/luci 补丁的强制失败退出——patch 冲突时只告警，不中断编译
#    3. 去掉联发科闭源无线 / hnat / warp 相关处理
#
#  执行时机：源码 clone 完成、feeds update 之后、make defconfig 之前
#  执行方式：cd <openwrt> && /path/to/x86-diy.sh
# ============================================================================

set -e

OP_author="${OP_author:-klxyy}"
OP_IP="${OP_IP:-192.168.6.1}"

# 稀疏克隆：只取仓库里需要的目录，省时间省空间
function git_sparse_clone() {
  branch="$1" repourl="$2" && shift 2
  git clone --depth=1 -b "$branch" --single-branch --filter=blob:none --sparse "$repourl"
  repodir=$(echo "$repourl" | awk -F '/' '{print $(NF)}')
  cd "$repodir" && git sparse-checkout set "$@"
  mv -f "$@" ../
  cd .. && rm -rf "$repodir"
}

echo "[DIY] 拉第三方插件源 ..."
# 与原仓库一致的两个源；若提示无法访问，换成你自己的插件仓库即可
git clone -b packages --depth 1 --single-branch https://github.com/shiyu1314/openwrt-feeds package/xd   || echo "[DIY] package/xd 拉取失败，跳过"
git clone -b porxy   --depth 1 --single-branch https://github.com/shiyu1314/openwrt-feeds package/porxy || echo "[DIY] package/porxy 拉取失败，跳过"

echo "[DIY] 应用 luci 补丁（如有）..."
if [ -d feeds/luci ]; then
  pushd feeds/luci >/dev/null
  for patch in *.patch; do
    [ -f "$patch" ] || continue
    echo "  applying $patch ..."
    # 原版是失败即 exit 1；x86 上部分 MTK 相关补丁并不适用，改为告警继续
    patch -p1 --no-backup-if-mismatch < "$patch" \
      || echo "  [WARN] $patch 应用失败，已跳过"
  done
  popd >/dev/null
fi

echo "[DIY] 追加额外内建包 ..."
cat >> .config <<'EOF'
CONFIG_PACKAGE_luci-app-store=y
CONFIG_PACKAGE_luci-compat=y
CONFIG_PACKAGE_xz-utils=y
CONFIG_PACKAGE_curl=y
CONFIG_PACKAGE_tcpdump=y
EOF

echo "[DIY] 设置默认 LAN IP ..."
# 与 workflow 中的 OP_IP 输入保持一致；脚本单独跑时用默认值
sed -i "s/192\.168\.1\.1/${OP_IP}/g" package/base-files/files/bin/config_generate 2>/dev/null \
  || echo "[WARN] config_generate 未找到，跳过 IP 设置"

echo "[DIY] 写入 banner ..."
cat > package/base-files/files/etc/banner <<EOF
  _______                     ________        __
 |       |.-----.-----.-----.|  |  |  |.----.|  |_
 |   -   ||  _  |  -__|     ||  |  |  ||   _||   _|
 |_______||   __|_____|__|__||________||__|  |____|
          |__|
 OpenWrt x86/64  ——  编译于 $(date +'%Y-%m-%d')
 作者: ${OP_author}
 管理地址: http://${OP_IP}
 ---------------------------------------------------
EOF

echo "[DIY] make defconfig ..."
make defconfig

echo "[DIY] 完成。"
