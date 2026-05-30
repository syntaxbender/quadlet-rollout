# SSH'siz Quadlet Deploy MVP

Bu depo, Ubuntu 22.04/24.04 + Podman Quadlet için SSH'siz deploy mimarisi örneği içerir.

## Bileşenler

- `webhook-app/webhook.py`: Nginx reverse proxy arkasında çalışacak webhook uygulaması
- `agent/quadlet-agent.sh`: user-space agent script'i
- `agent/systemd-user/*.service|*.timer`: her kullanıcıya kurulacak user unit dosyaları
- `nginx-rollout/nginx-rollout.sh`: root seviyesinde nginx+certbot rollout agent
- `nginx-rollout/systemd/*.service|*.timer`: root rollout agent unit dosyaları
- `examples/server-quadlets/`: kullanıcı bazlı `.container` repo örneği
- `examples/nginx/http|https|cert-bundles`: repo tabanlı nginx config + grouped SAN cert örnekleri
- `examples/nginx/webhook-ingress.example.conf`: webhook domain için Nginx reverse proxy örneği
- `github-actions.deploy.example.yml`: Actions örnek akışı
- `install.sh`: Ubuntu 22.04/24.04 için interaktif kurulum script'i
- `templates/`: bileşen installer'ları tarafından render edilen webhook quadlet ve nginx config template'leri

## Webhook Özeti

- `/deploy` endpoint'i sadece `POST` kabul eder
- `sha` ve HMAC token sadece header'dan alınır:
  - `X-Deploy-Sha`
  - `X-Deploy-Token`
  - `X-Deploy-Time-UTC`
- Query/body üzerinden deploy verisi kabul edilmez
- `sha` sadece hex commit formatında kabul edilir (`40` veya `64` karakter)
- Token doğrulama, zaman penceresine ek olarak `sha`'ya bağlıdır (token başka bir `sha` ile kullanılamaz)
- `X-Deploy-Time-UTC` formatı zorunlu: `YYYY-MM-DDTHH:MM:SSZ`
- Token doğrulama: `X-Deploy-Time-UTC` ile webhook `now(UTC)` farkı varsayılan `+/-5 dakika`
- Token payload formatı: `TIME_UTC + "\\n" + lower(sha)`
- Başarılı istek: `VERSION_FILE` içine SHA atomic yazılır
- TLS termination Nginx üzerinde yapılır, webhook container local HTTP dinler
- Webhook, servis restart veya user-space işlem yapmaz

## Agent Özeti

- `/opt/quadlet-rollout/global_version` ile local `seen_version` karşılaştırılır
- Değişim varsa quadlet repo güncellenir
- Agent ve nginx-rollout aynı repo clone'unu kullanır: `<project_dir>/repos/quadlet-nginx-shared-repo` (default project_dir: `/opt/quadlet-rollout`)
- Kurulum sırasında agent kullanıcıları `quadlet-rollout` grubuna eklenir; ortak repo bu grupla yazılabilir yapılır
- Repoda `quadlet-containers/$USER/` varsa içeriği `$HOME/` altına whitelist ile overwrite kopyalanır
- Sadece `*.container`, `*.service`, `*.timer` dosyaları kopyalanır
- Kaynak ağaçta symlink varsa güvenlik nedeniyle deploy reddedilir
- `systemctl --user daemon-reload` sonrası restart hedefleri dinamik belirlenir:
  - `~/.config/containers/systemd/*.container -> <name>.service`
  - `~/.config/systemd/user/*.service|*.timer -> aynı unit adı`
- Rollout sırasında kopyalanan her `container/service` unit için yoksa otomatik boş env dosyası oluşturulur:
  - Unit dosyasının yanında: `<unit_adi>.env`
  - Örnek: `appsvc.container -> ~/.config/containers/systemd/appsvc.env`
  - Örnek: `myjob.service -> ~/.config/systemd/user/myjob.env`

## Nginx Rollout Özeti

- Root timer (`nginx-rollout.timer`) `/opt/quadlet-rollout/global_version` değişimini izler
- Değişim varsa rollout repo `git pull` ile güncellenir
- Git lock dosyası ile (`.quadlet-nginx-shared-repo.lock`) agent/nginx eşzamanlı pull çakışmaları engellenir
- Repo `nginx/http/` configleri önce aktive edilir (`nginx -t && reload`)
- `nginx/cert-bundles/*.env` dosyalarına göre `certbot certonly --webroot --keep-until-expiring --expand` çalışır
- Her bundle tek certificate lineage olarak yönetilir (`CERT_NAME`) ve çoklu domain (SAN) destekler
- Cert aşaması başarılıysa `nginx/https/` configleri aktive edilir
- Son durumda tekrar `nginx -t && systemctl reload nginx` yapılır
- `nginx_seen_version` state dosyası güncellenir
- Certbot renew hook (`/etc/letsencrypt/renewal-hooks/deploy/10-nginx-reload.sh`) otomatik reload sağlar

Örnek repo sözleşmesi:

```text
quadlet-nginx-shared-repo/
  quadlet-containers/
    appuser1/
      .config/containers/systemd/app.container
    appuser2/
      .config/containers/systemd/app.container
  nginx/
    http/
      webhook.example.com.conf
    https/
      webhook.example.com.conf
    cert-bundles/
      example-main.env
```

## Varsayılan Değerler

### Webhook varsayılanları

- `SALT_SECRET`: boş (zorunlu, set edilmezse webhook isteklerini reddeder)
- `VERSION_FILE`: `/opt/quadlet-rollout/global_version`
- `PORT`: `8080`
- `BIND`: `0.0.0.0`
- `TZ`: `UTC` (container ortam saat dilimi)
- `TOKEN_TOLERANCE_MINUTES`: `5` (now etrafında kabul edilen +/- dakika aralığı)
- `MAX_HEADER_VALUE_LEN`: `128`
- Container runtime user: `quadlet-rollout` (`APP_UID=21001`, `APP_GID=21001`)

Kaynak: [webhook.py](/home/syn/Desktop/webhook/webhook-app/webhook.py)

### Agent varsayılanları

- Config yolu: `${XDG_CONFIG_HOME:-$HOME/.config}/quadlet-agent/config`
- Env dosyası modeli: unit dosyasının yanında `${unit_adi}.env` (yoksa rollout sırasında boş oluşturulur)
  - Container için: `${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd/<unit_adi>.env`
  - User service için: `${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/<unit_adi>.env`
- State yolu: `${XDG_STATE_HOME:-$HOME/.local/state}/quadlet-agent/seen_version`
- Ortak repo URL: `https://github.com/syntaxbender/quadlet-services.git`
- Ortak repo path: `<project_dir>/repos/quadlet-nginx-shared-repo` (default: `/opt/quadlet-rollout/repos/quadlet-nginx-shared-repo`)
- Repo kullanıcı dizin kuralı: `$REPO_DIR/quadlet-containers/$USER/`
- Hedef kök: `$HOME/`

Kaynak: [quadlet-agent.sh](/home/syn/Desktop/webhook/agent/quadlet-agent.sh)

### Timer varsayılanları

- İlk çalıştırma: `OnBootSec=1min`
- Periyot: `OnUnitActiveSec=1min`
- Jitter: `RandomizedDelaySec=15s`
- Kaçan tur telafisi: `Persistent=true`

Kaynak: [quadlet-agent.timer](/home/syn/Desktop/webhook/agent/systemd-user/quadlet-agent.timer)

### Nginx rollout varsayılanları

- Config yolu: `/etc/quadlet-rollout/nginx-rollout.env`
- Script yolu: `/usr/local/bin/nginx-rollout.sh`
- Global version dosyası: `<project_dir>/global_version` (default: `/opt/quadlet-rollout/global_version`)
- Rollout repo yolu: `<project_dir>/repos/quadlet-nginx-shared-repo` (default: `/opt/quadlet-rollout/repos/quadlet-nginx-shared-repo`)
- Repo-relative dizinler:
  - `NGINX_HTTP_DIR=nginx/http`
  - `NGINX_HTTPS_DIR=nginx/https`
  - `CERT_BUNDLES_DIR=nginx/cert-bundles`
- ACME webroot: `/var/www/certbot`
- State dosyası: `<project_dir>/nginx_seen_version` (default: `/opt/quadlet-rollout/nginx_seen_version`)
- Certbot binary: `/usr/bin/certbot`
- Renew hook: `/etc/letsencrypt/renewal-hooks/deploy/10-nginx-reload.sh`

Kaynak: [nginx-rollout.env.example](/home/syn/Desktop/webhook/nginx-rollout/nginx-rollout.env.example)

## Değerler Nereden ve Nasıl Güncellenir

### Webhook environment değerlerini güncelleme

1. Hostta kullanılan env dosyasını güncelle (`.env.webhook.example` içeriğini referans al).
2. Quadlet `.container` içinde env tanımlarını güncelle:
   - `Environment=SALT_SECRET=...`
   - `Environment=VERSION_FILE=...`
   - `Environment=PORT=8080` (container iç portu)
   - `Environment=TZ=UTC`
   - `Environment=TOKEN_TOLERANCE_MINUTES=5`
   - `Environment=MAX_HEADER_VALUE_LEN=...` (opsiyonel)
3. Değişiklikten sonra ilgili systemd unit'i reload/restart et.

Örnek env: [.env.webhook.example](/home/syn/Desktop/webhook/.env.webhook.example)  
Örnek unit: [webhook.container.example](/home/syn/Desktop/webhook/webhook-app/webhook.container.example)

### Agent config değerlerini güncelleme

1. Kullanıcı bazında `~/.config/quadlet-agent/config` dosyasını düzenle.
2. En az şu değişkenler set olmalı:
   - `GLOBAL_VERSION_FILE`
   - `REPO_URL`
   - `REPO_DIR`
   - Önerilen `REPO_URL`: `https://github.com/syntaxbender/quadlet-services.git`
   - Önerilen `REPO_DIR`: `<project_dir>/repos/quadlet-nginx-shared-repo` (default: `/opt/quadlet-rollout/repos/quadlet-nginx-shared-repo`)
3. Timer bir sonraki turda yeni değerlerle çalışır. Hemen denemek için:

```bash
systemctl --user start quadlet-agent.service
```

Örnek config: [config.example](/home/syn/Desktop/webhook/agent/config.example)

### Nginx rollout config değerlerini güncelleme

1. Root config dosyasını düzenle: `/etc/quadlet-rollout/nginx-rollout.env`
2. En az şu değişkenler set olmalı:
   - `REPO_URL`
   - `REPO_DIR`
   - `NGINX_HTTP_DIR`
   - `NGINX_HTTPS_DIR`
   - `CERT_BUNDLES_DIR`
   - `ACME_CHALLENGE_ROOT`
   - Agent ile aynı repo kullanılabilir (önerilen):
     - `REPO_URL=https://github.com/syntaxbender/quadlet-services.git`
     - `REPO_DIR=<project_dir>/repos/quadlet-nginx-shared-repo` (default: `/opt/quadlet-rollout/repos/quadlet-nginx-shared-repo`)
3. Repo içinde cert bundle dosyalarıyla grouped SAN tanımla:
   - [example-main.env](/home/syn/Desktop/webhook/examples/nginx/cert-bundles/example-main.env)
4. Değişiklikten sonra test için:

```bash
sudo systemctl start nginx-rollout.service
sudo systemctl status nginx-rollout.service
```

### Saat senkronizasyonu ve tolerans (GitHub Actions + Webhook)

1. Her iki tarafı da UTC'de çalıştır:
   - Workflow: `env: TZ: UTC` (örnek workflow içinde eklendi)
   - Webhook container: `Environment=TZ=UTC`
2. Workflow her deploy isteğinde UTC timestamp header üretir:
   - `X-Deploy-Time-UTC: YYYY-MM-DDTHH:MM:SSZ`
   - Örnek workflow `date -u` ile üretir.
3. Webhook, bu timestamp'in `now(UTC)` farkını kontrol eder.
4. Replay tolerans aralığını (default `+/-5 dk`) webhook tarafında ayarla:
   - `TOKEN_TOLERANCE_MINUTES=5`
5. Sunucu `UTC+3` olsa bile sorun olmaz; doğrulama UTC timestamp üzerinden yapılır.
6. İlk denemede 401 alırsan önce saat senkronunu kontrol et:

```bash
timedatectl status
```

### Timer periyodunu güncelleme

1. `~/.config/systemd/user/quadlet-agent.timer` dosyasını düzenle.
2. Sonrasında:

```bash
systemctl --user daemon-reload
systemctl --user restart quadlet-agent.timer
systemctl --user status quadlet-agent.timer
```

## Kurulum (özet)

1. Root tarafta ortak version dosyası oluştur:

```bash
# Hostta servis kullanıcısı/grubu oluştur (container içindeki UID:GID ile aynı)
getent group quadlet-rollout >/dev/null || \
  sudo groupadd --system --gid 21001 quadlet-rollout
id -u quadlet-rollout >/dev/null 2>&1 || \
  sudo useradd --system --uid 21001 --gid quadlet-rollout --home-dir /nonexistent --shell /usr/sbin/nologin quadlet-rollout

sudo mkdir -p /opt/quadlet-rollout
sudo touch /opt/quadlet-rollout/global_version
# Webhook container varsayılan olarak UID:GID 21001:21001 ile çalışır.
# (bkz: webhook-app/Containerfile -> APP_UID/APP_GID)
sudo chown quadlet-rollout:quadlet-rollout /opt/quadlet-rollout
sudo chown quadlet-rollout:quadlet-rollout /opt/quadlet-rollout/global_version
sudo chmod 0755 /opt/quadlet-rollout
sudo chmod 0644 /opt/quadlet-rollout/global_version
```

Not: Container build sırasında `APP_UID`/`APP_GID` değiştirirsen, hosttaki kullanıcı UID:GID ve `chown` değerlerini de aynı şekilde güncellemelisin.

2. Her deploy kullanıcısı için linger aç:

```bash
sudo loginctl enable-linger appuser1
sudo loginctl enable-linger appuser2
```

3. Her kullanıcı için agent kur:

```bash
install -Dm0755 agent/quadlet-agent.sh ~/.local/bin/quadlet-agent.sh
install -Dm0644 agent/config.example ~/.config/quadlet-agent/config
install -Dm0644 agent/systemd-user/quadlet-agent.service ~/.config/systemd/user/quadlet-agent.service
install -Dm0644 agent/systemd-user/quadlet-agent.timer ~/.config/systemd/user/quadlet-agent.timer
systemctl --user daemon-reload
systemctl --user enable --now quadlet-agent.timer
```

4. Webhook app'i container olarak çalıştırırken host path mount + local publish kullan:

`Volume=/opt/quadlet-rollout:/data:Z`  
`PublishPort=127.0.0.1:18080:8080`

5. Nginx reverse proxy'yi webhook domain için etkinleştir:

```bash
# Örnek dosyayı kopyala ve domain/cert path değerlerini güncelle
sudo cp examples/nginx/webhook-ingress.example.conf /etc/nginx/sites-available/webhook.example.com

# site'ı etkinleştir
sudo ln -s /etc/nginx/sites-available/webhook.example.com /etc/nginx/sites-enabled/webhook.example.com

# config doğrula ve reload et
sudo nginx -t
sudo systemctl reload nginx
```

Nginx örnek dosyası: [webhook-ingress.example.conf](/home/syn/Desktop/webhook/examples/nginx/webhook-ingress.example.conf)

6. Pipeline secret'ında webhook URL'i domain üzerinden ver:

```text
DEPLOY_URL=https://webhook.example.com
```

7. Nginx+Certbot rollout agent kullanacaksan repo sözleşmesini uygula:

- HTTP config örneği: [webhook.example.com.conf](/home/syn/Desktop/webhook/examples/nginx/http/webhook.example.com.conf)
- HTTPS config örneği: [webhook.example.com.conf](/home/syn/Desktop/webhook/examples/nginx/https/webhook.example.com.conf)
- Cert bundle örneği: [example-main.env](/home/syn/Desktop/webhook/examples/nginx/cert-bundles/example-main.env)

## Minimum yetki modeli

- Webhook sadece `global_version` yazabilir
- Agent root değildir, sadece kendi user-space'inde çalışır
- `systemctl --user` sadece ilgili kullanıcı context'inde çağrılır
- Nginx/Certbot rollout ayrı root agent ile çalışır; user agent root işlemi yapmaz

## Interaktif Kurulum Scripti

`install.sh` kök orchestrator scriptidir. Kurulum işini doğrudan yapmaz; aşağıdaki installer'ları sırayla tetikler:

- [webhook-app/install.sh](/home/syn/Desktop/webhook/webhook-app/install.sh)
- [agent/install.sh](/home/syn/Desktop/webhook/agent/install.sh) (her kullanıcı için)
- [nginx-rollout/install.sh](/home/syn/Desktop/webhook/nginx-rollout/install.sh)

Çalıştırma:

```bash
chmod +x ./install.sh
sudo ./install.sh
```

Kök scriptte istenecek temel inputlar:

- Quadlet rollout project dizini (`/opt/quadlet-rollout`)
- Agent/Nginx ortak repo URL (`https://github.com/syntaxbender/quadlet-services.git`)
- Agent kurulacak Linux kullanıcıları (boşlukla ayrılmış liste)

Sonrasında her alt installer kendi bileşenine ait soruları interaktif olarak sorar.
Not: Kök script paket kurmaz; gerekli paketlerin sistemde hazır olduğu varsayılır.

Not (Ubuntu 22.04): Varsayılan repo Podman sürümü eski olabilir. Script Quadlet için `Podman >= 4.6` bekler.

## Bileşen Bazlı Kurulum/Upgrade

Toplu kurulum yerine sadece değişen bileşeni upgrade etmek için her dizinde ayrı installer bulunur:

- Webhook bileşeni: [webhook-app/install.sh](/home/syn/Desktop/webhook/webhook-app/install.sh)
- Agent bileşeni: [agent/install.sh](/home/syn/Desktop/webhook/agent/install.sh)
- Nginx rollout bileşeni: [nginx-rollout/install.sh](/home/syn/Desktop/webhook/nginx-rollout/install.sh)

Detaylı kullanım dokümanları:

- [webhook-app/README.md](/home/syn/Desktop/webhook/webhook-app/README.md)
- [agent/README.md](/home/syn/Desktop/webhook/agent/README.md)
- [nginx-rollout/README.md](/home/syn/Desktop/webhook/nginx-rollout/README.md)

Örnek upgrade akışı:

```bash
git pull
sudo ./webhook-app/install.sh
sudo TARGET_USER="appuser1" ./agent/install.sh
sudo ./nginx-rollout/install.sh
```

zaafiyetlerin ammınake
-ai(chatgpt)
