import http from 'node:http';
const id='11111111-1111-4111-8111-111111111111';
let uploads=0,retries=0;
let glossary=['OpenAI','中英夾雜'];
const hubRuns=[
 {id,status:'done',sourceType:'real',parentId:null,duration:12.5,createdAt:'2026-10-15T00:00:00Z',cleanText:'Keep English，保留中文。',rawText:'keep English 原始'},
 {id:'22222222-2222-4222-8222-222222222222',status:'done',sourceType:'real',parentId:id,duration:12.5,createdAt:'2026-10-15T00:01:00Z',cleanText:'重試'},
 {id:'33333333-3333-4333-8333-333333333333',status:'done',sourceType:'scripted',duration:99,createdAt:'2026-10-14T00:00:00Z'},
 {id:'44444444-4444-4444-8444-444444444444',status:'failed',sourceType:'real',duration:22,error:'fixture',createdAt:'2026-10-13T00:00:00Z'},
 {id:'55555555-5555-4555-8555-555555555555',status:'done',sourceType:'real',duration:5,createdAt:'2026-10-12T00:00:00Z',cleanText:'長文 English。'.repeat(2000)}
];
const server=http.createServer(async(req,res)=>{
  let body='';for await(const part of req)body+=part;
  function reply(status,obj){res.writeHead(status,{'Content-Type':'application/json'});res.end(JSON.stringify(obj));}
  if(req.url.startsWith('/partial/api/'))return reply(200,{words:1,tokens:1});
  if(req.url==='/api/config')return reply(200,{app:'dex-voice-pilot',nativeProtocol:1,configured:true,token:'fixture-only',settings:{glossary},models:{transcribe:'fixture-stt',cleanup:'fixture-cleanup'}});
  if(req.url==='/empty/api/runs')return reply(200,[]);
  if(req.url==='/failure/api/runs')return reply(503,{error:'fixture offline'});
  if(req.url==='/api/runs'&&req.method==='GET')return reply(200,hubRuns);
  if(req.method!=='GET'&&req.headers['x-pilot-token']!=='fixture-only')return reply(403,{error:'missing token'});
  if(req.url==='/api/glossary'&&req.method==='PUT'){glossary=JSON.parse(body).glossary;return reply(200,{glossary});}
  if(req.url==='/failure/api/glossary')return reply(503,{error:'save failed'});
  if(req.url==='/api/runs'&&req.method==='POST'){
    if(!body.includes('native-contract-test')||!body.includes('name="sourceType"\r\n\r\nreal'))return reply(400,{error:'bad multipart'});
    uploads++;
    if(uploads===2)return reply(409,{error:'已有一筆正在處理，請稍候。'});
    if(uploads===3)return reply(202,{unexpected:'missing id'});
    if(uploads>3)return reply(400,{error:'duplicate upload'});
    return reply(202,{id,status:'transcribing'});
  }
  if(req.url===`/api/runs/${id}`&&req.method==='GET')return reply(200,{id,status:'failed',rawText:'Keep English，保留中文。',failedStage:'cleanup',error:'fixture failure'});
  if(req.url===`/api/runs/${id}/retry`){
    if(JSON.parse(body).mode!=='cleanup'||++retries!==1)return reply(400,{error:'must retry only cleanup'});
    return reply(202,{id,status:'done',cleanText:'Keep English，保留中文。'});
  }
  if(req.url===`/api/runs/${id}`&&req.method==='PATCH')return reply(200,{id,status:'done'});
  if(req.url==='/redirect/api/config'){res.writeHead(302,{Location:'/should-not-follow'});res.end();return;}
  if(req.url==='/should-not-follow')return reply(200,{app:'dex-voice-pilot',nativeProtocol:1,configured:true,token:'redirect-was-followed'});
  reply(404,{error:'not found'});
});
server.listen(0,'127.0.0.1',()=>console.log(server.address().port));
