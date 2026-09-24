#!/usr/bin/env bash
# ============================================================================
# SEED AC5 固件构建缓存预热脚本（在 GitHub Codespace 中运行）
#
# 作用: 在 Codespace 里完成一次 OpenWrt/ImmortalWrt 编译(4核32GB 也能跑, 见下方说明),
#       然后把 ccache / dl / staging_dir 打包装成 Release 资产传回仓库;
#       Actions 工作流会自动下载该资产作为"热缓存", 把冷构建变热构建。
#
# 用法:
#   bash scripts/codespace-prepare-cache.sh
#
# 常用环境变量:
#   WORK=/tmp/build        源码/编译工作目录(默认 /workspaces/build)。
#                          ★ Codespace 里 /workspaces 通常只有 32GB, 而 /tmp 往往挂在大盘上
#                            (本机实测 118GB), 全量编译峰值 60GB+, 建议 WORK=/tmp/build
#   TARBALL=...            打包产物路径(默认与 WORK 同分区)
#   GOAL=toolchain|full    toolchain=只编工具链(约40~60min, 适合 32GB 小盘先跑一轮); full=全量(默认)
#   TRIGGER_BUILD=1        打包上传完成后自动触发 Actions 热构建
#   SKIP_BUILD=1           不编译, 只打包现有缓存
#   JOBS=4                 并行度(默认 nproc)
#   DISK_FLOOR_GB=3        磁盘看门狗阈值: 可用空间低于该值自动停下编译, 保证还能打包上传
#   KEEP_BUILD_DIR=1       打包时**一并把 build_dir 打进 tar**(体积巨大, 一般不用)
#   KEEP_BUILD_DIR_ON_DISK=1  只保留 build_dir 在磁盘上、但不打包(Codespace 专用;
#                             失败后可直接续跑, 不必从零重编)
#   CACHE_RELEASE=prebuilt-cache   缓存所在 Release tag
#
# 32GB 磁盘建议(两轮累积):
#   第一轮: GOAL=toolchain bash scripts/codespace-prepare-cache.sh
#   第二轮: GOAL=full TRIGGER_BUILD=1 bash scripts/codespace-prepare-cache.sh
# ============================================================================
set -uo pipefail

REPO_SLUG="${REPO_SLUG:-hu2846/immortalwrt-seed-ac5}"
SRC_REPO="${SRC_REPO:-https://github.com/BeeconMini/immortalwrt.git}"
SRC_BRANCH="${SRC_BRANCH:-25.12.0-rc2}"
CACHE_RELEASE="${CACHE_RELEASE:-prebuilt-cache}"
WORK="${WORK:-/workspaces/build}"
JOBS="${JOBS:-$(nproc)}"
GOAL="${GOAL:-full}"
SKIP_BUILD="${SKIP_BUILD:-0}"
DISK_FLOOR_GB="${DISK_FLOOR_GB:-3}"
KEEP_BUILD_DIR="${KEEP_BUILD_DIR:-0}"
TARBALL="${TARBALL:-$(dirname "$WORK")/prebuilt-cache.tar.zst}"
PART_SIZE="${PART_SIZE:-1900M}"

log() { echo -e "\n\033[1;36m==> $*\033[0m"; }
# 可用磁盘(GB): 跟随 WORK 所在分区(不存在时向上找已存在的父目录)
avail_gb() {
  local p="${1:-$WORK}"
  while [ ! -d "$p" ] && [ "$p" != "/" ]; do p="$(dirname "$p")"; done
  df -BG --output=avail "$p" 2>/dev/null | tail -1 | tr -dc '0-9'
}

# ★★ 必须在任何 cd 之前解析“配置仓库”根目录 ★★
# 用相对路径调用脚本时 BASH_SOURCE 是相对路径, 之后一旦 cd 走开, 解析结果就会变成
# 编译目录自身 —— 2026-09-11 实际踩坑: cp 报 "are the same file", 你的 .config 根本没
# 拷进源码树, defconfig 回落到 target 默认设备(openwrt_one), 出现"编译成功但产物不是
# 目标机"的假成功。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
if [ ! -f "$CONFIG_REPO_DIR/.config" ]; then
  echo "❌ 无法定位配置仓库: $CONFIG_REPO_DIR 下没有 .config"
  echo "   请用绝对路径调用: bash $(pwd)/scripts/codespace-prepare-cache.sh"
  exit 1
fi
echo "配置仓库: $CONFIG_REPO_DIR"

log "环境检查"
echo "nproc=$(nproc) arch=$(uname -m) 目标=$GOAL"; free -h | head -2
echo "工作目录: $WORK (所在分区可用 $(avail_gb)GB)"
df -h /workspaces /tmp 2>/dev/null | grep -vE '^Filesystem' | head -4
echo "看门狗阈值 ${DISK_FLOOR_GB}GB"

log "安装编译依赖"
sudo apt-get update -qq
sudo apt-get install -y -qq build-essential ccache clang cmake curl ecj fastjar file g++ gawk gettext git \
  libelf-dev libncurses-dev libssl-dev python3 python3-docutils python3-setuptools rsync swig time \
  unzip wget zlib1g-dev qemu-utils zstd procps >/dev/null

log "准备源码目录 $WORK"
mkdir -p "$WORK"; cd "$WORK"
[ -d source/.git ] || git clone -b "$SRC_BRANCH" --single-branch "$SRC_REPO" source
cd source

log "应用本仓库的 feeds / .config / files / 补丁脚本"
# CONFIG_REPO_DIR 已在脚本开头(任何 cd 之前)解析完成, 此处不再重算。
# 关键: Codespace 里的仓库克隆可能停留在旧提交(历史事故: 用它编译只收敛出 235 个包,
# 且 bin/targets 里没有 beeconmini_seed-ac3 设备镜像)。先从 origin/master 刷新这两个配置文件。
if [ -d "$CONFIG_REPO_DIR/.git" ]; then
  if git -C "$CONFIG_REPO_DIR" fetch -q origin master; then
    for f in .config feeds.conf.default; do
      if git -C "$CONFIG_REPO_DIR" show FETCH_HEAD:"$f" > "$CONFIG_REPO_DIR/$f.tmp" 2>/dev/null \
         && [ -s "$CONFIG_REPO_DIR/$f.tmp" ]; then
        mv -f "$CONFIG_REPO_DIR/$f.tmp" "$CONFIG_REPO_DIR/$f"
        echo "已从 origin/master 刷新 $f"
      else
        rm -f "$CONFIG_REPO_DIR/$f.tmp"
        echo "⚠️ $f 刷新失败, 沿用现有副本"
      fi
    done
  else
    echo "⚠️ git fetch 失败, 沿用现有副本(可能较旧)"
  fi
fi
cp -f "$CONFIG_REPO_DIR/feeds.conf.default" feeds.conf.default
cp -f "$CONFIG_REPO_DIR/.config" .config
# 硬校验: .config 必须真的拷进来了(源里要含目标设备)
if ! grep -q "beeconmini_seed-ac3" .config; then
  echo "❌ .config 未正确应用(未找到 beeconmini_seed-ac3)! 来源: $CONFIG_REPO_DIR/.config"
  echo "   若来源与目标相同会报 'are the same file', 说明 SCRIPT_DIR 解析有误。"
  exit 1
fi
echo "✅ 已应用 .config: $(grep -cE '^CONFIG_PACKAGE_[a-z0-9._-]+=y' .config) 个包"
[ -d "$CONFIG_REPO_DIR/files" ] && cp -r "$CONFIG_REPO_DIR/files" ./
mkdir -p .ccache
export CCACHE_DIR="$WORK/source/.ccache" CCACHE_MAXSIZE=8G CCACHE_COMPRESS=true

# 复用已有的 feeds/dl/staging 时, 先更新 feeds 再收敛
./scripts/feeds update -a
./scripts/feeds install -a
python3 "$CONFIG_REPO_DIR/scripts/fix-libffi-makefile.py" feeds/packages/libs/libffi/Makefile || true

# ---- 修正 feeds/luci 的 ucode 版本下限(2026-09-11 实际踩坑) ----
# feeds/luci/luci.mk 新增了 "ucode 字节码格式下限":
#   LUCI_UT_MIN_UCODE?=2026.02.27    # ucode 字节码 format 0x02 自 2026-02-27 起
# 并在 LUCI_EXTRA_DEPENDS 里生成 `ucode (>=$(LUCI_UT_MIN_UCODE))` 依赖。
# 但本源码树(BeeconMini/immortalwrt@25.12.0-rc2)内 ucode 仍是 2026.01.16, apk 依赖解析直接失败:
#   ERROR: unable to select packages:
#     ucode-2026.01.16~85922056-r1:
#       breaks: luci-base-[ucode>=2026.02.27] / luci-mod-status / luci-theme-argon / luci-theme-bootstrap / wpad-openssl
#   make[2]: *** [package/Makefile:100: package/install] Error 71
#   make: *** [include/toplevel.mk:233: world] Error 2   -> 全部包都编完了, 却卡在最后装 rootfs, 不产出固件
# 该下限的原意是"host 端 ucode 预编译模板产出的字节码必须能被目标端运行时读取";
# 本树里 ucode/host 与目标 ucode 同源同版本(package/utils/ucode/Makefile), 格式天然一致,
# 因此把下限对齐到树内版本是安全且等效的。
# 注意: 不要用改 .config / feeds.conf.default 的方式绕(会触发 Actions 构建且破坏已验证的收敛逻辑)。
if [ -f feeds/luci/luci.mk ]; then
  # 只把"版本下限"下调为 0.0.0 —— 树内 ucode(2026.01.16)必然满足该下限。
  # ⚠️ 千万不要试图把 `ucode (>=$(LUCI_UT_MIN_UCODE))` 整段文本 sed 删掉:
  #    该行末尾是连续三个 ')' (字面括号 + 变量括号 + $(strip 的括号),
  #    用 [^)]* 匹配会把字面 '(' 的闭合括号吃掉, 得到 `ucode))` 这种畸形依赖。
  sed -i -E 's/^LUCI_UT_MIN_UCODE\?=.*/LUCI_UT_MIN_UCODE?=0.0.0/' feeds/luci/luci.mk
  echo "✅ 已下调 feeds/luci/luci.mk 的 ucode 版本下限:"
  grep -nE '^LUCI_UT_MIN_UCODE\?=|ucode \(>=' feeds/luci/luci.mk | head -5
else
  echo "⚠️ feeds/luci/luci.mk 不存在, 跳过 ucode 依赖下限修正"
fi
grep -qE '^CONFIG_CCACHE=y' .config || echo 'CONFIG_CCACHE=y' >> .config

# ---- 强制目标设备 ----
# ⚠️ 2026-09-11 实际踩坑: 不带 TARGET/PROFILE 行时 defconfig 会回落到 target 默认设备
#    (mediatek/filogic 的默认是 openwrt_one), 结果是"编译成功但产物不是 seed-ac3"。
DEVICE="${DEVICE:-beeconmini_seed-ac3}"
force_target() {
  # 删掉全部 mediatek/filogic 相关行(含 DEVICE_xxx), 再由 PROFILE 重新生成
  sed -i -E -e '/^CONFIG_TARGET_mediatek/d' \
            -e '/^CONFIG_TARGET_(BOARD|SUBTARGET|PROFILE|ARCH_PACKAGES|OPTIMIZATION|SUFFIX)=/d' .config
  cat >> .config <<EOF
CONFIG_TARGET_mediatek=y
CONFIG_TARGET_mediatek_filogic=y
CONFIG_TARGET_mediatek_filogic_DEVICE_${DEVICE}=y
CONFIG_TARGET_BOARD="mediatek"
CONFIG_TARGET_SUBTARGET="filogic"
CONFIG_TARGET_ARCH_PACKAGES="aarch64_cortex-a53"
CONFIG_TARGET_PROFILE="DEVICE_${DEVICE}"
CONFIG_TARGET_OPTIMIZATION="-Os -pipe -mcpu=cortex-a53"
CONFIG_TARGET_SUFFIX="musl"
EOF
}

log "配置收敛(与 Actions 工作流一致)"
PREV=-1
for i in 1 2 3 4 5 6 7 8; do
  grep -hE '^CONFIG_PACKAGE_[^ =]+=y' "$CONFIG_REPO_DIR/.config" | while IFS= read -r line; do
    sym="${line%%=*}"
    grep -qE "^${sym}=y$|^${sym}=m$" .config || echo "$line" >> .config
  done
  force_target
  make defconfig >/dev/null 2>&1
  N=$(grep -cE '^CONFIG_PACKAGE_[a-z0-9._-]+=y' .config || true)
  DEV_NOW=$(grep -oE "^CONFIG_TARGET_[a-z0-9_]*_DEVICE_[^=]+=y" .config | head -1 | sed 's/.*DEVICE_//;s/=y//')
  echo "第 $i 轮后 PACKAGE=y: $N (设备: ${DEV_NOW:-无})"
  [ "$N" = "$PREV" ] && { echo "配置已收敛"; break; }
  PREV=$N
done
grep -qE '^CONFIG_CCACHE=y' .config || echo 'CONFIG_CCACHE=y' >> .config

# ---- 收敛后强校验: 设备必须正确、包数不能异常 ----
if ! grep -qE "^CONFIG_TARGET_[a-z0-9_]*_DEVICE_${DEVICE}=y" .config; then
  echo "❌ 设备未生效(期望 ${DEVICE})！实际: $(grep -oE '^CONFIG_TARGET_[a-z0-9_]*_DEVICE_[^=]+=y' .config | head -3 | tr '\n' ' ')"
  echo "   此时编译只会得到错误设备的固件, 已中止。"
  exit 1
fi
if [ "${N:-0}" -lt 380 ]; then
  echo "❌ 收敛后包数异常($N < 380), 疑似配置被静默丢弃, 已中止。"
  exit 1
fi
echo "✅ 配置校验通过: 设备=${DEVICE}, PACKAGE=y=${N}"

# ------------------------- 编译(带磁盘看门狗) -------------------------
run_build() {
  local target="$1" desc="$2"
  log "$desc (可用磁盘 $(avail_gb)GB)"
  make -j"$JOBS" V=s $target &
  local pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    sleep 20
    if [ "$(avail_gb)" -lt "$DISK_FLOOR_GB" ]; then
      echo -e "\n\033[1;33m⚠️ 可用磁盘 < ${DISK_FLOOR_GB}GB, 停止编译以保留打包空间\033[0m"
      pkill -TERM -P "$pid" 2>/dev/null || true
      kill -TERM "$pid" 2>/dev/null || true
      pkill -f '^make ' 2>/dev/null || true
      sleep 5
      break
    fi
  done
  wait "$pid" 2>/dev/null
  echo "目标 [$target] 结束, 剩余磁盘 $(avail_gb)GB"
}

if [ "$SKIP_BUILD" != "1" ]; then
  # download 先行(有磁盘阈值保护)
  for i in 1 2 3; do
    make -j$((JOBS+1)) download V=s && break || { echo "download 重试 $i/3"; sleep 20; }
  done

  if [ "$GOAL" = "toolchain" ]; then
    run_build "tools/install" "编译 host 工具(tools/install)"
    run_build "toolchain/install" "编译交叉工具链(toolchain/install)"
  else
    run_build "" "完整编译 make -j$JOBS V=s"
  fi
  ccache -s || true
fi

# ------------------------- 打包上传 -------------------------
log "准备打包(默认删除 build_dir 腾空间)"
cd "$WORK/source"
PACK_LIST=(.ccache dl staging_dir)
if [ "$KEEP_BUILD_DIR" = "1" ] && [ -d build_dir ]; then
  PACK_LIST+=(build_dir)
elif [ "${KEEP_BUILD_DIR_ON_DISK:-0}" = "1" ]; then
  # Codespace 专用: build_dir 不进 tar(否则包体暴涨), 但留在磁盘上。
  # 动机: 2026-09-11 一轮跑完 package/install 才失败, 而 build_dir 已按老逻辑删掉 ->
  # 下一轮等于全量重编。留着就能热续跑。
  echo "保留 build_dir 在磁盘(不打包): $(du -sh build_dir 2>/dev/null | cut -f1)"
else
  # ⚠️ 必须先删再打包: 旧版先把 build_dir/host* 加进 PACK_LIST 又 `rm -rf build_dir`,
  # 导致 tar 报 "Exiting with failure status due to previous errors"(文件不存在)。
  rm -rf build_dir
fi
echo "打包内容: ${PACK_LIST[*]}"; du -sh "${PACK_LIST[@]}" 2>/dev/null || true

rm -f "$TARBALL"
tar -I 'zstd -T0 -3' -cf "$TARBALL" "${PACK_LIST[@]}"
ls -lh "$TARBALL"

log "分片并上传到 Release: $CACHE_RELEASE"
rm -f "${TARBALL}".part-*
split -b "$PART_SIZE" -d -a 3 "$TARBALL" "${TARBALL}.part-"
export GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
# gh cs ssh 不会继承本机环境变量, 因此也尝试从常见文件位置读取 token
if [ -z "${GH_TOKEN:-}" ]; then
  for f in "$HOME/.gh_token" "$HOME/.ghtoken" "$CONFIG_REPO_DIR/.gh_token"; do
    if [ -s "$f" ]; then export GH_TOKEN="$(tr -d '\r\n' < "$f")"; echo "已从 $f 读取 token"; break; fi
  done
fi
if [ -z "${GH_TOKEN:-}" ]; then
  echo "❌ 未找到 GH_TOKEN/GITHUB_TOKEN。"
  echo "   注意: 通过 'gh cs ssh -c <name> -- \"bash scripts/codespace-prepare-cache.sh\"' 调用时不会继承本机 env,"
  echo "   请显式传入: gh cs ssh -c <name> -- \"GH_TOKEN=<tok> bash scripts/codespace-prepare-cache.sh\""
  echo "   或将 token 写入 ~/.gh_token 后重跑(打包好的 $TARBALL 仍在, 可 SKIP_BUILD=1 直接重跑打包上传)。"
  exit 1
fi
if ! gh release view "$CACHE_RELEASE" --repo "$REPO_SLUG" >/dev/null 2>&1; then
  gh release create "$CACHE_RELEASE" --repo "$REPO_SLUG" \
    --title "Prebuilt build cache" --notes "Codespace 预热的 ccache/dl/staging 缓存, 供 Actions 工作流恢复使用。" || true
fi
gh release upload "$CACHE_RELEASE" "${TARBALL}".part-* --repo "$REPO_SLUG" --clobber
echo "✅ 缓存已上传。可删除本地大文件: rm -f $TARBALL ${TARBALL}.part-*"

# ------------------------- 顺带上传固件(若本次编译真出了我们的镜像) -------------------------
IMG_DIR="$WORK/source/bin/targets/mediatek/filogic"
FIRMWARE_RELEASE="${FIRMWARE_RELEASE:-build-${SRC_BRANCH}}"
if ls "$IMG_DIR"/*"${DEVICE}"* >/dev/null 2>&1; then
  log "发现 ${DEVICE} 固件, 按 SEED-AC3-${SRC_BRANCH}-类型 命名并上传: $FIRMWARE_RELEASE"
  STAGE="/tmp/fw-stage"; rm -rf "$STAGE"; mkdir -p "$STAGE"
  for f in "$IMG_DIR"/*"${DEVICE}"*; do
    base="$(basename "$f")"; ext="${base##*.}"
    case "$base" in
      *squashfs-sysupgrade*) cp -f "$f" "$STAGE/SEED-AC3-${SRC_BRANCH}-squashfs-sysupgrade.${ext}";;
      *initramfs*)           cp -f "$f" "$STAGE/SEED-AC3-${SRC_BRANCH}-initramfs.${ext}";;
      *)                     cp -f "$f" "$STAGE/$base";;
    esac
  done
  cp -f "$IMG_DIR"/mt79*-bl2.bin "$STAGE/" 2>/dev/null || true
  ls -lh "$STAGE"
  if ! gh release view "$FIRMWARE_RELEASE" --repo "$REPO_SLUG" >/dev/null 2>&1; then
    gh release create "$FIRMWARE_RELEASE" --repo "$REPO_SLUG" \
      --title "SEED AC3 ${SRC_BRANCH} (Codespace build)" --notes "由 Codespace 直接编译产出。" || true
  fi
  gh release upload "$FIRMWARE_RELEASE" "$STAGE"/* --repo "$REPO_SLUG" --clobber
  echo "✅ 固件已上传到 Release: $FIRMWARE_RELEASE"
else
  echo "⚠️ 未找到 ${DEVICE} 的固件镜像(构建可能未完成), 跳过固件上传"
fi

if [ "${TRIGGER_BUILD:-0}" = "1" ]; then
  log "触发 Actions 热构建"
  gh workflow run "Build ImmortalWRT for SEED AC3" --repo "$REPO_SLUG" --ref master
  sleep 8
  gh run list --repo "$REPO_SLUG" --workflow "Build ImmortalWRT for SEED AC3" --limit 3
else
  echo "下一步: 在 Actions 手动触发 'Build ImmortalWRT for SEED AC3'(或加 TRIGGER_BUILD=1 自动触发)"
fi
