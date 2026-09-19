#!/usr/bin/env bash
#
# BeeconMini SEED AC5 - ImmortalWRT 25.12.0-rc2 一键编译脚本
#
# 用法:
#   ./build_immortalwrt.sh                    # 交互式:逐步确认
#   ./build_immortalwrt.sh --auto             # 全自动:使用默认配置,不打断
#   ./build_immortalwrt.sh --dl-dir /mnt/dl   # 指定已备份的 dl 缓存目录
#   ./build_immortalwrt.sh --config /tmp/.config
#   ./build_immortalwrt.sh --build-only       # 源码已就绪,只跑编译
#
set -uo pipefail

BRANCH="ac3"
REPO="https://github.com/zqin758/immortalwrt-seed-ac5.git"
SRC_DIR="$HOME/immortalwrt"
DL_DIR=""
CONFIG_FILE=""
AUTO=0
BUILD_ONLY=0
JOBS="$(nproc)"

RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GRN}[$(date +%H:%M:%S)]${NC} $*"; }
warn() { echo -e "${YEL}[$(date +%H:%M:%S)] 警告${NC} $*"; }
die()  { echo -e "${RED}[$(date +%H:%M:%S)] 失败${NC} $*"; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --auto)        AUTO=1; shift ;;
    --build-only)  BUILD_ONLY=1; shift ;;
    --dl-dir)      DL_DIR="$2"; shift 2 ;;
    --config)      CONFIG_FILE="$2"; shift 2 ;;
    --branch)      BRANCH="$2"; shift 2 ;;
    --jobs)        JOBS="$2"; shift 2 ;;
    -h|--help)     sed -n '3,12p' "$0"; exit 0 ;;
    *)             die "未知参数: $1" ;;
  esac
done

confirm() {
  [[ $AUTO -eq 1 ]] && return 0
  read -r -p "$1 [Y/n] " ans
  [[ -z "$ans" || "$ans" =~ ^[Yy] ]]
}

# ---------------------------------------------------------------- 环境检查
log "=== 环境检查 ==="
[[ $EUID -eq 0 ]] && die "请不要用 root 用户编译,改用普通用户(编译过程中的 sudo 会单独提示)"

AVAIL_KB=$(df -Pk "$HOME" | awk 'NR==2{print $4}')
AVAIL_GB=$((AVAIL_KB / 1024 / 1024))
log "当前用户: $(whoami) | CPU: $(nproc) 核 | 可用磁盘: ${AVAIL_GB}G"
if [[ $AVAIL_GB -lt 100 ]]; then
  warn "可用磁盘仅 ${AVAIL_GB}G。完整编译实测需要约 70G,建议至少准备 150G,"
  warn "否则极可能在编译中途撑爆磁盘。"
  confirm "仍要继续吗?" || exit 1
fi

cat /etc/os-release | grep -q 'Ubuntu' || warn "当前不是 Ubuntu,依赖安装命令可能需要调整"

# ---------------------------------------------------------------- 安装依赖
if [[ $BUILD_ONLY -eq 0 ]]; then
  log "=== 安装编译依赖 (需要 sudo) ==="
  sudo apt update -qq || die "apt update 失败,请检查网络/软件源"

  # 24.04 已移除 python3-distutils 与 sphinxsearch,单独处理
  PKGS="ack antlr3 asciidoc autoconf automake autopoint binutils bison build-essential \
bzip2 ccache clang cmake cpio curl device-tree-compiler diffutils ecj fastjar flex gawk \
gcc-multilib g++-multilib gettext genisoimage git gperf g++ gcc grep help2man haveged \
intltool libc6-dev-i386 libc6-dev libelf-dev libfuse-dev lib32gcc-s1 libgmp3-dev libmpc-dev \
libmpfr-dev libncurses5-dev libncurses-dev libncursesw5-dev libpython3-dev libreadline-dev \
libssl-dev libtool libxml-parser-perl libdevmapper-dev libglib2.0-dev libgnutls28-dev \
libyaml-dev libltdl-dev lld llvm lrzsz make manpages-posix-dev msmtp nano ninja-build \
ocaml-nox ocaml-findlib patch pkgconf python3 python3-docutils python3-ply python3-pyelftools \
python3-pip python3-setuptools qemu-utils quilt re2c rsync scons sharutils sphinx-common \
subversion swig tar tcl texinfo uglifyjs unzip upx-ucl vim wget xmlto xxd zlib1g-dev zstd"

  for extra in python3-distutils sphinxsearch; do
    apt-cache show "$extra" >/dev/null 2>&1 && PKGS="$PKGS $extra"
  done

  sudo apt install -y $PKGS || die "依赖安装失败"
  log "依赖安装完成"
fi

# ---------------------------------------------------------------- 拉取源码
if [[ $BUILD_ONLY -eq 0 ]]; then
  if [[ -d "$SRC_DIR/.git" ]]; then
    log "=== 源码已存在,跳过 clone ==="
  else
    log "=== 拉取源码 (分支 $BRANCH) ==="
    git clone -b "$BRANCH" --single-branch "$REPO" "$SRC_DIR" || die "clone 失败,请检查网络"
  fi
fi
cd "$SRC_DIR" || die "无法进入 $SRC_DIR"
log "当前 HEAD: $(git log -1 --format='%h %ad %s' --date=short)"

# ---------------------------------------------------------------- 恢复 dl
if [[ -n "$DL_DIR" && -d "$DL_DIR" ]]; then
  if [[ -d dl ]] && [[ -n "$(ls -A dl 2>/dev/null)" ]]; then
    log "=== dl 目录非空,跳过恢复 ==="
  else
    log "=== 从 $DL_DIR 恢复 dl 缓存 ==="
    mkdir -p dl && cp -r "$DL_DIR"/. dl/ && log "dl 缓存恢复完成: $(du -sh dl | cut -f1)"
  fi
fi

# ---------------------------------------------------------------- feeds
if [[ $BUILD_ONLY -eq 0 ]]; then
  log "=== 更新 feeds ==="
  ./scripts/feeds update -a || die "feeds update 失败"
  log "=== 安装 feeds ==="
  ./scripts/feeds install -a || die "feeds install 失败"
fi

# ---------------------------------------------------------------- 配置
if [[ -n "$CONFIG_FILE" && -f "$CONFIG_FILE" ]]; then
  log "=== 应用已有配置: $CONFIG_FILE ==="
  cp "$CONFIG_FILE" .config
else
  [[ -f .config ]] || cp .config.old .config 2>/dev/null || true
fi

if [[ -f .config ]]; then
  log "=== 执行 make defconfig (补齐依赖) ==="
  make defconfig || die "defconfig 失败,.config 与当前源码可能不兼容"
  grep -E '^CONFIG_TARGET_(BOARD|SUBTARGET|PROFILE)=' .config
  if grep -q '^CONFIG_USE_APK=y' .config; then log "包管理器: APK"; fi
  for p in luci-app-dockerman mwan3 dockerd; do
    grep -q "^CONFIG_PACKAGE_$p=y" .config && log "  已勾选: $p" || warn "  未勾选: $p (配网中心需要)"
  done
else
  warn "没有找到 .config,将进入 menuconfig 手动配置"
  warn "请选择: MediaTek Ralink ARM -> Filogic 8x0 (MT798x) -> BeeconMini SEED AC系列产品"
  confirm "现在进入 menuconfig 吗?" && make menuconfig
fi

# ---------------------------------------------------------------- 编译
log "=== 开始编译 (make -j$JOBS) ==="
log "提示: 首次编译耗时较长,建议用 tmux/screen 防止 SSH 断开导致中断"
if confirm "现在开始编译?"; then
  log "--- 阶段 1/2: 下载源码包 ---"
  make -j"$JOBS" download || warn "部分源码包下载失败,将尝试继续(失败会在编译时暴露)"

  log "--- 阶段 2/2: 正式编译 ---"
  START=$(date +%s)
  if make -j"$JOBS" V=s 2>&1 | tee build_$(date +%m%d_%H%M).log; then
    COST=$(( ($(date +%s) - START) / 60 ))
    log "编译成功,耗时 ${COST} 分钟"
  else
    warn "编译失败。可用 make -j1 V=s 单线程重跑以精确定位错误"
    exit 1
  fi

  echo
  log "=== 产物 ==="
  find bin/targets -name '*.bin' -newermt "-3 hours" -printf '%p  (%s bytes)\n' 2>/dev/null | sort
  log "刷机文件: bin/targets/mediatek/filogic/*beeconmini_seed-ac5-squashfs-sysupgrade.bin"
else
  log "已跳过编译。可稍后手动执行: cd $SRC_DIR && make -j$JOBS V=s"
fi
