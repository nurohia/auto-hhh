#!/usr/bin/env bash
set -e

APP_NAME="abcard"
REPO_URL="https://github.com/nurohia/ABCard.git"
APP_DIR="$HOME/ABCard"
PORT="8503"
DISPLAY_NUM=":99"
SCREEN_RES="1920x1080x24"
ENTRY_FILE="ui.py"

log() {
  echo
  echo "[INFO] $1"
}

ok() {
  echo
  echo "[OK] $1"
}

warn() {
  echo
  echo "[WARN] $1"
}

err() {
  echo
  echo "[ERROR] $1"
  exit 1
}

pause_wait() {
  echo
  read -r -p "按回车继续..." _
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

ensure_sudo() {
  if ! need_cmd sudo; then
    err "没有检测到 sudo，请先安装 sudo，或者直接用 root 执行。"
  fi
}

ensure_apt() {
  if ! need_cmd apt-get; then
    err "当前系统没有 apt-get。这个脚本目前只支持 Debian/Ubuntu 系。"
  fi
}

ensure_cmd_or_pkg() {
  local cmd="$1"
  local pkg="$2"

  if need_cmd "$cmd"; then
    ok "$cmd 已存在"
  else
    log "缺少 $cmd，正在安装系统包: $pkg"
    sudo apt-get update
    sudo apt-get install -y "$pkg"
  fi
}

ensure_pkg() {
  local pkg="$1"

  if dpkg -s "$pkg" >/dev/null 2>&1; then
    ok "$pkg 已安装"
  else
    log "安装系统包: $pkg"
    sudo apt-get update
    sudo apt-get install -y "$pkg"
  fi
}

# 核心重构：多系统自适应 Python 3.12 引擎
ensure_python312() {
  if need_cmd python3.12; then
    ok "python3.12 已存在，跳过安装"
    return
  fi

  log "检测到缺少 python3.12，正在执行系统级探针..."
  
  local os_type=""
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    os_type=$ID
  fi

  if [ "$os_type" = "ubuntu" ]; then
    log "探针反馈：Ubuntu 架构。启用 PPA 高速部署模式..."
    sudo apt-get update
    sudo apt-get install -y software-properties-common
    if need_cmd add-apt-repository; then
      sudo add-apt-repository -y ppa:deadsnakes/ppa || true
      sudo apt-get update
    fi
    sudo apt-get install -y python3.12 python3.12-venv python3.12-dev

  elif [ "$os_type" = "debian" ]; then
    log "探针反馈：Debian 架构。启动底层 C 源码静默编译模式 (视 CPU 性能需 3-10 分钟)..."
    sudo apt-get update
    sudo apt-get install -y wget build-essential libssl-dev zlib1g-dev \
      libncurses5-dev libncursesw5-dev libreadline-dev libsqlite3-dev \
      libgdbm-dev libdb5.3-dev libbz2-dev libexpat1-dev liblzma-dev tk-dev libffi-dev

    cd /tmp
    if [ ! -f "Python-3.12.2.tar.xz" ]; then
      wget https://www.python.org/ftp/python/3.12.2/Python-3.12.2.tar.xz
    fi
    tar -xf Python-3.12.2.tar.xz
    cd Python-3.12.2
    
    ./configure --enable-optimizations
    make -j"$(nproc 2>/dev/null || echo 1)"
    sudo make altinstall
    
    cd ~
    rm -rf /tmp/Python-3.12.2 /tmp/Python-3.12.2.tar.xz

    if ! need_cmd python3.12; then
      err "Python 3.12 源码编译失败，请检查编译日志。"
    fi
  else
    err "未知的操作系统类型 ($os_type)，本环境构建器当前仅适配 Ubuntu 与 Debian。"
  fi
  
  ok "Python 3.12 跨平台自适应构建完成！"
}

get_server_ip() {
  local ip=""
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  if [ -z "$ip" ]; then
    ip="服务器IP"
  fi
  echo "$ip"
}

show_access_url() {
  if systemctl is-active --quiet "$APP_NAME" 2>/dev/null; then
    local ip
    ip="$(get_server_ip)"

    echo
    echo "===================================="
    echo " 浏览器访问地址"
    echo "------------------------------------"
    echo " http://${ip}:${PORT}"
    echo "===================================="
    echo
  fi
}

write_xvfb_service() {
  sudo tee /etc/systemd/system/xvfb.service > /dev/null <<EOF2
[Unit]
Description=Virtual Framebuffer X Server
After=network.target

[Service]
Type=simple
ExecStartPre=-/usr/bin/pkill -f "Xvfb ${DISPLAY_NUM}"
ExecStartPre=-/usr/bin/rm -f /tmp/.X99-lock
ExecStartPre=-/usr/bin/rm -f /tmp/.X11-unix/X99
ExecStart=/usr/bin/Xvfb ${DISPLAY_NUM} -screen 0 ${SCREEN_RES} -ac -nolisten tcp
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF2
}

write_abcard_service() {
  local user_name
  user_name="$(whoami)"

  sudo tee /etc/systemd/system/${APP_NAME}.service > /dev/null <<EOF2
[Unit]
Description=ABCard Streamlit App
After=network.target xvfb.service
Requires=xvfb.service

[Service]
Type=simple
User=${user_name}
WorkingDirectory=${APP_DIR}
Environment=DISPLAY=${DISPLAY_NUM}
Environment=BROWSER=none
Environment=STREAMLIT_BROWSER_GATHER_USAGE_STATS=false
Environment=PATH=${APP_DIR}/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=${APP_DIR}/.venv/bin/streamlit run ${ENTRY_FILE} --server.address 0.0.0.0 --server.port ${PORT} --server.headless true
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF2
}

install_dependencies() {
  ensure_sudo
  ensure_apt

  log "检查并安装必要系统依赖"
  ensure_cmd_or_pkg git git
  ensure_cmd_or_pkg curl curl
  ensure_python312
  ensure_pkg xvfb
}

clone_repo_if_needed() {
  if [ -d "$APP_DIR/.git" ]; then
    warn "$APP_DIR 已经是一个 git 仓库，跳过 clone"
    return
  fi

  if [ -d "$APP_DIR" ] && [ "$(ls -A "$APP_DIR" 2>/dev/null)" ]; then
    err "目录 $APP_DIR 已存在且非空，无法直接 clone。请先清空或删除该目录。"
  fi

  mkdir -p "$APP_DIR"
  log "克隆仓库到 $APP_DIR"
  git clone "$REPO_URL" "$APP_DIR"
}

validate_project() {
  cd "$APP_DIR"

  if [ ! -f "$ENTRY_FILE" ]; then
    err "没有找到入口文件: $ENTRY_FILE，请检查仓库内容，或修改脚本里的 ENTRY_FILE。"
  fi
}

prepare_config() {
  cd "$APP_DIR"

  if [ ! -f "config.json" ] && [ -f "config.example.json" ]; then
    log "检测到 config.example.json，复制为 config.json"
    cp config.example.json config.json
    warn "已创建 config.json，请按需修改配置。"
  else
    warn "未复制配置文件。可能已经存在 config.json，或仓库里没有 config.example.json。"
  fi
}

setup_python_env() {
  cd "$APP_DIR"

  if [ ! -d ".venv" ]; then
    log "创建 Python 3.12 虚拟环境"
    python3.12 -m venv .venv
  else
    ok ".venv 已存在，跳过创建"
  fi

  log "升级 pip"
  "$APP_DIR/.venv/bin/pip" install --upgrade pip

  if [ -f "requirements.txt" ]; then
    log "安装 requirements.txt"
    "$APP_DIR/.venv/bin/pip" install -r requirements.txt
  else
    warn "没有找到 requirements.txt，跳过"
  fi

  log "安装 streamlit 和 playwright"
  "$APP_DIR/.venv/bin/pip" install streamlit playwright

  log "安装 Playwright Chromium"
  "$APP_DIR/.venv/bin/playwright" install chromium

  log "安装 Playwright 系统级底层依赖"
  "$APP_DIR/.venv/bin/playwright" install-deps chromium
}

enable_and_start_services() {
  log "写入 systemd 服务"
  write_xvfb_service
  write_abcard_service

  log "重载 systemd"
  sudo systemctl daemon-reload

  log "设置开机自启"
  sudo systemctl enable xvfb
  sudo systemctl enable "$APP_NAME"

  log "启动/重启服务"
  sudo systemctl restart xvfb
  sudo systemctl restart "$APP_NAME"

  ok "服务已启动并设置为开机自启"
}

install_app() {
  install_dependencies
  clone_repo_if_needed
  validate_project
  prepare_config
  setup_python_env
  enable_and_start_services

  ok "安装完成"
  echo
  echo "项目目录: $APP_DIR"
  echo "仓库地址: $REPO_URL"
  echo "查看状态: sudo systemctl status $APP_NAME"
  echo "查看日志: journalctl -u $APP_NAME -f"
  echo "重启服务: sudo systemctl restart $APP_NAME"

  show_access_url
  pause_wait
}

update_app() {
  ensure_sudo
  ensure_apt

  if [ ! -d "$APP_DIR" ]; then
    err "目录不存在: $APP_DIR，请先安装。"
  fi

  cd "$APP_DIR"

  if [ ! -d ".git" ]; then
    err "$APP_DIR 不是 git 仓库，无法自动更新。"
  fi

  install_dependencies

  log "拉取最新代码"
  git pull

  validate_project
  prepare_config
  setup_python_env
  enable_and_start_services

  ok "更新完成"
  echo
  echo "查看状态: sudo systemctl status $APP_NAME"
  echo "查看日志: journalctl -u $APP_NAME -f"

  show_access_url
  pause_wait
}

uninstall_app() {
  ensure_sudo

  echo
  read -r -p "确认卸载吗？这会删除项目目录和 systemd 服务 [y/N]: " confirm

  case "$confirm" in
    y|Y|yes|YES)
      log "停止服务"
      sudo systemctl stop "$APP_NAME" 2>/dev/null || true
      sudo systemctl stop xvfb 2>/dev/null || true

      log "禁用开机自启"
      sudo systemctl disable "$APP_NAME" 2>/dev/null || true
      sudo systemctl disable xvfb 2>/dev/null || true

      log "删除 systemd 服务文件"
      sudo rm -f "/etc/systemd/system/${APP_NAME}.service"
      sudo rm -f "/etc/systemd/system/xvfb.service"
      sudo systemctl daemon-reload

      if [ -d "$APP_DIR" ]; then
        log "删除项目目录: $APP_DIR"
        rm -rf "$APP_DIR"
      fi

      ok "卸载完成"
      ;;
    *)
      warn "已取消卸载"
      ;;
  esac

  pause_wait
}

show_status() {
  ensure_sudo
  echo
  sudo systemctl --no-pager --full status "$APP_NAME" || true
  echo
  sudo systemctl --no-pager --full status xvfb || true
  show_access_url
  pause_wait
}

show_logs() {
  ensure_sudo
  journalctl -u "$APP_NAME" -f
}

restart_app() {
  ensure_sudo
  log "重启 xvfb 和 $APP_NAME"
  sudo systemctl restart xvfb
  sudo systemctl restart "$APP_NAME"
  ok "重启完成"
  show_access_url
  pause_wait
}

menu() {
  while true; do
    clear
    echo "===================================="
    echo "        ABCard 管理脚本"
    echo "===================================="
    echo "固定仓库: $REPO_URL"
    echo "安装目录: $APP_DIR"
    
    if systemctl is-active --quiet "$APP_NAME" 2>/dev/null; then
      echo "访问地址: http://$(get_server_ip):${PORT}"
    else
      echo "访问地址: (服务未运行，安装启动后显示)"
    fi
    
    echo "===================================="
    echo "1) 安装"
    echo "2) 更新"
    echo "3) 卸载"
    echo "4) 查看状态"
    echo "5) 查看日志"
    echo "6) 重启服务"
    echo "0) 退出"
    echo "===================================="
    echo
    read -r -p "请输入选项: " choice

    case "$choice" in
      1) install_app ;;
      2) update_app ;;
      3) uninstall_app ;;
      4) show_status ;;
      5) show_logs ;;
      6) restart_app ;;
      0) exit 0 ;;
      *) warn "无效选项"; pause_wait ;;
    esac
  done
}

menu
