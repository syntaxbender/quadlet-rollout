# SSH'siz Quadlet Deploy MVP

Bu depo, Ubuntu 24.04 + Podman Quadlet için SSH'siz deploy mimarisi örneği içerir.

## Bileşenler

- `webhook-app/webhook.py`: HTTPS arkasında çalışacak webhook uygulaması
- `agent/quadlet-agent.sh`: user-space agent script'i
- `agent/systemd-user/*.service|*.timer`: her kullanıcıya kurulacak user unit dosyaları
- `examples/server-quadlets/`: kullanıcı bazlı `.container` repo örneği
- `github-actions.deploy.example.yml`: Actions örnek akışı

## Webhook Özeti

- `/deploy` endpoint'i sadece `POST` kabul eder
- `sha` ve HMAC token sadece header'dan alınır:
  - `X-Deploy-Sha`
  - `X-Deploy-Token`
- Query/body üzerinden `sha` veya `token` kabul edilmez
- `sha` sadece hex commit formatında kabul edilir (`40` veya `64` karakter)
- Token doğrulama, zaman penceresine ek olarak `sha`'ya bağlıdır (token başka bir `sha` ile kullanılamaz)
- Token doğrulama: mevcut 10 dakika penceresi + önceki pencere
- Token payload formatı: `TIME_WINDOW + "\\n" + lower(sha)`
- Başarılı istek: `VERSION_FILE` içine SHA atomic yazılır
- Webhook, servis restart veya user-space işlem yapmaz

## Agent Özeti

- `/opt/quadlet-rollout/global_version` ile local `seen_version` karşılaştırılır
- Değişim varsa quadlet repo güncellenir
- Repoda `quadlet-containers/$USER/` varsa içeriği `$HOME/` altına whitelist ile overwrite kopyalanır
- Sadece `*.container`, `*.service`, `*.timer` dosyaları kopyalanır
- Kaynak ağaçta symlink varsa güvenlik nedeniyle deploy reddedilir
- `systemctl --user daemon-reload` ve tanımlı servis restart edilir

## Varsayılan Değerler

### Webhook varsayılanları

- `SALT_SECRET`: boş (zorunlu, set edilmezse webhook isteklerini reddeder)
- `VERSION_FILE`: `/opt/quadlet-rollout/global_version`
- `PORT`: `8080`
- `BIND`: `0.0.0.0`
- `TZ`: `UTC` (container ortam saat dilimi)
- `CLOCK_SKEW_MINUTES`: `0` (UTC bazında dakika düzeltmesi)
- `TZ_OFFSET_MINUTES`: `0` (geri uyum için desteklenir, yeni kurulumda önerilmez)
- `MAX_HEADER_VALUE_LEN`: `128`

Kaynak: [webhook.py](/home/syn/Desktop/webhook/webhook-app/webhook.py)

### Agent varsayılanları

- Config yolu: `${XDG_CONFIG_HOME:-$HOME/.config}/quadlet-agent/config`
- State yolu: `${XDG_STATE_HOME:-$HOME/.local/state}/quadlet-agent/seen_version`
- Repo kullanıcı dizin kuralı: `$REPO_DIR/quadlet-containers/$USER/`
- Hedef kök: `$HOME/`

Kaynak: [quadlet-agent.sh](/home/syn/Desktop/webhook/agent/quadlet-agent.sh)

### Timer varsayılanları

- İlk çalıştırma: `OnBootSec=1min`
- Periyot: `OnUnitActiveSec=1min`
- Jitter: `RandomizedDelaySec=15s`
- Kaçan tur telafisi: `Persistent=true`

Kaynak: [quadlet-agent.timer](/home/syn/Desktop/webhook/agent/systemd-user/quadlet-agent.timer)

## Değerler Nereden ve Nasıl Güncellenir

### Webhook environment değerlerini güncelleme

1. Hostta kullanılan env dosyasını güncelle (`.env.webhook.example` içeriğini referans al).
2. Quadlet `.container` içinde env tanımlarını güncelle:
   - `Environment=SALT_SECRET=...`
   - `Environment=VERSION_FILE=...`
   - `Environment=PORT=...`
   - `Environment=TZ=UTC`
   - `Environment=CLOCK_SKEW_MINUTES=0`
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
   - `SERVICES`
3. Timer bir sonraki turda yeni değerlerle çalışır. Hemen denemek için:

```bash
systemctl --user start quadlet-agent.service
```

Örnek config: [config.example](/home/syn/Desktop/webhook/agent/config.example)

### TZ senkronizasyonu (GitHub Actions + Webhook)

1. Her iki tarafı da UTC'de çalıştır:
   - Workflow: `env: TZ: UTC` (örnek workflow içinde eklendi)
   - Webhook container: `Environment=TZ=UTC`
2. Workflow token hesabında UTC kullan:
   - Örnek workflow zaten `date -u` ile hesap yapar.
3. Saat farkı varsa sadece webhook tarafında küçük düzeltme ver:
   - `CLOCK_SKEW_MINUTES=1` veya `-1` gibi.
4. İlk denemede 401 alırsan önce saat senkronunu kontrol et:

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
sudo mkdir -p /opt/quadlet-rollout
sudo touch /opt/quadlet-rollout/global_version
sudo chown webhook:quadlet-rollout /opt/quadlet-rollout/global_version
sudo chmod 0644 /opt/quadlet-rollout/global_version
```

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

4. Webhook app'i container olarak çalıştırırken host path mount et:

`Volume=/opt/quadlet-rollout:/data:Z`

## Minimum yetki modeli

- Webhook sadece `global_version` yazabilir
- Agent root değildir, sadece kendi user-space'inde çalışır
- `systemctl --user` sadece ilgili kullanıcı context'inde çağrılır
