#!/bin/bash
# ============================================================
# 脚本名称: setup_nginx_download.sh
# 功能: 交互式安装 Nginx 文件下载服务 (生产环境)
# 适用系统: Ubuntu/Debian, CentOS/RHEL, Rocky Linux
# 使用方法: sudo bash setup_nginx_download.sh
# ============================================================

set -e  # 遇到错误立即退出

# ---------- 颜色定义 ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ---------- 辅助函数 ----------
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# ---------- 检查 root 权限 ----------
if [[ $EUID -ne 0 ]]; then
    print_error "该脚本必须以 root 权限运行！请使用 sudo bash $0"
    exit 1
fi

# ---------- 检测操作系统 ----------
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    VERSION=$VERSION_ID
else
    print_error "无法检测操作系统，仅支持 Ubuntu/Debian 和 CentOS/RHEL 系列。"
    exit 1
fi

print_info "检测到操作系统: $OS $VERSION"

# ---------- 安装 Nginx ----------
install_nginx() {
    if command -v nginx &>/dev/null; then
        print_warning "Nginx 已安装，跳过安装步骤。"
        return 0
    fi

    print_info "正在安装 Nginx..."
    case $OS in
        ubuntu|debian)
            apt update -y
            apt install -y nginx
            ;;
        centos|rhel|rocky|fedora)
            if ! command -v epel-release &>/dev/null; then
                yum install -y epel-release
            fi
            yum install -y nginx
            ;;
        *)
            print_error "不支持的操作系统: $OS"
            exit 1
            ;;
    esac

    # 启动并设置开机自启
    systemctl start nginx
    systemctl enable nginx

    if systemctl is-active --quiet nginx; then
        print_success "Nginx 安装并启动成功。"
    else
        print_error "Nginx 启动失败，请检查日志。"
        exit 1
    fi
}

# ---------- 交互式获取配置 ----------
get_user_input() {
    echo ""
    print_info "开始交互式配置..."

    # 1. 文件存放目录
    read -p "请输入文件存放目录 (默认: /data/download): " DOWNLOAD_DIR
    DOWNLOAD_DIR=${DOWNLOAD_DIR:-/data/download}
    # 去除末尾斜杠
    DOWNLOAD_DIR=$(echo "$DOWNLOAD_DIR" | sed 's:/*$::')
    print_info "文件目录将设置为: $DOWNLOAD_DIR"

    # 2. 端口
    read -p "请输入监听端口 (默认: 80): " LISTEN_PORT
    LISTEN_PORT=${LISTEN_PORT:-80}
    if ! [[ "$LISTEN_PORT" =~ ^[0-9]+$ ]] || [ "$LISTEN_PORT" -lt 1 ] || [ "$LISTEN_PORT" -gt 65535 ]; then
        print_error "端口号无效，使用默认端口 80"
        LISTEN_PORT=80
    fi

    # 3. 域名或IP（用于显示访问地址）
    read -p "请输入您的域名或服务器IP (留空自动检测): " SERVER_NAME
    if [ -z "$SERVER_NAME" ]; then
        # 自动检测公网IP
        SERVER_NAME=$(curl -s ifconfig.me || curl -s icanhazip.com || echo "localhost")
    fi
    print_info "服务器地址: $SERVER_NAME"

    # 4. 是否开启目录浏览
    read -p "是否开启目录浏览 (autoindex)? [y/N]: " ENABLE_AUTOINDEX
    ENABLE_AUTOINDEX=${ENABLE_AUTOINDEX:-n}
    if [[ "$ENABLE_AUTOINDEX" =~ ^[Yy]$ ]]; then
        AUTOINDEX="on"
    else
        AUTOINDEX="off"
    fi

    # 5. 是否启用限速
    read -p "是否启用下载限速? [y/N]: " ENABLE_LIMIT
    ENABLE_LIMIT=${ENABLE_LIMIT:-n}
    if [[ "$ENABLE_LIMIT" =~ ^[Yy]$ ]]; then
        read -p "请输入每个连接的最大下载速度 (例如 1m, 500k, 默认 1m): " LIMIT_RATE
        LIMIT_RATE=${LIMIT_RATE:-1m}
        read -p "请输入不限速的初始大小 (例如 5m, 默认 5m): " LIMIT_AFTER
        LIMIT_AFTER=${LIMIT_AFTER:-5m}
    else
        LIMIT_RATE=""
        LIMIT_AFTER=""
    fi

    # 6. 是否启用 IP 白名单
    read -p "是否启用 IP 白名单? [y/N]: " ENABLE_WHITELIST
    ENABLE_WHITELIST=${ENABLE_WHITELIST:-n}
    WHITELIST_RULES=""
    if [[ "$ENABLE_WHITELIST" =~ ^[Yy]$ ]]; then
        echo "请输入允许的 IP 或 CIDR 网段，每行一个，输入空行结束。"
        WHITELIST_RULES=""
        while true; do
            read -p "允许的 IP/CIDR: " ip
            if [ -z "$ip" ]; then
                break
            fi
            WHITELIST_RULES+="        allow $ip;\n"
        done
        # 如果没有输入任何IP，则关闭白名单
        if [ -z "$WHITELIST_RULES" ]; then
            print_warning "未输入任何 IP，关闭白名单功能。"
            ENABLE_WHITELIST="n"
        else
            # 最后添加 deny all
            WHITELIST_RULES+="        deny all;"
        fi
    fi

    echo ""
    print_info "配置摘要:"
    echo "  - 文件目录: $DOWNLOAD_DIR"
    echo "  - 监听端口: $LISTEN_PORT"
    echo "  - 服务器地址: $SERVER_NAME"
    echo "  - 目录浏览: $AUTOINDEX"
    if [[ "$ENABLE_LIMIT" =~ ^[Yy]$ ]]; then
        echo "  - 下载限速: $LIMIT_RATE (初始不限速: $LIMIT_AFTER)"
    else
        echo "  - 下载限速: 关闭"
    fi
    if [[ "$ENABLE_WHITELIST" =~ ^[Yy]$ ]]; then
        echo "  - IP 白名单: 已启用"
    else
        echo "  - IP 白名单: 关闭"
    fi
    read -p "确认以上配置并继续? [Y/n]: " CONFIRM
    CONFIRM=${CONFIRM:-y}
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        print_info "用户取消，退出。"
        exit 0
    fi
}

# ---------- 创建目录并设置权限 ----------
prepare_directory() {
    print_info "创建目录: $DOWNLOAD_DIR"
    mkdir -p "$DOWNLOAD_DIR"
    # 确定 Nginx 用户
    NGINX_USER=$(ps -eo user,comm | grep -E 'nginx|www-data' | awk '{print $1}' | head -1)
    if [ -z "$NGINX_USER" ]; then
        NGINX_USER="www-data"  # 默认
    fi
    print_info "Nginx 用户为: $NGINX_USER"
    chown -R "$NGINX_USER":"$NGINX_USER" "$DOWNLOAD_DIR"
    chmod 755 "$DOWNLOAD_DIR"
    # 创建测试文件
    echo "测试文件 - 如果你能看到这个文件，说明下载服务配置成功！" > "$DOWNLOAD_DIR/test.txt"
    print_success "目录准备完成，并已创建测试文件 test.txt"
}

# ---------- 生成 Nginx 配置 ----------
generate_nginx_config() {
    local config_file=""
    local enable_site=""

    # 判断操作系统，选择配置路径
    if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
        config_file="/etc/nginx/sites-available/download"
        enable_site="/etc/nginx/sites-enabled/download"
    else
        config_file="/etc/nginx/conf.d/download.conf"
        # CentOS 等没有 sites-available，直接放在 conf.d
    fi

    # 如果配置文件已存在，询问是否覆盖
    if [ -f "$config_file" ]; then
        print_warning "配置文件 $config_file 已存在。"
        read -p "是否覆盖? [y/N]: " OVERWRITE
        OVERWRITE=${OVERWRITE:-n}
        if [[ ! "$OVERWRITE" =~ ^[Yy]$ ]]; then
            print_info "保留原有配置，退出。"
            exit 0
        fi
    fi

    # 构建配置内容
    local config_content=""
    config_content="server {\n"
    config_content+="    listen $LISTEN_PORT;\n"
    config_content+="    server_name $SERVER_NAME;\n"
    config_content+="    charset utf-8;\n"
    config_content+="    root $DOWNLOAD_DIR;\n"
    config_content+="    index index.html;\n\n"

    config_content+="    # 访问日志\n"
    config_content+="    access_log /var/log/nginx/download_access.log;\n"
    config_content+="    error_log /var/log/nginx/download_error.log;\n\n"

    config_content+="    location / {\n"
    config_content+="        autoindex $AUTOINDEX;\n"
    config_content+="        autoindex_format html;\n"
    config_content+="        autoindex_exact_size off;\n"
    config_content+="        autoindex_localtime on;\n"
    config_content+="        default_type application/octet-stream;\n\n"

    # 性能优化
    config_content+="        # 性能优化\n"
    config_content+="        sendfile on;\n"
    config_content+="        sendfile_max_chunk 1m;\n"
    config_content+="        tcp_nopush on;\n"
    config_content+="        aio on;\n"
    config_content+="        directio 10m;\n"
    config_content+="        directio_alignment 4096;\n"
    config_content+="        chunked_transfer_encoding on;\n"
    config_content+="        output_buffers 4 32k;\n\n"

    # 限速
    if [[ "$ENABLE_LIMIT" =~ ^[Yy]$ ]]; then
        config_content+="        # 下载限速\n"
        config_content+="        limit_rate $LIMIT_RATE;\n"
        config_content+="        limit_rate_after $LIMIT_AFTER;\n\n"
    fi

    # IP 白名单
    if [[ "$ENABLE_WHITELIST" =~ ^[Yy]$ ]]; then
        config_content+="        # IP 白名单\n"
        config_content+="$WHITELIST_RULES\n\n"
    fi

    # 可选的防盗链（这里注释掉，如需启用可自行添加）
    config_content+="        # 防盗链配置 (按需启用)\n"
    config_content+="        # valid_referers none blocked server_names $SERVER_NAME;\n"
    config_content+="        # if (\$invalid_referer) { return 403; }\n\n"

    config_content+="    }\n"
    config_content+="}\n"

    # 写入配置文件
    echo -e "$config_content" > "$config_file"
    print_success "配置文件已生成: $config_file"

    # 对 Ubuntu/Debian 启用站点
    if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
        if [ -L "$enable_site" ]; then
            rm -f "$enable_site"
        fi
        ln -s "$config_file" "$enable_site"
        print_success "站点已启用: $enable_site -> $config_file"
    fi
}

# ---------- 测试并重载 Nginx ----------
reload_nginx() {
    print_info "检查 Nginx 配置语法..."
    if nginx -t; then
        print_success "配置语法正确。"
        print_info "正在重载 Nginx..."
        systemctl reload nginx
        if systemctl is-active --quiet nginx; then
            print_success "Nginx 重载成功。"
        else
            print_error "Nginx 重载失败，请检查日志。"
            exit 1
        fi
    else
        print_error "Nginx 配置语法错误，请检查配置文件 $config_file"
        exit 1
    fi
}

# ---------- 防火墙配置 ----------
configure_firewall() {
    print_info "正在配置防火墙..."
    # 判断防火墙类型
    if command -v ufw &>/dev/null; then
        # Ubuntu UFW
        if ufw status | grep -q "Status: active"; then
            ufw allow "$LISTEN_PORT"/tcp
            print_success "UFW 防火墙已放行端口 $LISTEN_PORT"
        else
            print_warning "UFW 防火墙未激活，跳过。"
        fi
    elif command -v firewall-cmd &>/dev/null; then
        # CentOS firewalld
        if systemctl is-active --quiet firewalld; then
            firewall-cmd --permanent --add-port="$LISTEN_PORT"/tcp
            firewall-cmd --reload
            print_success "firewalld 防火墙已放行端口 $LISTEN_PORT"
        else
            print_warning "firewalld 未运行，跳过。"
        fi
    else
        print_warning "未检测到常见防火墙，请手动放行端口 $LISTEN_PORT。"
    fi
}

# ---------- 输出完成信息 ----------
print_summary() {
    echo ""
    print_success "========================================="
    print_success "🎉 Nginx 文件下载服务安装完成！"
    print_success "========================================="
    echo ""
    print_info "访问地址: http://$SERVER_NAME:$LISTEN_PORT/"
    print_info "测试文件: http://$SERVER_NAME:$LISTEN_PORT/test.txt"
    echo ""
    print_info "文件存放目录: $DOWNLOAD_DIR"
    print_info "配置文件路径: $config_file"
    print_info "访问日志: /var/log/nginx/download_access.log"
    print_info "错误日志: /var/log/nginx/download_error.log"
    echo ""
    if [[ "$AUTOINDEX" == "on" ]]; then
        print_info "目录浏览已开启，访问根路径即可看到文件列表。"
    else
        print_info "目录浏览已关闭，只能通过确切文件名下载。"
    fi
    echo ""
    print_info "如需修改配置，请编辑: $config_file"
    print_info "修改后执行: sudo nginx -t && sudo systemctl reload nginx"
    echo ""
    print_success "现在可以将你的文件放入 $DOWNLOAD_DIR 并分享链接了！"
}

# ---------- 主函数 ----------
main() {
    print_info "开始安装 Nginx 文件下载服务..."
    install_nginx
    get_user_input
    prepare_directory
    generate_nginx_config
    reload_nginx
    configure_firewall
    print_summary
}

# 运行主函数
main
