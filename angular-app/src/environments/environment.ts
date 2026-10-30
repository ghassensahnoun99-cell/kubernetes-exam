const runtimeEnv = (window as any).__env || {};

export const environment :
{
  production?:boolean,
  apiUrl:string,
}
= {
    production: false,
    apiUrl: runtimeEnv.apiUrl || 'http://localhost:8081',
  };
