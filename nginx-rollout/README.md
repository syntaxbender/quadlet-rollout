# nginx-rollout

Bu bileşen, root seviyesinde Nginx + Certbot rollout agent'ını kurar/günceller.

## Ne kurar

- `/usr/local/bin/nginx-rollout.sh`
- `/etc/systemd/system/nginx-rollout.service`
- `/etc/systemd/system/nginx-rollout.timer`
- `/etc/quadlet-rollout/nginx-rollout.env`
- `/etc/letsencrypt/renewal-hooks/deploy/10-nginx-reload.sh`

## Çalıştırma

```bash
sudo ./nginx-rollout/install.sh
```

Script interaktif olarak `PROJECT_DIR` ve `NGINX_ROLLOUT_REPO_URL` sorar.  
Diğer path/env değerleri varsayılan/hardcoded akışla türetilir ve `nginx-rollout.timer` varsayılan olarak aktif edilir.

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
