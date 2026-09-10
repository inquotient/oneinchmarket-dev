# Backstage — Keycloak(OIDC) 사인인을 넣은 자체 빌드
#
# ★ 왜 공식 예제 이미지를 못 쓰는가 (실측, 2026-09-11)
#   `ghcr.io/backstage/backstage:1.30.2` 의 백엔드 번들은 auth 모듈로
#   **guest 하나만** 등록하고(`grep -o "auth-backend-module-[a-z-]*"` 결과가
#   `guest` 뿐), 프런트 번들도 provider 로 `guest` 만 참조한다.
#   OIDC 모듈은 node_modules 에 **있지만 붙어 있지 않다** — "설치돼 있다" 와
#   "등록돼 있다" 는 다르다.
#   백엔드는 한 줄로 붙일 수 있지만 **프런트는 코드**다(새 프런트엔드 시스템의
#   SignInPageBlueprint). 그래서 앱을 직접 빌드한다.
#
# ★ 앱 소스는 `app/` 에 있다 — `@backstage/create-app` 이 만든 것에서
#   딱 두 곳만 고쳤다:
#     packages/app/src/modules/auth/index.tsx  (신규: OIDC ApiRef + 사인인 페이지)
#     packages/backend/src/index.ts            (guest 제거, oidc 추가)
#
# ★ 다단계 빌드다. 마지막 단계에는 **런타임 의존성만** 남긴다
#   (`yarn workspaces focus --all --production`).

# ── 1) 워크스페이스 뼈대만 — 의존성 레이어를 캐시한다 ──────────────────
FROM docker.io/library/node:22-bookworm-slim AS packages
WORKDIR /app
COPY app/package.json app/yarn.lock app/.yarnrc.yml ./
COPY app/.yarn ./.yarn
COPY app/packages packages
# package.json 만 남기면 소스가 바뀌어도 install 레이어가 유효하다.
RUN find packages -mindepth 2 -maxdepth 2 ! -name "package.json" -exec rm -rf {} \+

# ── 2) 빌드 ───────────────────────────────────────────────────────────
FROM docker.io/library/node:22-bookworm-slim AS build
WORKDIR /app
# better-sqlite3 등 네이티브 모듈 빌드에 필요하다(런타임 이미지에는 안 남는다).
RUN apt-get update && \
    apt-get install -y --no-install-recommends python3 g++ build-essential libsqlite3-dev ca-certificates && \
    rm -rf /var/lib/apt/lists/*
COPY --from=packages /app .
RUN yarn install --immutable
COPY app/ .
# tsc 를 먼저 돌려 타입 오류를 **빌드 시점에** 잡는다 — 런타임에 드러나면
# 파드가 CrashLoop 하고 원인이 멀어진다.
RUN yarn tsc && yarn build:all

# ── 3) 런타임 ─────────────────────────────────────────────────────────
FROM docker.io/library/node:22-bookworm-slim
WORKDIR /app
RUN apt-get update && \
    apt-get install -y --no-install-recommends libsqlite3-0 ca-certificates && \
    rm -rf /var/lib/apt/lists/*
ENV NODE_ENV=production
# WORKDIR 이 만든 /app 은 **root 소유**다. 그대로 USER node 로 넘어가면
# 다음 단계의 `tar x` 가 디렉터리를 못 만들어 죽는다(실측:
#   tar: packages: Cannot mkdir: Permission denied).
# COPY --chown 은 파일 소유만 바꿀 뿐 **디렉터리 쓰기 권한을 주지 않는다.**
RUN chown node:node /app
# ★ 비-root. node 이미지의 `node` 사용자는 uid 1000 이라 이 레포 규약과 맞는다.
USER node
COPY --from=build --chown=node:node /app/.yarn ./.yarn
COPY --from=build --chown=node:node /app/.yarnrc.yml /app/yarn.lock /app/package.json ./
COPY --from=build --chown=node:node /app/packages/backend/dist/skeleton.tar.gz ./
RUN tar xzf skeleton.tar.gz && rm skeleton.tar.gz
RUN yarn workspaces focus --all --production && yarn cache clean
COPY --from=build --chown=node:node /app/packages/backend/dist/bundle.tar.gz ./
RUN tar xzf bundle.tar.gz && rm bundle.tar.gz
# 카탈로그 파일은 ConfigMap 이 /app/catalog 로 마운트한다(매니페스트 참조).
COPY --from=build --chown=node:node /app/examples ./examples
EXPOSE 7007
CMD ["node", "packages/backend", "--config", "app-config.yaml", "--config", "app-config.production.yaml"]
