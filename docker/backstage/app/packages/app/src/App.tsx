import { createApp } from '@backstage/frontend-defaults';
import catalogPlugin from '@backstage/plugin-catalog/alpha';
import { navModule } from './modules/nav';
import { homeModule } from './modules/home';
import { authModule } from './modules/auth';

export default createApp({
  // ★ authModule 이 guest 대신 Keycloak 사인인 페이지를 건다.
  features: [catalogPlugin, navModule, homeModule, authModule],
});
