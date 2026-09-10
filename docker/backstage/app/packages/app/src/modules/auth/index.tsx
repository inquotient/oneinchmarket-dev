/*
 * Keycloak(OIDC) 사인인 — 이 앱을 직접 빌드하는 이유가 이 파일이다.
 *
 * ★ 왜 설정으로 못 하는가
 *   새 프런트엔드 시스템에서 사인인 페이지는 `SignInPageBlueprint` 확장이고,
 *   그것은 **코드**다(`@backstage/plugin-app` 의 alpha 문서가 그 예를 든다).
 *   `app.extensions` 로는 만들 수 없다. 그래서 공식 예제 이미지
 *   (ghcr.io/backstage/backstage)를 그대로 쓰면 guest 밖에 못 쓴다 —
 *   그 이미지의 프런트 번들은 provider 로 `guest` 하나만 참조한다(실측).
 *
 * ★ 백엔드에 일반 OIDC 제공자가 있어도 프런트가 그것을 부르지 않으면
 *   아무 일도 일어나지 않는다. 두 쪽을 함께 넣어야 한다
 *   (backend: packages/backend/src/index.ts).
 */
import {
  ApiBlueprint,
  configApiRef,
  createApiRef,
  createFrontendModule,
  discoveryApiRef,
  oauthRequestApiRef,
} from '@backstage/frontend-plugin-api';
import { SignInPageBlueprint } from '@backstage/plugin-app-react';
import { OAuth2 } from '@backstage/core-app-api';
import { SignInPage } from '@backstage/core-components';
import type {
  BackstageIdentityApi,
  ProfileInfoApi,
  SessionApi,
} from '@backstage/core-plugin-api';

/**
 * ★ Backstage 는 범용 OIDC 용 ApiRef 를 기본 제공하지 않는다
 *   (google/github/microsoft 만 있다 — 실측). 그래서 직접 만든다.
 *   id 는 프런트 내부 식별자이고, **백엔드 제공자 이름('oidc')과는 별개**다.
 */
export const oidcAuthApiRef = createApiRef<
  ProfileInfoApi & BackstageIdentityApi & SessionApi
>({ id: 'auth.oidc' });

const oidcAuthApi = ApiBlueprint.make({
  name: 'oidc',
  params: define =>
    define({
      api: oidcAuthApiRef,
      deps: {
        discoveryApi: discoveryApiRef,
        oauthRequestApi: oauthRequestApiRef,
        configApi: configApiRef,
      },
      factory: ({ discoveryApi, oauthRequestApi, configApi }) =>
        OAuth2.create({
          discoveryApi,
          oauthRequestApi,
          // 백엔드 라우트가 /api/auth/oidc/* 이므로 provider.id 는 'oidc' 여야 한다.
          provider: { id: 'oidc', title: 'Keycloak', icon: () => null },
          // ★ 이 값이 백엔드의 auth.providers.oidc.<environment> 를 고른다.
          //   양쪽이 어긋나면 "provider not configured" 로 죽는다.
          environment: configApi.getOptionalString('auth.environment'),
          defaultScopes: ['openid', 'profile', 'email'],
        }),
    }),
});

const signInPage = SignInPageBlueprint.make({
  params: {
    loader: async () => (props: any) => (
      <SignInPage
        {...props}
        provider={{
          id: 'oidc',
          title: 'Keycloak',
          message: 'Keycloak 계정으로 로그인합니다',
          apiRef: oidcAuthApiRef,
        }}
      />
    ),
  },
});

export const authModule = createFrontendModule({
  pluginId: 'app',
  extensions: [oidcAuthApi, signInPage],
});
