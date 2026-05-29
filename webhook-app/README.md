# webhook-app

Bu bileşen, deploy webhook container'ını ve (istersen) webhook domain için Nginx site config'ini kurar/günceller.

## Ne kurar

- `/etc/containers/systemd/quadlet-webhook.container`
- `quadlet-webhook.service` (enable + start)
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
