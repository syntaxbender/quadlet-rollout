# nginx-rollout

Bu bileşen, root seviyesinde Nginx + Certbot rollout agent'ını kurar/günceller.

## Ne kurar

- `/usr/local/bin/nginx-rollout.sh`
- `/etc/systemd/system/nginx-rollout.service`
- `/etc/systemd/system/nginx-rollout.timer`
- `<project_dir>/nginx-rollout.env` (default: `/opt/quadlet-rollout/nginx-rollout.env`)
- `<project_dir>/status/nginx/seen_version`
- `/etc/letsencrypt/renewal-hooks/deploy/10-nginx-reload.sh`

## Çalıştırma

```bash
sudo ./nginx-rollout/install.sh
```

Script interaktif olarak `PROJECT_DIR` ve `NGINX_ROLLOUT_REPO_URL` sorar.  
Diğer path/env değerleri varsayılan/hardcoded akışla türetilir ve `nginx-rollout.timer` varsayılan olarak aktif edilir.

Installer her çalışmada permission self-heal yapar:
- `<project_dir>` ve `<project_dir>/global_version` izinlerini normalize eder (`quadlet-rollout:quadlet-rollout`, `0755/0644`)
- ortak repo lock dosyasını (`.quadlet-nginx-shared-repo.lock`) ve repo dizinini grup yazılabilir hale getirir

Rollout akışı certbot için mevcut enabled site'ları geçici olarak devreden çıkarır ve sadece ACME HTTP config'i aktive eder. Böylece eski bir server block veya repo `nginx/http/` redirect kuralı `/.well-known/acme-challenge/` isteklerini yakalayamaz. Cert aşaması bitince ACME config kapatılır, önceki enabled site'lar geri yüklenir, ardından repo `nginx/http/` ve `nginx/https/` configleri aktive edilir.

Rollout başarısız olursa `<project_dir>/nginx_failed_version` içine o anki global version SHA yazılır. Timer tekrar çalışsa bile global version aynı kaldığı sürece certbot/nginx rollout yeniden denenmez; yeni webhook SHA gelince tekrar denenir. Başarılı rollout sonrası failed marker temizlenir, `<project_dir>/nginx_seen_version` ve `/check` için `<project_dir>/status/nginx/seen_version` güncellenir.

## Sık kullanılan env override'ları

```bash
sudo PROJECT_DIR='/opt/quadlet-rollout' NGINX_ROLLOUT_REPO_URL='https://github.com/syntaxbender/quadlet-services.git' ./nginx-rollout/install.sh
```

## Upgrade

Nginx rollout script'i, systemd unit'i veya env şablonu değiştiyse:

```bash
git pull
sudo ./nginx-rollout/install.sh
sudo systemctl start nginx-rollout.service
```
