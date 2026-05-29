# webhook-app

Bu bileşen, deploy webhook container'ını ve (istersen) webhook domain için Nginx site config'ini kurar/günceller.

## Ne kurar

- `/etc/containers/systemd/quadlet-webhook.container`
- `quadlet-webhook.service` (start/restart)
- `/opt/quadlet-rollout/global_version` (owner: `quadlet-rollout`)
- Opsiyonel Nginx site config (`/etc/nginx/sites-available/<domain>`)

## Çalıştırma

```bash
sudo ./webhook-app/install.sh
```

## Sık kullanılan env override'ları

```bash
sudo SALT_SECRET='...' WEBHOOK_IMAGE='ghcr.io/org/webhook:latest' BUILD_IMAGE='n' ./webhook-app/install.sh
```

```bash
sudo WEBHOOK_DOMAIN='webhook.example.com' CONFIGURE_NGINX='y' NGINX_ENABLE_SSL='y' NGINX_ACTIVATE_CONFIG='n' ./webhook-app/install.sh
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
