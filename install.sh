#!/usr/bin/env bash
set -e

APP_NAME="abcard"
REPO_URL=" https://github.com/nurohia/ABCard.git"   # <<< 这里改成你的仓库地址
APP_DIR="$HOME/ABCard"
PORT="8503"
DISPLAY_NUM=":99"
SCREEN_RES="1920x1080x24"

info() {
  echo
  echo "[INFO] $1"
}

warn() {
  echo
  echo "[WARN] $1"
}

err() {
  echo
  echo "[ERROR] $1"
}

need_sudo() {
  if ! command -v sudo >/dev/null 2>&1; then
    err "系统没有 sudo，先安装 sudo 或改用 root 执行。"
    exit 1
  fi
}

write_xvfb_service() {
  sudo tee /etc/systemd/system/xvfb.service > /dev/null <<EOF
[Unit]
Description=Virtual Framebuffer X Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/Xvfb ${DISPLAY_NUM} -screen 0 ${SCREEN_RES} -ac
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
}

write_abcard_service() {
  sudo tee /etc/systemd/system/${APP_NAME}.service > /dev/null <<EOF
[Unit]
Description=ABCard Streamlit App
After=network.target xvfb.service
Requires=xvfb.service

[Service]
Type=simple
User=$(whoami)
WorkingDirectory=${APP_DIR}
Environment=DISPLAY=${DISPLAY_NUM}
Environment=PATH=${APP_DIR}/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=${APP_DIR}/.venv/bin/streamlit run ui.py --server.address 0.0.0.0 --server.port ${PORT}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

install_app() {
  need_sudo

  info "安装系统依赖"
  sudo apt-get update
  sudo apt-get install -y git python3-venv xvfb

  if [ ! -d "${APP_DIR}" ]; then
    info "克隆仓库到 ${APP_DIR}"
    git clone "${REPO_URL}" "${APP_DIR}"
  else
    warn "${APP_DIR} 已存在，跳过 git clone"
  fi

  cd "${APP_DIR}"

  if [ ! -f "ui.py" ]; then
    err "没有找到 ui.py，请确认仓库内容正确。"
    exit 1
  fi

  if [ ! -f "config.json" ] && [ -f "config.example.json" ]; then
    info "复制配置模板"
    cp config.example.json config.json
    warn "已生成 config.json，记得按你的需求修改。"
  fi

  if [ ! -d ".venv" ]; then
    info "创建虚拟环境"
    python3 -m venv .venv
  fi

  info "升级 pip"
  "${APP_DIR}/.venv/bin/pip" install --upgrade pip

  if [ -f "requirements.txt" ]; then
    info "安装 requirements.txt"
    "${APP_DIR}/.venv/bin/pip" install -r requirements.txt
  else
    warn "没有 requirements.txt，跳过。"
  fi

  info "安装 streamlit 和 playwright"
  "${APP_DIR}/.venv/bin/pip" install streamlit playwright

  info "安装 Playwright Chromium"
  "${APP_DIR}/.venv/bin/playwright" install chromium

  info "写入 systemd 服务"
  write_xvfb_service
  write_abcard_service

  info "重载 systemd"
  sudo systemctl daemon-reload

  info "设置开机自启"
  sudo systemctl enable xvfb
  sudo systemctl enable "${APP_NAME}"

  info "启动服务"
  sudo systemctl restart xvfb
  sudo systemctl restart "${APP_NAME}"

  info "安装完成"
  echo "查看状态: sudo systemctl status ${APP_NAME}"
  echo "查看日志: journalctl -u ${APP_NAME} -f"
  echo "修改配置: nano ${APP_DIR}/config.json"
}

update_app() {
  need_sudo

  if [ ! -d "${APP_DIR}" ]; then
    err "目录不存在：${APP_DIR}，先执行安装。"
    exit 1
  fi

  cd "${APP_DIR}"

  if [ ! -d ".git" ]; then
    err "${APP_DIR} 不是 git 仓库，没法自动更新。"
    exit 1
  fi

  info "拉取最新代码"
  git pull

  if [ -d ".venv" ]; then
    info "升级 pip"
    "${APP_DIR}/.venv/bin/pip" install --upgrade pip
  else
    info "创建虚拟环境"
    python3 -m venv .venv
  fi

  if [ -f "requirements.txt" ]; then
    info "安装 requirements.txt"
    "${APP_DIR}/.venv/bin/pip" install -r requirements.txt
  fi

  info "确保 streamlit / playwright 已安装"
  "${APP_DIR}/.venv/bin/pip" install streamlit playwright

  info "更新 Chromium"
  "${APP_DIR}/.venv/bin/playwright" install chromium

  info "重写服务文件"
  write_xvfb_service
  write_abcard_service

  info "重载并重启服务"
  sudo systemctl daemon-reload
  sudo systemctl restart xvfb
  sudo systemctl restart "${APP_NAME}"

  info "更新完成"
  echo "查看状态: sudo systemctl status ${APP_NAME}"
  echo "查看日志: journalctl -u ${APP_NAME} -f"
}

uninstall_app() {
  need_sudo

  warn "即将卸载 ${APP_NAME}"
  read -r -p "确认卸载吗？这会删除 ${APP_DIR} 和服务文件 [y/N]: " confirm

  case "$confirm" in
    y|Y|yes|YES)
      info "停止并禁用服务"
      sudo systemctl stop "${APP_NAME}" 2>/dev/null || true
      sudo systemctl stop xvfb 2>/dev/null || true
      sudo systemctl disable "${APP_NAME}" 2>/dev/null || true
      sudo systemctl disable xvfb 2>/dev/null || true

      info "删除 systemd 服务文件"
      sudo rm -f /etc/systemd/system/${APP_NAME}.service
      sudo rm -f /etc/systemd/system/xvfb.service
      sudo systemctl daemon-reload

      if [ -d "${APP_DIR}" ]; then
        info "删除项目目录 ${APP_DIR}"
        rm -rf "${APP_DIR}"
      fi

      info "卸载完成"
      ;;
    *)
      warn "已取消卸载"
      ;;
  esac
}

show_status() {
  need_sudo
  echo
  sudo systemctl --no-pager --full status "${APP_NAME}" || true
  echo
  sudo systemctl --no-pager --full status xvfb || true
}

menu() {
  while true; do
    echo
    echo "=============================="
    echo " ABCard 管理菜单"
    echo "=============================="
    echo "1) 安装"
    echo "2) 更新"
    echo "3) 卸载"
    echo "4) 查看状态"
    echo "0) 退出"
    echo "=============================="
    read -r -p "请输入选项: " choice

    case "$choice" in
      1) install_app ;;
      2) update_app ;;
      3) uninstall_app ;;
      4) show_status ;;
      0) exit 0 ;;
      *) warn "无效选项，重新输入。" ;;
    esac
  done
}

menu
