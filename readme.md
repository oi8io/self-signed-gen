# 开发环境自签证书生成器

给局域网服务和本机开发签自签证书。一条命令，一个域名或内网 IP，得到一张客户端导入根 CA 后就认的证书。

```bash
./gen-self-signed-cert.sh example.com
```

跑完 `certs/example.com/` 下有私钥、证书、证书链，终端同时打印 nginx 配置片段、导入根证书的命令和 curl 自检命令。

## 什么场景用它

内网域名拿不到公有 CA 的证书，浏览器对自签证书一律拦一道。这个脚本就是给这些地方用的：

- 家里的 NAS、路由器面板、内网 Git 或 API 服务要上 https，域名是自己配的 `example.com`、`git.lab`，公网查不到
- 本机开发要 https。`localhost` 和 `127.0.0.1` 本身就是安全上下文，但内网域名和局域网 IP 不是，Cookie 的 `Secure`、Service Worker、剪贴板 API 在这些地址上一律失效
- 内网机器用 IP 直连，`https://192.168.1.10` 不想每次点“继续访问”
- 手机、平板、同事的电脑要访问你的开发机，不想每台设备手动加例外
- 机器不出网，拿不到 Let's Encrypt 的签发服务

反过来，对公网开放的服务别用它。那种场景应该走 Let's Encrypt、ZeroSSL 这类公有 CA，自签证书在公网只会让别人看到警告。

## 它能做什么

- 根 CA 建一次，之后每个域名签一张叶子证书复用同一根。系统或手机信任一次，后面换证书不用再动设置。
- `subjectAltName` 自动写对：域名本身加一级通配（`example.com`、`*.example.com`）。2017 年后浏览器只认 SAN，写在 `commonName` 里的域名一律报错。
- 传 IPv4 地址时改用 `IP.1`，不用为内网 IP 另建一套配置。
- 直接产出拼接好的 `fullchain.crt`，nginx 的 `ssl_certificate` 填它就行，不用自己 cat。
- 跑完把三样东西打印出来：nginx 片段、各平台导入根证书的命令、`curl --cacert` 自检命令，路径都按当前输出目录算好。
- 参数不对直接退出，退出码 1。非法域名、域名格式错误、参数个数不对都不会留下半张证书。

## 快速开始

```bash
git clone https://github.com/oi8io/self-signed-gen.git
cd self-signed-gen
chmod +x gen-self-signed-cert.sh

./gen-self-signed-cert.sh example.com
```

输出：

```
域名       : example.com (+ *.example.com)
输出目录   : /Users/you/self-signed-gen/certs/example.com
根 CA      : 新建 /Users/you/self-signed-gen/certs/_ca/ca.crt（有效期 3650 天）

=== 服务器证书 ===
subject= /C=CN/ST=Guangdong/L=Shenzhen/O=Local Dev/OU=Dev Server/CN=example.com
issuer= /C=CN/ST=Guangdong/L=Shenzhen/O=Local Dev/OU=Self-Signed CA/CN=Local Dev Root CA
...
```

## 信任根证书

证书生成完还不算完，客户端得先认识签发它的那根 CA。脚本会把当前路径的命令打出来，下面是 macOS 系统级：

```bash
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain certs/_ca/ca.crt
```

Linux、Windows、Firefox（有独立的 NSS 库）、Java，以及 iOS / Android 装描述文件的步骤，见 [more.md](more.md) 和脚本末尾的附录 C。

## 接进 nginx

```nginx
server {
    listen 443 ssl;
    server_name example.com;

    ssl_certificate     certs/example.com/fullchain.crt;
    ssl_certificate_key certs/example.com/server.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
}
```

## 产物

| 文件 | 用途 |
|---|---|
| `server.key` | 服务器私钥，RSA 2048，未加密，权限 600 |
| `server.crt` | 叶子证书，含 SAN |
| `fullchain.crt` | `server.crt` + `ca.crt`，给 nginx 用 |
| `ca.crt` | 根 CA 证书，拿去导入信任库 |
| `server.csr` | 签名请求，留档，可删 |
| `certs/_ca/ca.srl` | 签发序列号记录，别删，删了会重号 |

`certs/` 里是明文私钥，别提交到仓库。

## 用法与环境变量

```bash
./gen-self-signed-cert.sh example.com            # 域名
./gen-self-signed-cert.sh '*.example.com'        # 泛域名，结果相同
./gen-self-signed-cert.sh 192.168.1.10       # 内网 IP
```

| 变量 | 默认 | 说明 |
|---|---|---|
| `CERT_OUT_DIR` | `$PWD/certs/<域名>` | 证书输出目录 |
| `CA_DIR` | `$PWD/certs/_ca` | 根 CA 目录，已存在则复用 |
| `DAYS` | 3650 | 叶子证书有效期 |
| `CA_DAYS` | 3650 | 根 CA 有效期 |

```bash
# 多个域名共用同一根 CA
CA_DIR=/etc/ssl/_ca ./gen-self-signed-cert.sh app.example.com

# 有效期改成 397 天
DAYS=397 ./gen-self-signed-cert.sh example.com
```

## 环境与限制

macOS 自带的 LibreSSL 3.3 和 Linux 上的 OpenSSL 1.1 / 3.x 都测过，脚本只依赖 `openssl` 与 bash。

限制写在明处：叶子证书固定 RSA 2048；IP 只支持 IPv4；通配符只顶一级，`*.example.com` 不覆盖 `a.b.example.com`；DN 里的 C/ST/L/O 想换成自己的，直接改脚本里的两段 heredoc。

## 文档

- [more.md](more.md)：信任链怎么验证、SAN 的历史、真实握手测试、报错对照表、旧教程里的坑
- 脚本末尾附录 A–D：参数默认值、产物清单、各平台信任命令、几条已知行为
