# webhook-app

Bu bileşen, deploy webhook container'ını ve (istersen) webhook domain için Nginx site config'ini kurar/günceller.

## Ne kurar

- `/etc/containers/systemd/quadlet-webhook.container`
- `quadlet-webhook.service` (start/restart)
- `/opt/quadlet-rollout/global_version` (owner: `quadlet-rollout`)
- Opsiyonel Nginx site config (`/etc/nginx/sites-available/<domain>`)
- Koşullu Certbot SSL üretimi (aşağıdaki koşullar sağlanırsa)

## Çalıştırma

```bash
sudo ./webhook-app/install.sh
```

Script interaktif olarak en az şu alanları sorar:

- `PROJECT_DIR`
- `WEBHOOK_DOMAIN`
- `TOKEN_TOLERANCE_MINUTES`
- `CONFIGURE_NGINX` (+ seçime göre `NGINX_ACTIVATE_CONFIG`, `NGINX_ENABLE_SSL`)

`SALT_SECRET` sorulmaz:
- Unit dosyasında mevcut bir secret varsa korunur.
- İlk kurulumda yoksa `openssl` ile otomatik üretilir ve çıktı olarak basılır.
- İstersen `SALT_SECRET=...` override ederek manuel sabitleyebilirsin.

Installer her çalışmada `<project_dir>` ve `<project_dir>/global_version` izinlerini tekrar normalize eder (`quadlet-rollout:quadlet-rollout`, `0755/0644`).

## Sık kullanılan env override'ları

```bash
sudo PROJECT_DIR='/opt/quadlet-rollout' TOKEN_TOLERANCE_MINUTES='5' ./webhook-app/install.sh
```

```bash
sudo WEBHOOK_DOMAIN='webhook.example.com' CONFIGURE_NGINX='y' NGINX_ENABLE_SSL='y' NGINX_ACTIVATE_CONFIG='n' ./webhook-app/install.sh
```

## Otomatik SSL Koşulları

Script aşağıdakiler **aynı anda** `y` ise certbot ile sertifika üretir/yeniler:

- `CONFIGURE_NGINX`
- `NGINX_ENABLE_SSL`
- `NGINX_ACTIVATE_CONFIG`

Akış:

1. Önce HTTP config aktive edilir (ACME challenge erişimi için).
2. `certbot certonly --webroot --keep-until-expiring --expand` çalışır.
3. Sertifika geldikten sonra HTTPS config aktive edilir.

İlgili env'ler:

- `CERTBOT_EMAIL` (opsiyonel; boşsa `--register-unsafely-without-email` kullanılır)
- `CERTBOT_BIN` (default: `/usr/bin/certbot`)
- `CERTBOT_CERT_NAME` (opsiyonel; boşsa certbot default cert adı kullanılır)
- `ACME_CHALLENGE_ROOT` (default: `/var/www/certbot`)

Örnek:

```bash
sudo WEBHOOK_DOMAIN='webhook.example.com' \
  CONFIGURE_NGINX='y' \
  NGINX_ENABLE_SSL='y' \
  NGINX_ACTIVATE_CONFIG='y' \
  ./webhook-app/install.sh
```

## Upgrade

Webhook kodu, `Containerfile` veya webhook quadlet template değiştiyse:

```bash
git pull
sudo ./webhook-app/install.sh
```

## Hata Notu

`Failed to enable unit: Unit file quadlet-webhook.service does not exist.` görürsen:

- Quadlet generator `.container` dosyasını parse edememiş olabilir.
- Script artık bu durumda dry-run + journal teşhis çıktısı basar.
- Sonrasında tekrar çalıştır:

```bash
sudo ./webhook-app/install.sh
```

`Failed to enable unit: Unit /run/systemd/generator/quadlet-webhook.service is transient or generated.` görürsen:

- Bu, Quadlet için beklenen davranıştır; generated `.service` enable edilmez.
- Installer artık `enable` çağırmadan `start/restart` uygular.

`Failed to set up mount namespacing: /run/systemd/unit-root/data: No such file or directory` görürsen:

- Bu hata, service-level `ReadWritePaths=/data` gibi host path ile container path'in karışmasından kaynaklanır.
- Güncel template bu ayarı içermez; installer'ı tekrar çalıştırarak unit'i yeniden üret.
