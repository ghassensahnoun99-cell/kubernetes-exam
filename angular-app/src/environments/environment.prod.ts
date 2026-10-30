const runtimeEnv = (window as any).__env || {};

export const environment = {
  production: true,
  apiUrl: runtimeEnv.apiUrl || 'http://localhost:8081',
};
