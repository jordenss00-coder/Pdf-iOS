#!/usr/bin/env bash
# TestFlight iş akışının GitHub secret'larını kendi bilgisayarında ayarlar.
# Sertifika anahtarı yoksa üretir (~/.pdfatolye/cert_key.pem). Değerler ekrana yazılmaz.
# Gerekenler: gh (giriş yapılmış), ssh-keygen (Git Bash ile gelir).
set -euo pipefail
REPO=jordenss00-coder/Pdf-iOS

read -rp "Issuer ID: " issuer
read -rp "Key ID: " key_id
read -rp ".p8 dosyasının yolu (sürükleyip bırakabilirsin): " p8
p8="${p8%\"}"; p8="${p8#\"}"; p8="${p8%\'}"; p8="${p8#\'}"
[ -f "$p8" ] || { echo "Dosya bulunamadı: $p8" >&2; exit 1; }

key_file="$HOME/.pdfatolye/cert_key.pem"
if [ ! -f "$key_file" ]; then
  mkdir -p "$(dirname "$key_file")"
  ssh-keygen -t rsa -b 2048 -m PEM -N "" -q -f "$key_file"
  rm -f "$key_file.pub"
  echo "Sertifika anahtarı üretildi: $key_file"
fi

gh secret set APP_STORE_CONNECT_ISSUER_ID --repo "$REPO" --body "$issuer"
gh secret set APP_STORE_CONNECT_KEY_IDENTIFIER --repo "$REPO" --body "$key_id"
gh secret set APP_STORE_CONNECT_PRIVATE_KEY --repo "$REPO" < "$p8"
gh secret set CERTIFICATE_PRIVATE_KEY --repo "$REPO" < "$key_file"
echo "Tamam. $key_file dosyasını yedekle ve kimseyle paylaşma; dağıtım sertifikan buna bağlı."
