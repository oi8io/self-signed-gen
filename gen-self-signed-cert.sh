#!/usr/bin/env bash
#
# gen-self-signed-cert.sh —— 单域名的本地可信证书：一根本地 CA + 一张叶子证书
#
# 用法：./gen-self-signed-cert.sh <域名>
#   可调项、产物清单、各平台信任命令，全部集中在文件末尾的附录 A–D。
#
# 退出码：0 成功；1 参数错误；2 执行失败

set -euo pipefail

WORK_DIR=""
cleanup() {
    [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ] && rm -rf "$WORK_DIR"
    return 0
}
trap cleanup EXIT

die() {
    printf '错误：%s\n' "$1" >&2
    exit "${2:-2}"
}

usage() {
    cat >&2 <<'USAGE'
用法：gen-self-signed-cert.sh <域名>

  域名形式：example.com / app.example.com / *.example.com / 127.0.0.1
  环境变量：CERT_OUT_DIR、CA_DIR、DAYS、CA_DAYS（默认值见脚本末尾附录 A）
USAGE
}

# ---------- 参数检查：有且仅有一个 ----------
[ "$#" -eq 1 ] || { usage; exit 1; }
case "$1" in
    -h|--help|-) usage; exit 1 ;;
esac
[ -n "$(printf '%s' "$1" | tr -d '[:space:]')" ] || { usage; exit 1; }

command -v openssl >/dev/null 2>&1 || die "未找到 openssl，请先安装"

RAW="$1"

# ---------- 归一化：小写、去协议/路径/端口/末尾点、去前导 *. ----------
DOMAIN=$(printf '%s' "$RAW" \
    | tr 'A-Z' 'a-z' \
    | sed -e 's#^[a-z][a-z0-9+.-]*://##' \
          -e 's#^/##' \
          -e 's#[/?#].*$##' \
          -e 's#:[0-9][0-9]*$##' \
          -e 's#\.$##')

case "$DOMAIN" in
    \*.*) DOMAIN="${DOMAIN#\*.}" ;;
esac

[ -n "$DOMAIN" ] || die "域名不能为空（原始输入：$RAW）" 1

# ---------- 输入是 IPv4 还是域名 ----------
IS_IP=0
if printf '%s' "$DOMAIN" | grep -Eq '^[0-9]{1,3}(\.([0-9]{1,3})){3}$'; then
    IS_IP=1
    set -- $(printf '%s' "$DOMAIN" | tr '.' ' ')
    [ "$#" -eq 4 ] || die "非法 IPv4 地址：$DOMAIN" 1
    for octet in "$@"; do
        case "$octet" in
            ''|*[!0-9]*) die "非法 IPv4 地址：$DOMAIN" 1 ;;
        esac
        [ "$octet" -le 255 ] || die "非法 IPv4 地址：$DOMAIN" 1
    done
fi

if [ "$IS_IP" -eq 0 ]; then
    printf '%s' "$DOMAIN" \
        | grep -Eq '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$' \
        || die "非法域名：$RAW" 1
    [ "$(printf '%s' "$DOMAIN" | wc -c | tr -d ' ')" -le 253 ] \
        || die "域名过长（超过 253 字符）：$DOMAIN" 1
fi

# 域名带点则顺带签发一级通配，一条命令覆盖 app./api./www.
WILDCARD=0
if [ "$IS_IP" -eq 0 ]; then
    case "$DOMAIN" in
        *.*) WILDCARD=1 ;;
    esac
fi

# ---------- 路径与有效期 ----------
ROOT_DIR=$(pwd)
OUT_DIR="${CERT_OUT_DIR:-$ROOT_DIR/certs/$DOMAIN}"
CA_DIR="${CA_DIR:-$ROOT_DIR/certs/_ca}"
DAYS="${DAYS:-3650}"
CA_DAYS="${CA_DAYS:-3650}"

case "$DAYS" in ''|*[!0-9]*) die "DAYS 必须是正整数：$DAYS" 1 ;; esac
case "$CA_DAYS" in ''|*[!0-9]*) die "CA_DAYS 必须是正整数：$CA_DAYS" 1 ;; esac

mkdir -p "$OUT_DIR" "$CA_DIR"
umask 077
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/selfsigned.XXXXXX")

printf '域名       : %s%s\n' "$DOMAIN" "$([ "$WILDCARD" -eq 1 ] && printf ' (+ *.%s)' "$DOMAIN")"
printf '输出目录   : %s\n' "$OUT_DIR"

# ---------- 第 1 步：本地根 CA（存在则复用） ----------
if [ -f "$CA_DIR/ca.key" ] && [ -f "$CA_DIR/ca.crt" ]; then
    printf '根 CA      : 复用 %s\n' "$CA_DIR/ca.crt"
else
    cat > "$WORK_DIR/ca.cnf" <<'EOF'
[req]
default_bits       = 2048
prompt             = no
default_md         = sha256
distinguished_name = ca_dn
x509_extensions    = v3_ca

[ca_dn]
C  = CN
ST = Guangdong
L  = Shenzhen
O  = Local Dev
OU = Self-Signed CA
CN = Local Dev Root CA

[v3_ca]
basicConstraints       = critical, CA:TRUE, pathlen:0
keyUsage               = critical, keyCertSign, cRLSign
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always
EOF
    openssl genrsa -out "$CA_DIR/ca.key" 2048 2>/dev/null
    chmod 600 "$CA_DIR/ca.key"
    openssl req -x509 -new -nodes -key "$CA_DIR/ca.key" -sha256 \
        -days "$CA_DAYS" -out "$CA_DIR/ca.crt" -config "$WORK_DIR/ca.cnf" 2>/dev/null
    printf '根 CA      : 新建 %s（有效期 %s 天）\n' "$CA_DIR/ca.crt" "$CA_DAYS"
fi

# ---------- 第 2 步：服务器证书，SAN 必须显式写死 ----------
if [ "$IS_IP" -eq 1 ]; then
    SAN_LINES="IP.1 = $DOMAIN"
else
    SAN_LINES="DNS.1 = $DOMAIN"
    if [ "$WILDCARD" -eq 1 ]; then
        SAN_LINES="$SAN_LINES
DNS.2 = *.$DOMAIN"
    fi
fi

CN_LINE="CN = $DOMAIN"
if [ "$(printf '%s' "$DOMAIN" | wc -c | tr -d ' ')" -gt 63 ]; then
    CN_LINE=""
fi

cat > "$WORK_DIR/server.cnf" <<EOF
[req]
default_bits       = 2048
prompt             = no
default_md         = sha256
distinguished_name = server_dn

[server_dn]
C  = CN
ST = Guangdong
L  = Shenzhen
O  = Local Dev
OU = Dev Server
${CN_LINE}

[v3_req]
basicConstraints       = critical, CA:FALSE
keyUsage               = critical, digitalSignature, keyEncipherment
extendedKeyUsage       = serverAuth
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid, issuer
subjectAltName         = @alt_names

[alt_names]
${SAN_LINES}
EOF

openssl req -new -newkey rsa:2048 -nodes \
    -keyout "$OUT_DIR/server.key" -out "$OUT_DIR/server.csr" \
    -config "$WORK_DIR/server.cnf" 2>/dev/null
chmod 600 "$OUT_DIR/server.key"

# ---------- 第 3 步：用根 CA 签发叶子证书 ----------
openssl x509 -req -sha256 -days "$DAYS" \
    -in "$OUT_DIR/server.csr" \
    -CA "$CA_DIR/ca.crt" -CAkey "$CA_DIR/ca.key" \
    -CAcreateserial -CAserial "$CA_DIR/ca.srl" \
    -out "$OUT_DIR/server.crt" \
    -extfile "$WORK_DIR/server.cnf" -extensions v3_req 2>/dev/null

cat "$OUT_DIR/server.crt" "$CA_DIR/ca.crt" > "$OUT_DIR/fullchain.crt"
cp "$CA_DIR/ca.crt" "$OUT_DIR/ca.crt"
chmod 644 "$OUT_DIR/server.crt" "$OUT_DIR/fullchain.crt" "$OUT_DIR/ca.crt"

# ---------- 自检 ----------
openssl verify -CAfile "$CA_DIR/ca.crt" "$OUT_DIR/server.crt" >/dev/null 2>&1 \
    || die "自检失败：server.crt 无法用 ca.crt 验证，请检查 openssl 版本与配置"

echo
echo "=== 服务器证书 ==="
openssl x509 -in "$OUT_DIR/server.crt" -noout -subject -issuer -dates 2>/dev/null \
    || openssl x509 -in "$OUT_DIR/server.crt" -noout -text | sed -n '1,20p'
echo
openssl x509 -in "$OUT_DIR/server.crt" -noout -ext subjectAltName 2>/dev/null \
    | sed -e 's/^/  /' \
    || openssl x509 -in "$OUT_DIR/server.crt" -text -noout | grep -A1 'Subject Alternative Name' | sed -e 's/^/  /'

cat <<EOF

=== 产物 ===
  $OUT_DIR/server.key       私钥（chmod 600）
  $OUT_DIR/server.crt       服务器证书
  $OUT_DIR/fullchain.crt    server.crt + ca.crt
  $OUT_DIR/ca.crt           根 CA 证书（用于导入信任）
  $OUT_DIR/server.csr       签名请求（留档，可删）

=== nginx 配置 ===
  ssl_certificate     $OUT_DIR/fullchain.crt;
  ssl_certificate_key $OUT_DIR/server.key;
  ssl_protocols       TLSv1.2 TLSv1.3;

=== 信任根 CA 的命令 ===
  macOS   : sudo security add-trusted-cert -d -r trustRoot \\
              -k /Library/Keychains/System.keychain "$OUT_DIR/ca.crt"
  Ubuntu  : sudo cp "$OUT_DIR/ca.crt" /usr/local/share/ca-certificates/local-dev-ca.crt \\
              && sudo update-ca-certificates
  CentOS  : sudo cp "$OUT_DIR/ca.crt" /etc/pki/ca-trust/source/anchors/local-dev-ca.crt \\
              && sudo update-ca-trust
  Windows : certutil -addstore -f "ROOT" "$OUT_DIR/ca.crt"

验证连通性：curl --cacert "$OUT_DIR/ca.crt" https://$DOMAIN/
EOF

printf '\n完成：%s\n' "$DOMAIN"

# ==============================================================================
# 附录 A：可调参数（环境变量，不是命令行参数）
# ------------------------------------------------------------------------------
#   CERT_OUT_DIR  叶子证书产物目录，默认 $PWD/certs/<域名>
#                 例：CERT_OUT_DIR=/etc/ssl/demo ./gen-self-signed-cert.sh demo.local
#
#   CA_DIR        根 CA 存放目录，默认 $PWD/certs/_ca
#                 该目录下已有 ca.key + ca.crt 时直接复用，不会重复生成；
#                 想让多个域名共用同一张根证书，就把它们指向同一个 CA_DIR
#
#   DAYS          叶子证书有效期（天），默认 3650
#                 例：DAYS=397 ./gen-self-signed-cert.sh example.com
#                 397 是公有信任链在 Chrome 里的上限；本地根不受此限制，
#                 这里只是让开发环境的有效期贴近生产习惯
#
#   CA_DAYS       根 CA 有效期（天），默认 3650
#
#   只改 DN（C/ST/L/O/OU）的话，直接编辑本文件里 ca.cnf / server.cnf 两段 heredoc。
#
# 附录 B：产物清单
# ------------------------------------------------------------------------------
#   server.key       服务器私钥，RSA 2048，未加密（-nodes），权限 600
#   server.csr       证书签名请求，留档用，部署时可删
#   server.crt       叶子证书，由本地 CA 签发，含 subjectAltName
#   fullchain.crt    server.crt + ca.crt 拼接，nginx 的 ssl_certificate 用这个
#   ca.crt           根 CA 证书，需导入系统/浏览器信任库
#   ca.srl           CA 序列号记录，位于 CA_DIR，删了会导致序列号重号
#
# 附录 C：各平台信任根证书
# ------------------------------------------------------------------------------
#   macOS 系统级（需 sudo，Chrome/Safari/curl 生效）：
#     sudo security add-trusted-cert -d -r trustRoot \
#          -k /Library/Keychains/System.keychain ca.crt
#   macOS 用户级（不需要 sudo，仅当前用户生效）：
#     security add-trusted-cert -d -r trustRoot -k ~/Library/Keychains/login.keychain-db ca.crt
#
#   Debian/Ubuntu：
#     sudo cp ca.crt /usr/local/share/ca-certificates/local-dev-ca.crt
#     sudo update-ca-certificates
#
#   RHEL/CentOS：
#     sudo cp ca.crt /etc/pki/ca-trust/source/anchors/local-dev-ca.crt
#     sudo update-ca-trust
#
#   Windows（管理员 cmd/PowerShell）：
#     certutil -addstore -f "ROOT" ca.crt
#
#   Firefox 用独立信任库（NSS），不读系统库，两种办法：
#     1) 设置页搜 "证书" -> 查看证书 -> 证书颁发机构 -> 导入 ca.crt（勾选"信任此 CA 识别网站"）
#     2) about:config 里把 security.enterprise_roots.enabled 设为 true，改用系统库
#
#   Java 有独立 cacerts，与服务端 TLS 无关；只在客户端是 JVM 时才需要
#     keytool -importcert -alias local-dev-ca -file ca.crt -keystore $JAVA_HOME/lib/security/cacerts
#
#   iOS（把 ca.crt 用 AirDrop、邮件或文件 App 传到设备，系统当成描述文件处理）：
#     设置 -> 通用 -> VPN 与设备管理（或"已下载描述文件"）-> 安装
#     装完还要开信任：设置 -> 通用 -> 关于本机 -> 证书信任设置 -> 打开该 CA 的完全信任
#     只装不信任的话，Safari 仍然报不受信任
#
#   Android（各家 UI 路径略有差异）：
#     设置 -> 安全 -> 加密与凭据 -> 安装证书 -> CA 证书 -> 选择 ca.crt
#     Android 7 起，App 默认不信任用户安装的 CA，只有浏览器和显式声明
#     network_security_config 的 App 会认；遇到 App 内报错，先确认这一点
#
# 附录 D：已知行为
# ------------------------------------------------------------------------------
#   * SAN 是唯一被浏览器校验的域名位，CN 只作展示；缺 SAN 的证书在 Chrome 报
#     ERR_CERT_COMMON_NAME_INVALID，2017 年起如此。
#   * 一级通配 *.example.com 只匹配 app.example.com，不匹配 a.b.example.com。
#   * 根 CA 的 pathlen:0 限制：只能签叶子证书，不能再签中间 CA。
#   * openssl verify 通过只证明"链能连上"，不证明浏览器会放行；主机名匹配、
#     有效期、EKU、信任锚任一不符都会报错，详见 more.md 的报错对照。
#   * 叶子证书有效期 3650 天在本地根下可用；一旦换成公有 CA 签发，
#     Chrome 会按 398 天上限拒绝。
# ==============================================================================
