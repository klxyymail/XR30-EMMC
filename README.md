# RAX3000M OpenWrt  闭源驱动固件

## 📋 支持的设备
- ✅ **RAX3000M EMMC 版** （.bin已测试）
- ✅ **RAX3000M NAND **
- ✅ **RAX3000M 256M NAND**
- ✅ **XR30 EMMC 版**  （.bin已测试）


## ⚡ 核心特性
- **插件内置**：常用插件（PassWall / 固件更新 / DDNS / WireGuard / ZeroTier 等）已编译进固件，无需依赖外部软件源
- **远程回家**：内置 WireGuard 服务端 + DDNS + ZeroTier，开机自动配置，LuCI「系统 → 固件更新」可检查新固件
- **无外部源依赖**：插件全部编译进固件，不依赖第三方软件源（已移除自建源及其签名私钥）
- **集成nginx**
- **中继增强**
- **最新25.12**：6.12内核
- **闭源驱动支持**：**wed hnat MTK 硬件加速**
- **DAED 1.28**



## 🔧 U-boot
- [bl-mt798x-dhcpd](https://github.com/Yuzhii0718/bl-mt798x-dhcpd)

## chasey-dev
- [核心源码](https://github.com/chasey-dev/immortalwrt-mt798x-rebase)

## sbwml
- [部分补丁来自](https://github.com/sbwml/r4s_build_script)
