#!/bin/bash

# 闲鱼自动回复系统 - Let's Encrypt SSL证书初始化脚本
# 域名: xianyu.mosql.com
#
# 使用方法:
#   1. 确保域名 xianyu.mosql.com 已解析到服务器IP
#   2. 运行: chmod +x init-letsencrypt.sh && ./init-letsencrypt.sh
#   3. 脚本会自动申请SSL证书并启用HTTPS

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 配置
DOMAIN="xianyu.mosql.com"
EMAIL=""  # 留空则使用 --register-unsafely-without-email
STAGING=0  # 设为1使用Let's Encrypt测试环境（避免频率限制）
RSA_KEY_SIZE=4096

print_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
print_success() { echo -e "${GREEN}✅ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
print_error() { echo -e "${RED}❌ $1${NC}"; }

echo "========================================"
echo "  Let's Encrypt SSL证书初始化"
echo "  域名: ${DOMAIN}"
echo "========================================"
echo ""

# 检查docker和docker-compose
if ! command -v docker &> /dev/null; then
    print_error "Docker 未安装"
    exit 1
fi

if ! docker compose version &> /dev/null && ! command -v docker-compose &> /dev/null; then
    print_error "Docker Compose 未安装"
    exit 1
fi

# 确定docker compose命令
if docker compose version &> /dev/null; then
    COMPOSE_CMD="docker compose"
else
    COMPOSE_CMD="docker-compose"
fi

# 询问邮箱
if [ -z "$EMAIL" ]; then
    echo -n "请输入邮箱地址（用于证书过期通知，留空跳过）: "
    read -r EMAIL
fi

# 创建必要目录
print_info "创建证书目录..."
mkdir -p certbot/conf certbot/www

# 检查是否已有证书
if [ -d "certbot/conf/live/${DOMAIN}" ]; then
    print_warning "已存在 ${DOMAIN} 的证书"
    echo -n "是否要重新申请？(y/N): "
    read -r response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        print_info "跳过证书申请"
        print_info "如需启用HTTPS，请将 nginx/nginx-ssl.conf 复制为 nginx/nginx.conf 后重启nginx"
        exit 0
    fi
fi

# 下载推荐的TLS参数
print_info "下载推荐的TLS参数..."
if [ ! -e "certbot/conf/options-ssl-nginx.conf" ] || [ ! -e "certbot/conf/ssl-dhparams.pem" ]; then
    curl -s https://raw.githubusercontent.com/certbot/certbot/master/certbot-nginx/certbot_nginx/_internal/tls_configs/options-ssl-nginx.conf > "certbot/conf/options-ssl-nginx.conf"
    curl -s https://raw.githubusercontent.com/certbot/certbot/master/certbot/certbot/ssl-dhparams.pem > "certbot/conf/ssl-dhparams.pem"
    print_success "TLS参数下载完成"
fi

# 创建临时自签名证书（让nginx能先启动）
print_info "创建临时证书..."
CERT_PATH="certbot/conf/live/${DOMAIN}"
mkdir -p "${CERT_PATH}"
if [ ! -f "${CERT_PATH}/fullchain.pem" ]; then
    openssl req -x509 -nodes -newkey rsa:${RSA_KEY_SIZE} \
        -days 1 \
        -keyout "${CERT_PATH}/privkey.pem" \
        -out "${CERT_PATH}/fullchain.pem" \
        -subj "/CN=localhost" 2>/dev/null
    print_success "临时证书创建完成"
fi

# 使用SSL版本的nginx配置
print_info "启用HTTPS nginx配置..."
cp nginx/nginx-ssl.conf nginx/nginx.conf
print_success "已切换到HTTPS nginx配置"

# 启动nginx（使用临时证书）
print_info "启动nginx..."
$COMPOSE_CMD up -d nginx
sleep 3

# 删除临时证书
print_info "删除临时证书..."
rm -rf "certbot/conf/live/${DOMAIN}"
rm -rf "certbot/conf/archive/${DOMAIN}"
rm -rf "certbot/conf/renewal/${DOMAIN}.conf"

# 构建certbot参数
CERTBOT_ARGS="certonly --webroot -w /var/www/certbot"
CERTBOT_ARGS="${CERTBOT_ARGS} -d ${DOMAIN}"
CERTBOT_ARGS="${CERTBOT_ARGS} --rsa-key-size ${RSA_KEY_SIZE}"
CERTBOT_ARGS="${CERTBOT_ARGS} --agree-tos"
CERTBOT_ARGS="${CERTBOT_ARGS} --force-renewal"

if [ -n "$EMAIL" ]; then
    CERTBOT_ARGS="${CERTBOT_ARGS} --email ${EMAIL}"
else
    CERTBOT_ARGS="${CERTBOT_ARGS} --register-unsafely-without-email"
fi

if [ $STAGING -eq 1 ]; then
    CERTBOT_ARGS="${CERTBOT_ARGS} --staging"
    print_warning "使用Let's Encrypt测试环境"
fi

# 申请证书
print_info "申请Let's Encrypt证书..."
$COMPOSE_CMD run --rm certbot ${CERTBOT_ARGS}

if [ $? -eq 0 ]; then
    print_success "SSL证书申请成功！"
else
    print_error "SSL证书申请失败"
    print_warning "请确保:"
    print_warning "  1. 域名 ${DOMAIN} 已正确解析到此服务器"
    print_warning "  2. 服务器80端口可从外网访问"
    print_warning "  3. 防火墙已放行80和443端口"

    # 恢复HTTP-only配置
    print_info "恢复HTTP配置..."
    git checkout nginx/nginx.conf 2>/dev/null || true
    $COMPOSE_CMD restart nginx
    exit 1
fi

# 重新加载nginx以使用新证书
print_info "重新加载nginx配置..."
$COMPOSE_CMD exec nginx nginx -s reload

print_success "🎉 HTTPS配置完成！"
echo ""
echo "========================================"
echo "  部署信息"
echo "========================================"
echo ""
echo "  🌐 访问地址: https://${DOMAIN}"
echo "  🔐 证书将自动续期（certbot容器每12小时检查）"
echo ""
echo "  📋 默认登录信息:"
echo "     用户名: admin"
echo "     密码:   admin123"
echo ""
echo "  ⚠️  请务必修改默认密码！"
echo "========================================"
