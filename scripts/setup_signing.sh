#!/bin/bash
# 生成 Peel 专用的本地签名证书（只运行一次）。
# 证书放在单独的钥匙串 ~/Library/Application Support/Peel/signing/peel-signing.keychain-db 里，
# 不改动登录钥匙串、不加入钥匙串搜索列表、不改系统信任设置。
# 作用：每次重新编译后签名身份不变，系统里的“辅助功能”授权一直有效。
# 删除方法：security delete-keychain "$KC"; rm -rf "$DIR"
set -euo pipefail
DIR="$HOME/Library/Application Support/Peel/signing"
KC="$DIR/peel-signing.keychain-db"
PASS="peel-local"          # 这个钥匙串只放这一张自签名证书
NAME="Peel Local Signing"

if [ -f "$KC" ] && security find-identity -p codesigning "$KC" 2>/dev/null | grep -q "$NAME"; then
    echo "✓ 签名证书已存在"; exit 0
fi
mkdir -p "$DIR"; cd "$DIR"
BEFORE=$(security list-keychains -d user)

cat > cert.cnf <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
OPENSSL=$(command -v /opt/homebrew/bin/openssl || command -v openssl)
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 -config cert.cnf 2>/dev/null
"$OPENSSL" pkcs12 -export -legacy -inkey key.pem -in cert.pem -out peel.p12 -passout pass:$PASS -name "$NAME" 2>/dev/null \
  || "$OPENSSL" pkcs12 -export -inkey key.pem -in cert.pem -out peel.p12 -passout pass:$PASS -name "$NAME"

[ -f "$KC" ] && security delete-keychain "$KC" 2>/dev/null || true
security create-keychain -p "$PASS" "$KC"
security set-keychain-settings "$KC"
security unlock-keychain -p "$PASS" "$KC"
security import peel.p12 -k "$KC" -P "$PASS" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASS" "$KC" >/dev/null
rm -f key.pem peel.p12 cert.cnf

# create-keychain 可能把新钥匙串加进搜索列表：恢复原来的列表
AFTER=$(security list-keychains -d user)
if [ "$BEFORE" != "$AFTER" ]; then
    eval security list-keychains -d user -s $BEFORE
fi
echo "✓ 已生成签名证书：$NAME"
