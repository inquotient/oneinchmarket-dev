#!/usr/bin/env python3
"""Zeek JSON 로그를 Logstash(5141)로 흘린다.

왜 직접 만드나 — Filebeat 를 쓰면 Elastic 저장소를 하나 더 붙여야 하고,
Zeek 의 JSON 에는 **어느 로그인지가 들어 있지 않다**(conn/dns/http 가
같은 모양이다). 파일명을 아는 쪽에서 `zeek_log` 를 넣어 주는 편이 확실하다.

★ Zeek 는 로그를 회전시킨다(기본 1시간). 파일이 새로 만들어지면 inode 가
  바뀌므로 그것을 감지해 다시 연다. 감지하지 못하면 조용히 멈춘다 —
  이 랩에서 이미 한 번 겪은 실패 방식이다(§8-50 의 port-forward).
"""
import json, os, socket, time, threading, sys

LOGDIR = "/var/log/zeek"
DEST = ("10.77.0.190", 5141)
WATCH = ["conn", "dns", "http", "ssl", "ntp", "weird", "notice", "files"]


def sender(q, lock):
    sock = None
    while True:
        try:
            if sock is None:
                sock = socket.create_connection(DEST, timeout=10)
            with lock:
                batch, q[:] = q[:], []
            if not batch:
                time.sleep(1)
                continue
            sock.sendall("".join(batch).encode())
        except Exception as e:
            print(f"[ship] 전송 실패, 재연결: {e}", file=sys.stderr, flush=True)
            try:
                sock.close()
            except Exception:
                pass
            sock = None
            time.sleep(5)


def tail(name, q, lock):
    path = os.path.join(LOGDIR, f"{name}.log")
    f, ino = None, None
    while True:
        try:
            st = os.stat(path)
            if f is None or st.st_ino != ino:
                if f:
                    f.close()
                f = open(path, "r")
                f.seek(0, os.SEEK_END)
                ino = st.st_ino
                print(f"[tail] {name} 열림 (inode {ino})", flush=True)
        except FileNotFoundError:
            time.sleep(5)
            continue
        line = f.readline()
        if not line:
            time.sleep(0.5)
            continue
        line = line.strip()
        if not line or not line.startswith("{"):
            continue
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            continue
        rec["zeek_log"] = name
        with lock:
            q.append(json.dumps(rec) + "\n")


def main():
    q, lock = [], threading.Lock()
    threading.Thread(target=sender, args=(q, lock), daemon=True).start()
    for n in WATCH:
        threading.Thread(target=tail, args=(n, q, lock), daemon=True).start()
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    main()
