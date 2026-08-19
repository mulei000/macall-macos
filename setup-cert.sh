#!/bin/bash
# One-time setup: create a STABLE, TRUSTED self-signed code-signing certificate.
#
# Why this matters: macOS TCC (辅助功能 / 屏幕录制 / 输入监控) grants are keyed
# off the code-signing *identity*. With ad-hoc signing the identity changes on
# every build, so the grants silently die and you must re-authorize each time.
# A fixed cert identity keeps the grants alive — BUT only if the cert is placed
# in the user trust store, otherwise TCC falls back to pinning the cdhash and
# still re-prompts on every rebuild.
#
# We add the trust to the user-scoped login keychain (no admin / sudo required),
# which makes `security find-identity -v` report the identity as VALID and lets
# TCC anchor to it.
#
# 照搬自 Macindow 的 setup-cert.sh，仅把证书名 / 钥匙串名改为 macall，并把信任
# 落到用户级 login.keychain（避免需要管理员授权的系统级信任）。
set -e

CERT_NAME="macall Code Signing"
KC_NAME="macall-signing.keychain"
KC_PW="macall"
LOGIN_KC="$HOME/Library/Keychains/login.keychain"

# 1) 证书是否已存在（任意状态）？
if security find-identity -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
  echo "证书 '$CERT_NAME' 已存在，跳过创建。"
else
  echo "==> 生成自签名代码签名证书: $CERT_NAME"
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout /tmp/macall_key.pem -out /tmp/macall_cert.pem -days 3650 \
    -subj "/CN=$CERT_NAME" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "keyUsage=critical,digitalSignature"

  openssl pkcs12 -export -out /tmp/macall.p12 \
    -inkey /tmp/macall_key.pem -in /tmp/macall_cert.pem -passout pass:"$PW"

  echo "==> 创建专用钥匙串并导入证书..."
  security create-keychain -p "$PW" "$KC_NAME" 2>/dev/null || true
  security list-keychains -s "$KC_NAME" login.keychain 2>/dev/null || true
  security import /tmp/macall.p12 -k "$KC_NAME" -P "$PW" \
    -T /usr/bin/codesign -T /usr/bin/security 2>/dev/null || true
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PW" "$KC_NAME" 2>/dev/null || true
fi

# 2) 关键：把证书加入「用户级」信任存储（codeSign 策略）。
#    这一步不需要 sudo。完成后 find-identity -v 会显示该身份为 VALID，
#    TCC 才能锚定到证书身份而非 cdhash，从而实现「重装/更新后免重新授权」。
echo "==> 将证书加入用户级信任 (codeSign)..."

# 确保信任步骤所需的 PEM 存在：若之前创建时已清理临时文件，则从钥匙串导出。
if [ ! -f /tmp/macall_cert.pem ]; then
  security find-certificate -c "$CERT_NAME" -p "$HOME/Library/Keychains/$KC_NAME-db" \
    > /tmp/macall_cert.pem 2>/dev/null || \
  security find-certificate -c "$CERT_NAME" -p > /tmp/macall_cert.pem 2>/dev/null || true
fi

if security add-trusted-cert -p codeSign -k "$LOGIN_KC" /tmp/macall_cert.pem 2>/dev/null; then
  echo "    信任写入成功（login.keychain）。"
else
  # 某些 macOS 版本对 login.keychain 信任也会要求解锁，重试一次。
  security unlock-keychain -p "$KC_PW" "$KC_NAME" 2>/dev/null || true
  if security add-trusted-cert -p codeSign -k "$LOGIN_KC" /tmp/macall_cert.pem 2>/dev/null; then
    echo "    信任写入成功（login.keychain，重试）。"
  else
    echo "  ⚠️ 用户级信任写入失败。可手动授权："
    echo "     sudo security add-trusted-cert -p codeSign -k /Library/Keychains/System.keychain /tmp/macall_cert.pem"
    echo "  （不信任也能签名，但 TCC 授权仍可能在每次重建后失效）"
  fi
fi

# 3) 确保钥匙串在搜索列表且解锁，方便 codesign 找到身份。
security list-keychains -s "$KC_NAME" login.keychain 2>/dev/null || true
security unlock-keychain -p "$PW" "$HOME/Library/Keychains/$KC_NAME-db" 2>/dev/null || true

echo "==> 验证证书（应为 VALID）："
security find-identity -v -p codesigning 2>/dev/null | grep "$CERT_NAME" || echo "  ⚠️ 仍显示无效，请参考上面的 sudo 命令手动信任。"
