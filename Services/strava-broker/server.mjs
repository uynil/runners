import http from 'node:http';
import { pathToFileURL } from 'node:url';

// Tokens are returned to the native Keychain. This broker never logs or persists them.
export function createBroker({clientID, clientSecret, fetcher = fetch, now = Date.now}) {
  if (!/^\d+$/.test(clientID ?? '') || !clientSecret) throw new Error('Configure STRAVA_CLIENT_ID and STRAVA_CLIENT_SECRET in the server environment.');
  const limits = new Map();
  return http.createServer(async (req, res) => {
    const send = (status, value, extra = {}) => {
      res.writeHead(status, {'Content-Type':'application/json','Cache-Control':'no-store','X-Content-Type-Options':'nosniff',...extra});
      res.end(JSON.stringify(value));
    };
    if (req.method === 'GET' && req.url === '/health') return send(200, {ok:true});
    if (req.method !== 'POST' || !['/oauth/exchange','/oauth/refresh','/oauth/revoke'].includes(req.url)) return send(404,{error:'not_found'});
    if (req.headers.origin || !/^application\/json(?:;|$)/i.test(req.headers['content-type'] ?? '')) return send(415,{error:'native_json_only'});
    const time = now(), ip = req.socket.remoteAddress;
    for (const [key, state] of limits) if (time - state.start >= 60_000) limits.delete(key);
    if (limits.size > 10_000) return send(429,{error:'rate_limited'},{'Retry-After':'60'});
    const bucket = limits.get(ip) ?? {start:time,count:0};
    if (++bucket.count > 10) return send(429,{error:'rate_limited'},{'Retry-After':'60'});
    limits.set(ip,bucket);
    try {
      let size=0, chunks=[];
      for await (const chunk of req) {
        size+=chunk.length;
        if(size>8192) { send(413,{error:'too_large'}); return; }
        chunks.push(chunk);
      }
      let value;
      try { value=JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { return send(400,{error:'invalid_json'}); }
      if (!value || Array.isArray(value) || value.client_id !== clientID) return send(400,{error:'invalid_client'});
      const refresh = req.url === '/oauth/refresh', revoke = req.url === '/oauth/revoke', key = revoke ? 'token' : (refresh ? 'refresh_token' : 'code');
      if (typeof value[key] !== 'string' || !/^[A-Za-z0-9._~-]{1,2048}$/.test(value[key])) return send(400,{error:'invalid_grant'});
      const body=new URLSearchParams({client_id:clientID,client_secret:clientSecret,grant_type:refresh?'refresh_token':'authorization_code',[key]:value[key]});
      if (revoke) {
        const response=await fetcher('https://www.strava.com/oauth/revoke',{method:'POST',
          headers:{Authorization:'Basic '+Buffer.from(clientID+':'+clientSecret).toString('base64')},
          body:new URLSearchParams({token:value.token,token_type_hint:'refresh_token'}),redirect:'error',signal:AbortSignal.timeout(15_000)});
        if(!response.ok) return send(response.status===401?401:502,{error:'revocation_failed'});
        return send(200,{revoked:true});
      }
      const response=await fetcher('https://www.strava.com/oauth/token',{method:'POST',body,redirect:'error',signal:AbortSignal.timeout(15_000)});
      if(response.status===429) return send(429,{error:'rate_limited'},{'Retry-After':'900'});
      if(!response.ok) return send(response.status===400||response.status===401?401:502,{error:'token_exchange_failed'});
      const raw=await response.text();
      if(raw.length>16384) return send(502,{error:'invalid_upstream'});
      const token=JSON.parse(raw);
      const valid=s=>typeof s==='string'&&/^[\x21-\x7e]{1,4096}$/.test(s);
      if(!valid(token.access_token)||!valid(token.refresh_token)||!Number.isFinite(token.expires_at)||token.expires_at<=0) return send(502,{error:'invalid_upstream'});
      if(!refresh && (!Number.isSafeInteger(token.athlete?.id)||token.athlete.id<=0)) return send(502,{error:'invalid_athlete'});
      return send(200,{access_token:token.access_token,refresh_token:token.refresh_token,expires_at:token.expires_at,
        ...(token.athlete?.id ? {athlete:{id:token.athlete.id}} : {})});
    } catch { if(!res.headersSent) send(502,{error:'token_service_unavailable'}); }
  });
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const server=createBroker({clientID:process.env.STRAVA_CLIENT_ID,clientSecret:process.env.STRAVA_CLIENT_SECRET});
  const port=Number(process.env.PORT ?? 8787);
  server.requestTimeout=20_000; server.headersTimeout=10_000;
  server.listen(port,'127.0.0.1',()=>process.stdout.write(`Strava token broker listening on loopback port ${port}. Use an HTTPS reverse proxy for the app.\n`));
}
