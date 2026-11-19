# 用 OpenSSL 给自己签一张浏览器认的证书

本地调接口，服务端只开了 https，很快会撞上证书问题。内网域名没有公网解析，公有 CA 不签，只能自己签一份。自己签的证书浏览器默认不认，一访问就一片红。

下面先说清信任链和 SAN 两个概念，再走一遍签发流程，最后用真实握手验证。

## 一张自签证书够用吗

TLS 客户端验证书时，顺着签发关系往上找，直到碰上本地信任库里已有的某张证书。碰上了，链能连，证书受信；碰不上，报 `ERR_CERT_AUTHORITY_INVALID`。

单张自签名证书也能用。导入系统钥匙串，把“使用此证书时”设成“始终信任”，浏览器同样放行。代价是每加一个域名就要重新生成、重新导入一次；它本身没有 `CA:TRUE`，签不了别的证书；签名用的私钥只有一把，泄露就得全部重来。

换成一层的 CA 结构就宽松得多。根证书建一次、导入一次，之后每个域名签一张叶子证书，服务端换证书不用再动系统设置。下面的流程按这个结构来写。

## 域名写在 subjectAltName

早年的证书把域名填在 `commonName`（CN），客户端比对这个字段。2017 年起 CA/Browser Forum 的基线要求把 `subjectAltName` 列成公有证书的必备扩展，Chrome 58 同期取消了 CN 的回退匹配。现在 CN 只是展示信息，判断域名只看 SAN。

配置写得再正确、CN 一个字不差，只要 SAN 缺失或者对不上，Chrome 就报：

```
ERR_CERT_COMMON_NAME_INVALID
```

SAN 的写法：

```ini
[alt_names]
DNS.1 = example.com
DNS.2 = *.example.com
```

等价于单行的 `subjectAltName = DNS:example.com, DNS:*.example.com`。通配只顶一级，`*.example.com` 命中 `app.example.com`，不命中 `a.b.example.com`，需要多级就逐条列出来。

## 三步签下来

### 建根 CA

```bash
openssl genrsa -out ca.key 2048
openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 -out ca.crt -config ca.cnf
```

```ini
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
```

三个扩展决定这张证书能不能当签发者。`CA:TRUE` 必须有，缺了它，签出的叶子证书在链验证时会被判“签发者不是 CA”。`pathlen:0` 表示它下面不允许再出现中间 CA，只能签叶子，本地开发用不到中间层。`keyUsage` 限定为 `keyCertSign,cRLSign`，`critical` 要求客户端必须遵守，如果这里只写 `digitalSignature`，拿它去签别的证书就是越权。

私钥加不加密由 `-nodes` 决定。换成 `-des3` 或 `-aes256` 会每次索要密码，交互式没问题，脚本里会一直等输入。本地开发 CA 用明文私钥、`chmod 600`、不进版本库就够了；团队共用的 CA 再上密码，密码通过 `-passin file:pass.txt` 传入。

### 签叶子证书

先出私钥和 CSR：

```bash
openssl req -new -newkey rsa:2048 -nodes -keyout server.key -out server.csr -config server.cnf
```

```ini
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
CN = example.com

[v3_req]
basicConstraints       = critical, CA:FALSE
keyUsage               = critical, digitalSignature, keyEncipherment
extendedKeyUsage       = serverAuth
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid, issuer
subjectAltName         = @alt_names

[alt_names]
DNS.1 = example.com
DNS.2 = *.example.com
```

CSR 里的扩展段自己不会跑到证书上。`[v3_req]` 写在这个文件里，只有签名那一步用 `-extfile` 指回来，内容才真正进证书。不少人把 SAN 认真写进 CSR，签名时却漏了 `-extfile`，签出的证书 SAN 是空的，然后回头怀疑浏览器。

### 用 CA 签

```bash
openssl x509 -req -sha256 -days 3650 \
  -in server.csr -CA ca.crt -CAkey ca.key \
  -CAcreateserial -CAserial ca.srl \
  -out server.crt -extfile server.cnf -extensions v3_req
```

`-extfile` 加 `-extensions v3_req` 是扩展真正落地的地方。`-CAserial` 记录签发序列号，`ca.srl` 删掉会导致序列号重号，有些客户端直接拒。`-days` 得单独给，`openssl x509 -req` 不继承 CA 的有效期。

签完先看 SAN 对不对，再往下走：

```
$ openssl x509 -in server.crt -noout -ext subjectAltName
X509v3 Subject Alternative Name:
    DNS:example.com, DNS:*.example.com
```

## verify 通过，浏览器未必放行

`openssl verify -CAfile ca.crt server.crt` 只回答一个问题：这条链能不能连上这根 CA。主机名、EKU、浏览器自己的规则，它一概不管。

要确认真能用，跑一次真实握手：

```bash
openssl s_server -accept 9443 -cert fullchain.crt -key server.key -www &

curl -sS --cacert ca.crt --resolve example.com:9443:127.0.0.1 \
  -o /dev/null -w '%{http_code}\n' https://example.com:9443/

curl -sS --cacert ca.crt --resolve app.example.com:9443:127.0.0.1 \
  -o /dev/null -w '%{http_code}\n' https://app.example.com:9443/
```

两次都该是 `200`。再去掉 `--cacert` 跑一遍，预期失败：

```
curl: (60) SSL certificate problem: unable to get local issuer certificate
```

这条反例证明问题出在缺少信任锚，而不是证书写坏了。带上 CA 仍然失败，就查 SAN、有效期和 EKU。

线上服务用 `s_client` 更直接：

```bash
openssl s_client -connect example.com:443 -servername example.com \
  -CAfile ca.crt -verify_return_error </dev/null 2>&1 \
  | grep -E 'Verify return code|subject='
```

`-servername` 别省。不带 SNI，服务端可能返回默认站点的证书，验的就不是你以为的那张。

## 接进 nginx

```nginx
server {
    listen 443 ssl;
    server_name example.com app.example.com;

    ssl_certificate     /etc/ssl/demo/fullchain.crt;
    ssl_certificate_key /etc/ssl/demo/server.key;

    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
}
```

`ssl_certificate` 指向拼接后的链，而不是单独的 `server.crt`。客户端要顺着链往上爬，只发叶子时某些客户端会因为找不到签发者而放弃：

```bash
cat server.crt ca.crt > fullchain.crt
```

Apache 拆成两项：

```apache
SSLCertificateFile      /etc/ssl/demo/server.crt
SSLCertificateKeyFile   /etc/ssl/demo/server.key
SSLCertificateChainFile /etc/ssl/demo/ca.crt
```

本地调试别开 HSTS。浏览器一旦记住强制 HTTPS，证书再出问题就是硬失败，清缓存也难收回。

## 把根证书塞进信任库

Chrome 不报警，不代表所有工具都认。各家的信任库是分开的：

| 客户端 | 读哪个库 |
|---|---|
| Chrome、Safari、系统 curl（macOS） | 系统钥匙串 |
| curl（Linux） | `/etc/ssl/certs` |
| Firefox | 自带的 NSS 库 |
| Java | `$JAVA_HOME/lib/security/cacerts` |
| Node.js | 自带根证书包，可用 `NODE_EXTRA_CA_CERTS` 指过去 |
| iOS | 系统装描述文件，再在“证书信任设置”里开完全信任 |
| Android | 系统“用户证书”，Android 7 起 App 默认不认 |

macOS 系统级导入：

```bash
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain ca.crt
```

只给当前用户用，不加 sudo：

```bash
security add-trusted-cert -d -r trustRoot -k ~/Library/Keychains/login.keychain-db ca.crt
```

手机、Linux、Windows、Firefox、Java 的命令在脚本末尾的附录 C。手机上只装证书还不够，iOS 要去“证书信任设置”里打开完全信任，Android 7 起 App 默认不信任用户装的 CA，只有浏览器认。

## 几个常见报错

| 报错 | 原因 | 处理 |
|---|---|---|
| `ERR_CERT_AUTHORITY_INVALID` | 根证书没导入，或 `ssl_certificate` 指成了叶子 | 导入 CA，补全链 |
| `ERR_CERT_COMMON_NAME_INVALID` | 证书没 SAN，或 SAN 与访问域名不符 | 重签，把域名写进 `subjectAltName` |
| `ERR_CERT_DATE_INVALID` | 证书过期、系统时间偏移、`-days` 给小了 | 重签，校准时间 |
| `ERR_SSL_VERSION_OR_CIPHER_MISMATCH` | 只开了 SSLv3、TLS1.0，或私钥与证书不配对 | 至少 TLSv1.2，核对私钥 |
| `curl: (60) unable to get local issuer certificate` | 客户端信任库里没有这根 CA | `--cacert` 或导入系统库 |
| nginx 报 `cannot load certificate` | 路径错、私钥不配套、PEM 头被改坏 | 比对 `-modulus` |

## 旧文章里几处对不上的地方

很多教程停在 2017 年前后，照着敲能出文件，但 Chrome 一定红。下面这几处是我在原文里逐条核对出来的。

原来的 `[req]` 段常带一行 `encrypt_key = no`。OpenSSL 不认这个指令，写了等于没写，控制私钥加密的是命令行 `-nodes`。

同一段里的 `default_keyfile = oats.key` 是上一手配置的残留。一旦触发，就会在当前目录悄悄落一个密钥文件。

把 `CN = *.mx.io` 写死在配置里，换域名要手改 CN 和 SAN 两处，改漏一处就回到前面 SAN 的报错。让域名当唯一变量、临时生成配置文件，才谈得上复用。

`-config <(cat cfg)` 用了 bash 的进程替换，`sh`、`dash` 和部分 CI 环境里跑不通。换成临时文件更稳，也省得解释。

`openssl genrsa -des3` 会交互索要密码，放进流水线就是挂死。要加密就用 `-aes256 -passout file:pass.txt`。

3650 天在本地根下没问题，换成公有 CA 签发，Chrome 会按 398 天上限直接拒绝。两种信任锚别共用一份期限。

`server.key`、`ca.key` 一律 600，并且加进 `.gitignore`。证书本身泄露无所谓，私钥进了公开仓库就是别人拿你的名义提供服务。

## 脚本

三步签发、SAN 注入、自检和打印配置都收在 [`gen-self-signed-cert.sh`](gen-self-signed-cert.sh)，可调项走环境变量，默认值写在脚本末尾附录 A，各平台信任命令在附录 C，产物清单在附录 B。安装与日常用法见 [readme.md](readme.md)。

根 CA 首次生成、之后复用，多个域名共用同一根信任锚；SAN 自动注入，域名带点则顺带加一级通配；IP 入参自动改用 `IP.1`；签完自检并打印 nginx 片段。

### 用法

```bash
chmod +x gen-self-signed-cert.sh

./gen-self-signed-cert.sh example.com        # 产物在 ./certs/example.com/
./gen-self-signed-cert.sh '*.example.com'    # 泛域名写法结果相同
./gen-self-signed-cert.sh 127.0.0.1          # IP 入参，SAN 写 IP.1

DAYS=397 CA_DIR=/etc/ssl/_ca ./gen-self-signed-cert.sh app.example.com
```

产物一共六项。`fullchain.crt` 给 nginx，`ca.crt` 拿去导入信任库，`server.csr` 留档、部署时可以删。`certs/_ca/ca.srl` 是签名序列号记录，别删，删了会重号。

| 文件 | 用途 |
|---|---|
| `server.key` | 服务器私钥，RSA 2048，未加密，权限 600 |
| `server.crt` | 叶子证书，含 SAN |
| `fullchain.crt` | `server.crt` + `ca.crt`，nginx `ssl_certificate` 用它 |
| `ca.crt` | 根 CA 证书，导入信任库用这一张 |
| `server.csr` | 签名请求，留档用 |

四个环境变量，不传就用默认值：

| 变量 | 默认 | 说明 |
|---|---|---|
| `CERT_OUT_DIR` | `$PWD/certs/<域名>` | 叶子证书输出目录 |
| `CA_DIR` | `$PWD/certs/_ca` | 根 CA 目录，已有则复用 |
| `DAYS` | 3650 | 叶子证书有效期 |
| `CA_DAYS` | 3650 | 根 CA 有效期 |

脚本末尾的附录 A 到 D 还写了 DN 字段怎么改、各平台信任命令、以及几条已知行为，不用再翻本文。
