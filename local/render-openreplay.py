import sys, yaml
out = sys.argv[1]
NS = "local.svc.cluster.local"
BIG   = {"chalice", "api", "assist", "spot"}
SMALL = {"alerts", "heuristics", "sourcemapreader"}
def res(name):
    if name in BIG:   return {"requests": {"cpu": "50m", "memory": "256Mi"},
                              "limits":   {"cpu": "1",   "memory": "768Mi"}}
    if name in SMALL: return {"requests": {"cpu": "20m", "memory": "64Mi"},
                              "limits":   {"cpu": "300m","memory": "192Mi"}}
    return {"requests": {"cpu": "25m", "memory": "128Mi"},
            "limits":   {"cpu": "500m","memory": "384Mi"}}

def secret_env(name, sec, key):
    return {"name": name, "valueFrom": {"secretKeyRef": {"name": sec, "key": key}}}

# 이 클러스터의 실제 엔드포인트. 자격증명은 값이 아니라 $(VAR) 로 넣고
# 그 VAR 는 Secret 에서 온다 — 렌더 산출물에 평문이 남지 않는다.
REWRITE = {
    "POSTGRES_STRING":   f"postgres://openreplay:$(pg_password)@openreplay-postgresql.{NS}:5432/openreplay",
    "REDIS_STRING":      f"redis://:$(redis_password)@redis-headless.{NS}:6379/4",
    # ★ DB 이름을 붙이면 안 된다. Go 클라이언트가 net.SplitHostPort 로 자르면서
    #   포트가 "9000/openreplay" 가 되어 `unknown port` 로 죽는다.
    #   DB·사용자·비밀번호는 ch_db·CH_USERNAME·CH_PASSWORD 로 따로 넘긴다.
    "CLICKHOUSE_STRING": f"clickhouse-headless.{NS}:9000",
    "KAFKA_SERVERS":     f"kafka-headless.{NS}:9092",
    "AWS_ENDPOINT":      f"http://minio-headless.{NS}:9000",
}
INJECT = {
    "POSTGRES_STRING":   [("pg_password",    "openreplay-secret", "db-password")],
    "REDIS_STRING":      [("redis_password", "redis-secret",      "redis-password")],
    "CLICKHOUSE_STRING": [("CLICKHOUSE_USERNAME", None, None),
                          ("CLICKHOUSE_PASSWORD", "clickhouse-secret", "password")],
    "AWS_ENDPOINT":      [("AWS_ACCESS_KEY_ID",     "minio-secret", "root-user"),
                          ("AWS_SECRET_ACCESS_KEY", "minio-secret", "root-password")],
}

def fix_container(c):
    if not c.get("resources"):
        c["resources"] = res(c.get("name", ""))
    envs = c.get("env") or []
    names = {e.get("name") for e in envs}
    add = []
    by_name = {e.get("name"): e for e in envs}
    for e in envs:
        n = e.get("name")
        if n in REWRITE and "value" in e:
            e["value"] = REWRITE[n]
            for var, sec, key in INJECT.get(n, []):
                # ★ 이미 있으면 건너뛰면 안 된다 — 차트가 pg_password 를 자기
                #   Secret 에서 주는데 그 값이 미치환 "{{ randAlphaNum 20}}" 라
                #   DSN 파싱이 깨진다. 우리 것으로 **덮어쓴다**.
                if var in by_name:
                    tgt = by_name[var]; tgt.pop("value", None); tgt.pop("valueFrom", None)
                    if sec is None: tgt["value"] = "openreplay"
                    else: tgt["valueFrom"] = {"secretKeyRef": {"name": sec, "key": key}}
                    continue
                if sec is None:
                    add.append({"name": var, "value": "openreplay"})
                else:
                    add.append(secret_env(var, sec, key))
                names.add(var)
        # 차트가 빈 문자열로 둔 S3 자격증명을 Secret 으로 채운다
        elif n == "AWS_ACCESS_KEY_ID" and not e.get("value"):
            e.pop("value", None); e["valueFrom"] = {"secretKeyRef": {"name": "minio-secret", "key": "root-user"}}
        elif n == "AWS_SECRET_ACCESS_KEY" and not e.get("value"):
            e.pop("value", None); e["valueFrom"] = {"secretKeyRef": {"name": "minio-secret", "key": "root-password"}}
    # ★ *_STRING 이 없는 컨테이너도 pg_password 등을 직접 쓴다(chalice 계열).
    #   트리거에 의존하지 말고 **이름 기준으로 무조건** 우리 Secret 을 가리키게 한다.
    FORCE = {
        "pg_password":           ("openreplay-secret", "db-password"),
        "POSTGRES_PASSWORD":     ("openreplay-secret", "db-password"),
        "ch_password":           ("clickhouse-secret", "password"),
        "CLICKHOUSE_PASSWORD":   ("clickhouse-secret", "password"),
        "redis_password":        ("redis-secret",      "redis-password"),
        "CH_PASSWORD":           ("clickhouse-secret", "password"),
        "ch_password":           ("clickhouse-secret", "password"),
        "S3_KEY":                ("minio-secret",      "root-user"),
        "S3_SECRET":             ("minio-secret",      "root-password"),
        # 마이그레이션 Job 의 initContainer·컨테이너가 쓰는 이름.
        # 차트 Secret 의 값은 미치환 "{{ randAlphaNum 20}}" 라 인증이 실패한다.
        "PGPASSWORD":            ("openreplay-secret", "db-password"),
        "CLICKHOUSE_PASS":       ("clickhouse-secret", "password"),
    }
    # chalice(psycopg2)는 접속 정보를 개별 변수로 받는다 — *_STRING 이 없다.
    PLAIN = {
        "ch_db": "openreplay", "CH_USERNAME": "openreplay",
        "CLICKHOUSE_DATABASE": "openreplay",
        "pg_host": f"openreplay-postgresql.{NS}", "pg_port": "5432",
        "pg_dbname": "openreplay", "pg_user": "openreplay",
        "ch_host": f"clickhouse-headless.{NS}", "ch_port": "9000",
        "ch_port_http": "8123", "ch_user": "openreplay",
        "S3_HOST": f"http://minio-headless.{NS}:9000",
    }
    for e in envs:
        n = e.get("name")
        if n in FORCE:
            sec, key = FORCE[n]
            e.pop("value", None)
            e["valueFrom"] = {"secretKeyRef": {"name": sec, "key": key}}
        elif n in PLAIN:
            e.pop("valueFrom", None)
            e["value"] = PLAIN[n]
    if add:
        c["env"] = add + envs

docs = []
for d in yaml.safe_load_all(open('/tmp/or-raw.yaml', encoding='utf-8')):
    if not d: continue
    d.setdefault('metadata', {}).setdefault('labels', {}).update({
        'app.kubernetes.io/part-of': 'oneinchmarket',
        'app.kubernetes.io/component': 'observability',
    })
    k = d.get('kind'); spec = None
    if k in ('Deployment', 'StatefulSet', 'DaemonSet', 'Job'):
        spec = d['spec']['template']['spec']
        d['spec']['template'].setdefault('metadata', {}).setdefault('labels', {}).update({
            'app.kubernetes.io/part-of': 'oneinchmarket',
            'app.kubernetes.io/component': 'observability',
            # ★ NetworkPolicy 가 이 라벨로 고른다. 차트는 Deployment 파드에만
            #   붙이므로 Job(databases-migrate) 파드가 빠져 DB 접근이 막혔다.
            'app.kubernetes.io/instance': 'openreplay',
        })
    elif k == 'CronJob':
        spec = d['spec']['jobTemplate']['spec']['template']['spec']
    if spec:
        for c in spec.get('containers', []) + spec.get('initContainers', []):
            fix_container(c)
    docs.append(d)
with open(out, 'w', encoding='utf-8') as f:
    f.write("# 생성 파일 — 직접 고치지 말 것. local/render-openreplay.sh 가 만든다.\n")
    yaml.safe_dump_all(docs, f, default_flow_style=False, allow_unicode=True, sort_keys=False)
print(f"  {out} — 오브젝트 {len(docs)}개")
