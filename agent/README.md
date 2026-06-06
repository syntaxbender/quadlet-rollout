# agent

Bu bileşen, bir veya birden fazla Linux kullanıcısı için `quadlet-agent` script + user systemd unit kurar/günceller.

## Ne kurar

- `%h/.local/bin/quadlet-agent.sh`
- `%h/.config/systemd/user/quadlet-agent.service`
- `%h/.config/systemd/user/quadlet-agent.timer`
- `%h/.config/quadlet-agent/config`
- `<project_dir>/status/agents/<user>/seen_version`
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
- Başarılı rollout sonrası local state (`~/.local/state/quadlet-agent/seen_version`) ve webhook `/check` için ortak state (`<project_dir>/status/agents/<user>/seen_version`) güncellenir.

## Çalıştırma

```bash
sudo TARGET_USER='appuser1' ./agent/install.sh
sudo TARGET_USERS_RAW='appuser1,appuser2' ./agent/install.sh
```

Script interaktif olarak `PROJECT_DIR` ve `AGENT_REPO_URL` sorar.  
Kullanıcı listesi `TARGET_USERS_RAW` (virgül/boşluk ayracı) veya `TARGET_USER` ile verilebilir.  
Hiçbiri verilmezse kullanıcı listesi interaktif sorulur.

Installer her çalışmada permission self-heal yapar:
- `<project_dir>/global_version` okunabilir moda döner (`0644`)
- ortak repo lock dosyası (`.quadlet-nginx-shared-repo.lock`) ve repo dizini grup yazılabilir hale getirilir
- kullanıcı home altındaki `.config/.local` ownership'i kullanıcıya geri alınır

Kurulumla birlikte `/usr/local/bin/quadlet-agentctl` yardımcı aracı da kurulur:

```bash
sudo quadlet-agentctl status appuser1 appuser2
sudo quadlet-agentctl run appuser1
sudo quadlet-agentctl logs appuser1
```

Bu araç `XDG_RUNTIME_DIR`/DBUS ayarını kendi yapar; `systemctl --user` için elle env vermen gerekmez.

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
