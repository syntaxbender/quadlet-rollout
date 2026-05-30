# agent

Bu bileşen, tek bir Linux kullanıcısı için `quadlet-agent` script + user systemd unit kurar/günceller.

## Ne kurar

- `%h/.local/bin/quadlet-agent.sh`
- `%h/.config/systemd/user/quadlet-agent.service`
- `%h/.config/systemd/user/quadlet-agent.timer`
- `%h/.config/quadlet-agent/config`
- `%h/.config/quadlet-agent/app.env` (yoksa boş oluşturur)

## Çalışma davranışı

- `SERVICES` değişkeni kullanılmaz.
- Agent restart hedeflerini kopyaladığı dosyalardan dinamik çıkarır:
  - `~/.config/containers/systemd/*.container -> <name>.service`
  - `~/.config/systemd/user/*.service|*.timer -> aynı unit adı`

## Çalıştırma

```bash
sudo TARGET_USER='appuser1' ./agent/install.sh
```

Script interaktif olarak `PROJECT_DIR` ve `AGENT_REPO_URL` sorar.  
`TARGET_USER` verilmezse kullanıcıyı ayrıca sorar.

## Sık kullanılan env override'ları

```bash
sudo TARGET_USER='appuser1' AGENT_REPO_URL='https://github.com/syntaxbender/quadlet-services.git' PROJECT_DIR='/opt/quadlet-rollout' ./agent/install.sh
```

## Çoklu kullanıcı upgrade

```bash
for u in appuser1 appuser2; do
  sudo TARGET_USER="$u" ./agent/install.sh
done
```
