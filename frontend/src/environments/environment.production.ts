// Convention (see also environment.development.ts / environment.ts and
// MessagesApiService): `apiBaseUrl` is ONLY the API origin (protocol + host
// + port), or '' when the API is served from the same origin as the SPA
// (e.g. behind a reverse proxy). It must NEVER include the `/api` path
// segment — MessagesApiService always appends the fixed `/api/v1/messages`
// path itself. Mixing the two conventions produced a double
// `/api/api/v1/messages` 404 in production (QA report round1, M2).
export const environment = {
  production: true,
  // Cross-origin two-service Render deploy (tech-design.md §14.5): the SPA
  // (mysms-messenger-web, a Render Static Site) and the API
  // (mysms-messenger-api, a Render web service) are genuinely separate
  // origins, so this must be the API service's absolute origin — NOT
  // '/api' and NOT a trailing slash. MessagesApiService always appends the
  // fixed '/api/v1/...' path itself; mixing conventions produced a double
  // `/api/api/v1/messages` 404 in production (QA report round1, M2).
  // PLACEHOLDER service name — director confirms the final Render service
  // name/URL (tech-design.md §14.9 open question 1) before the real deploy
  // build; Render assigns hostnames as <service-name>.onrender.com.
  apiBaseUrl: 'https://mysms-messenger-api.onrender.com',
};
