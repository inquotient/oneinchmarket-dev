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
    "POSTGRES_STRING":   f"postgres://openreplay:$(pg_password)@postgresql-headless.{NS}:5432/openreplay",
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

# ★ 마이그레이션 Job 의 버전 검사 상한을 18 로 올린다.
#
#   차트는 lowVersion=16.4 / highVersion=17 을 **템플릿에 하드코딩**해서
#   Helm 값으로 못 바꾼다. 우리는 렌더 산출물을 만들므로 여기서 바꾼다.
#
#   근거 — "18 이 안 된다"는 근거를 상류에서 찾지 못했다:
#     · 차트·문서·커밋 이력·이슈 어디에도 사유가 없다
#     · 상한이 자기들이 패키징·시험하는 버전을 따라간다
#       (PG 18 은 2025-09 출시, 그들은 2025-10 에 번들을 17.2.0 으로 올렸다)
#     · 스키마에 PG 18 에서 의미가 바뀐 구문이 없다 —
#       GENERATED 19건이 전부 BY DEFAULT AS IDENTITY 이고
#       GENERATED ALWAYS AS (...) (가상 생성 컬럼 변경 대상)는 0건이다
#     · 확장 pg_trgm·pgcrypto 가 18.6 에 정상 설치된다
#     · init_schema.sql 적용 결과가 두 버전에서 동일하다
#       (테이블 41 · 인덱스 148 · 시퀀스 21)
#   즉 지원 매트릭스 지연이지 알려진 비호환이 아니다.
#
#   ★ 이건 로컬만의 일탈이 아니다. dev/prod 의 공용 PostgreSQL 도 18.6 이라
#     거기서도 같은 선택이 필요하다 — ADR-071 참조.
def patch_version_gate(spec):
    for c in spec.get("containers", []) + spec.get("initContainers", []):
        args = c.get("args")
        if not args: continue
        c["args"] = [a.replace("highVersion=17", "highVersion=18") if isinstance(a, str) else a
                     for a in args]

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
        "pg_host": f"postgresql-headless.{NS}", "pg_port": "5432",
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
        for c in spec.get("containers", []) + spec.get("initContainers", []):
            fix_container(c)
        patch_version_gate(spec)
    docs.append(d)
with open(out, 'w', encoding='utf-8') as f:
    f.write("# 생성 파일 — 직접 고치지 말 것. local/render-openreplay.sh 가 만든다.\n")
    yaml.safe_dump_all(docs, f, default_flow_style=False, allow_unicode=True, sort_keys=False)
print(f"  {out} — 오브젝트 {len(docs)}개")
