import {test} from 'node:test';
import assert from 'node:assert/strict';
import {once} from 'node:events';
import {createBroker} from './server.mjs';

test('exchange and refresh use server secret, expose only token fields, reject untrusted input',async()=>{
  const calls=[];
  const server=createBroker({clientID:'123',clientSecret:'server-test-secret',fetcher:async(url,options)=>{
    calls.push([url,Object.fromEntries(options.body),options.redirect,options.headers]);
    if(url.endsWith('/revoke')) return new Response(null,{status:200});
    return new Response(JSON.stringify({access_token:'new-access',refresh_token:'rotated-refresh',expires_at:2000000000,athlete:{id:7,private:'excluded'}}),{status:200});
  }});
  server.listen(0,'127.0.0.1'); await once(server,'listening');
  const url=`http://127.0.0.1:${server.address().port}`;
  const post=(path,body,headers={})=>fetch(url+path,{method:'POST',headers:{'content-type':'application/json',...headers},body:JSON.stringify(body)});
  try {
    let result=await post('/oauth/exchange',{client_id:'123',code:'valid-code'});
    assert.equal(result.status,200); assert.equal(result.headers.get('cache-control'),'no-store');
    let token=await result.json(); assert.deepEqual(token.athlete,{id:7}); assert.equal(token.refresh_token,'rotated-refresh');
    assert.equal(calls[0][1].client_secret,'server-test-secret'); assert.equal(calls[0][2],'error');
    result=await post('/oauth/refresh',{client_id:'123',refresh_token:'old-refresh'});
    assert.equal(result.status,200); assert.equal(calls[1][1].grant_type,'refresh_token');
    result=await post('/oauth/revoke',{client_id:'123',token:'old-refresh'});
    assert.equal(result.status,200); assert.equal(calls[2][1].token_type_hint,'refresh_token');
    assert.equal(calls[2][3].Authorization,'Basic '+Buffer.from('123:server-test-secret').toString('base64'));
    assert.equal((await post('/oauth/exchange',{client_id:'wrong',code:'valid-code'})).status,400);
    assert.equal((await post('/oauth/exchange',{client_id:'123',code:'bad\r\ncode'})).status,400);
    assert.equal((await post('/oauth/exchange',{client_id:'123',code:'valid-code'},{origin:'https://untrusted.invalid'})).status,415);
    for(let i=0;i<6;i++) await post('/oauth/exchange',{client_id:'123',code:'valid-code'});
    assert.equal((await post('/oauth/exchange',{client_id:'123',code:'valid-code'})).status,429);
  } finally { server.close(); server.closeAllConnections(); }
});
