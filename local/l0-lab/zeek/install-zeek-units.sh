set -e
sudo tee /etc/systemd/system/zeek-capture.service > /dev/null <<'U'
[Unit]
Description=Zeek on the Hyper-V mirror interface (L0 lab)
Documentation=docs/LOCAL-DEPLOYMENT.md §8-51
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
# eth1 은 Hyper-V 포트 미러링의 목적지다. IP 를 주지 않고 promisc 로만 쓴다.
# 재부팅하면 DOWN 으로 돌아오므로 여기서 올린다.
ExecStartPre=/sbin/ip link set eth1 up
ExecStartPre=/sbin/ip link set eth1 promisc on
WorkingDirectory=/var/log/zeek
ExecStart=/opt/zeek/bin/zeek -i eth1 -C LogAscii::use_json=T
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
U
sudo tee /etc/systemd/system/zeek-ship.service > /dev/null <<'U'
[Unit]
Description=Ship Zeek JSON logs to Logstash 5141 (L0 lab)
Documentation=docs/LOCAL-DEPLOYMENT.md §8-51
After=zeek-capture.service
Wants=zeek-capture.service

[Service]
Type=simple
ExecStart=/usr/local/bin/zeek-ship.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
U
sudo pkill -f "zeek -i eth1" 2>/dev/null || true
sudo pkill -f zeek-ship 2>/dev/null || true
sleep 2
sudo mkdir -p /var/log/zeek
sudo systemctl daemon-reload
sudo systemctl enable --now zeek-capture zeek-ship
sleep 12
systemctl is-active zeek-capture zeek-ship
