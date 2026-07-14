// Convention (see also environment.development.ts / environment.ts and
// MessagesApiService): `apiBaseUrl` is ONLY the API origin (protocol + host
// + port), or '' when the API is served from the same origin as the SPA
// (e.g. behind a reverse proxy). It must NEVER include the `/api` path
// segment — MessagesApiService always appends the fixed `/api/v1/messages`
// path itself. Mixing the two conventions produced a double
// `/api/api/v1/messages` 404 in production (QA report round1, M2).
export const environment = {
  production: true,
  // '' = same-origin deploy (SPA and API served from one domain, e.g. via a
  // reverse proxy that routes /api/* to Rails). Set this to the deployed API
  // origin (e.g. 'https://api.example.com') if the SPA and API live on
  // different domains.
  apiBaseUrl: '',
};
