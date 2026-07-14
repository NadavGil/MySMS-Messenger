// Convention: `apiBaseUrl` is ONLY the API origin (protocol + host + port),
// never a path. MessagesApiService always appends the fixed
// `/api/v1/messages` path — see the comment there and in
// environment.production.ts (this fixes QA report round1 finding M2, the
// double `/api/api/v1/messages` production 404).
export const environment = {
  production: false,
  apiBaseUrl: 'http://localhost:3000',
};
