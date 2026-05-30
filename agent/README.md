# agent

Bu bileşen, bir veya birden fazla Linux kullanıcısı için `quadlet-agent` script + user systemd unit kurar/günceller.

## Ne kurar

- `%h/.local/bin/quadlet-agent.sh`
- `%h/.config/systemd/user/quadlet-agent.service`
- `%h/.config/systemd/user/quadlet-agent.timer`
- `%h/.config/quadlet-agent/config`
- `%h/.config/containers/systemd/<unit_adi>.env` veya `%h/.config/systemd/user/<unit_adi>.env` (rollout sırasında yoksa boş oluşturur)

## Çalışma davranışı

- `SERVICES` değişkeni kullanılmaz.
- Agent restart hedeflerini kopyaladığı dosyalardan dinamik çıkarır:
  - `~/.config/containers/systemd/*.container -> <name>.service`
  - `~/.config/systemd/user/*.service|*.timer -> aynı unit adı`
- Kopyalanan `container/service` için ilgili env dosyasını otomatik hazırlar:
  - Unit dosyasının yanında: `<unit_adi>.env`
  - Örnek: `appsvc.container -> ~/.config/containers/systemd/appsvc.env`
  - Örnek: `myjob.service -> ~/.config/systemd/user/myjob.env`

## Çalıştırma

```bash
sudo TARGET_USER='appuser1' ./agent/install.sh
sudo TARGET_USERS_RAW='appuser1,appuser2' ./agent/install.sh
```

Script interaktif olarak `PROJECT_DIR` ve `AGENT_REPO_URL` sorar.  
Kullanıcı listesi `TARGET_USERS_RAW` (virgül/boşluk ayracı) veya `TARGET_USER` ile verilebilir.  
Hiçbiri verilmezse kullanıcı listesi interaktif sorulur.

## Sık kullanılan env override'ları

```bash
sudo TARGET_USER='appuser1' AGENT_REPO_URL='https://github.com/syntaxbender/quadlet-services.git' PROJECT_DIR='/opt/quadlet-rollout' ./agent/install.sh
```

## Çoklu kullanıcı upgrade

```bash
for u in appuser1 appuser2; do
  sudo TARGET_USER="$u" ./agent/install.sh
done

# veya tek komutla
sudo TARGET_USERS_RAW='appuser1,appuser2' ./agent/install.sh
```
