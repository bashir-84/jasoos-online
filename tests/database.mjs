process.on('uncaughtException',e=>{console.error(e.message, e.where||'');process.exit(1)});
import fs from 'node:fs';import assert from 'node:assert/strict';
const {PGlite}=await import(process.env.JASOOS_PGLITE||'@electric-sql/pglite');
const root=new URL('../',import.meta.url);const db=new PGlite();
await db.exec(`create role anon;create role authenticated;create schema auth;create function auth.uid() returns uuid language sql as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;`);
for(const file of ['01_schema.sql','02_words.sql','03_rpc.sql']){try{await db.exec(fs.readFileSync(new URL('supabase/'+file,root),'utf8'));console.log('Loaded',file)}catch(e){console.log('FAILED',file,e.message, 'position',e.position, 'internal',e.internalPosition,e.internalQuery,'where',e.where);process.exit(1)}}
let checks=0;const check=(value,msg)=>{assert(value,msg);checks++};
const people=Array.from({length:6},()=>crypto.randomUUID());let current;
async function call(i,action,data={},r=current,version=r?.version,request=crypto.randomUUID()){await db.query(`select set_config('request.jwt.claim.sub',$1,false)`,[people[i]]);const result=(await db.query('select public.jasoos_api($1,$2,$3::jsonb,$4,$5) as result',[action,r?.room_id||null,JSON.stringify(data),version??null,request])).rows[0].result;return result}
const settings={capacity:3,spies:1,seconds:300,mode:'simple',lang:'fa',voting:true,hints:true,categories:['builtin-0'],custom:[]};
try{current=await call(0,'create',{name:'علی',title:'آزمون',alias:'۴۸۲۶',settings},null);check(current.alias==='4826','normalize room code');}catch(e){console.log('CREATE ERROR',e.message);throw e}
current=await call(1,'join',{name:'سارا',code:'4826'},null);current=await call(2,'join',{name:'مینا',code:'۴۸۲۶'},null);check(current.players.length===3,'three members');
async function host(action,data={}){current=await call(0,'snapshot');current=await call(0,action,data);return current}
async function rejects(i,action,data={},code){try{await call(i,action,data);throw Error('Expected rejection '+action)}catch(e){if(e.message.startsWith('Expected'))throw e;check(e.message===code,action+' expected '+code+' got '+e.message)}}
await rejects(1,'deal',{},'HOST_ONLY');
current=await host('deal');check(current.state.stage==='DEALING','deal stage');check(!JSON.stringify(current).includes('ordinary_word'),'no secret word in projection');
const sqlSecrets=(await db.query('select * from jasoos_private.secrets')).rows[0];
await rejects(0,'start',{},'WAIT_FOR_READY');
for(let i=0;i<3;i++){current=await call(i,'snapshot');const player=current.players.find(p=>p.id===current.me);const spy=sqlSecrets.spies.includes(player.id);check(current.my_card===(spy?'تو جاسوسی!':sqlSecrets.ordinary_word),'only own card');current=await call(i,'ready',{ready:true});}
current=await host('start');check(current.state.stage==='PLAYING','discussion');
const before=current.version;current=await call(0,'pause',{},current,before-1);check(current.stale&&current.state.paused===false,'stale version blocks mutation');
current=await host('pause');check(current.state.paused,'pause');current=await host('resume');check(!current.state.paused,'resume');
current=await host('early');check(current.state.stage==='VOTING','voting started');
for(let i=0;i<3;i++){current=await call(i,'snapshot');const id=current.me;await rejects(i,'vote',{picks:[id]},'INVALID_BALLOT');const target=current.players.find(p=>p.id!==id).id;current=await call(i,'vote',{picks:[target]});const other=current.players.find(p=>p.id!==id&&p.id!==target).id;current=await call(i,'vote',{picks:[other]});check(current.my_ballot[0]===other,'vote updated');check(current.players.filter(p=>p.voted).length>=1,'public participation only');check(!('ballots'in current),'no other ballots')}
current=await host('lock_votes');check(['RUNOFF_WAIT','RESULT','CAUGHT'].includes(current.state.stage),'valid vote resolution');
// Cancelled rounds never expose secrets, restart preserves members.
if(!['RESULT','CANCELLED'].includes(current.state.stage))current=await host('cancel',{confirm:'CANCEL'});
if(current.state.stage==='CANCELLED')check(!current.ordinary_word&&!current.spies,'cancellation private');current=await host('next');check(current.state.stage==='LOBBY'&&current.players.length===3&&!current.my_card&&current.my_ballot.length===0,'clean next round');
// No-vote timeout and advanced cards.
current=await host('settings',{settings:{...settings,voting:false,mode:'advanced',seconds:1}});current=await host('deal');const round=current.state.round_id;const advancedSecret=(await db.query('select * from jasoos_private.secrets where round_id=$1',[round])).rows[0];for(let i=0;i<3;i++){current=await call(i,'snapshot');check(current.my_card===(advancedSecret.spies.includes(current.me)?advancedSecret.spy_word:advancedSecret.ordinary_word),'paired card correct');check(!('isSpy' in current)&&!('spy_word' in current),'no advanced role flag');current=await call(i,'ready',{ready:true})}current=await host('start');await db.query(`update jasoos_private.rooms set state=jsonb_set(state,'{deadline}',to_jsonb((clock_timestamp()-interval '2 seconds')::text)) where id=$1`,[current.room_id]);current=await call(1,'snapshot');check(current.state.stage==='RESULT'&&current.state.winner==='spies','server timeout no vote');current=await host('next');
// Correct accusation, only a spy can guess, first guess wins, host judges.
current=await host('settings',{settings:{...settings,voting:false}});current=await host('deal');const secret=(await db.query('select * from jasoos_private.secrets where round_id=$1',[current.state.round_id])).rows[0];for(let i=0;i<3;i++){current=await call(i,'snapshot');current=await call(i,'ready',{ready:true})}current=await host('start');current=await host('accuse',{picks:secret.spies});check(current.state.stage==='CAUGHT','correct accusation');current=await host('start_guess');const spyPlayer=current.players.find(p=>secret.spies.includes(p.id));const spy=spyPlayer.name==='علی'?0:spyPlayer.name==='سارا'?1:2;const ordinary=[0,1,2].find(i=>i!==spy);await rejects(ordinary,'guess',{guess:'قهوه'},'SPY_ONLY');current=await call(spy,'guess',{guess:'جواب'});check(current.state.stage==='JUDGING','guess accepted');await rejects(spy,'guess',{guess:'تغییر'},'SPY_ONLY');current=await host('judge',{correct:false});check(current.state.winner==='ordinary','host judgement');
// Six players, two spies: fixed winners plus a boundary runoff, and repeated tie.
current=await call(0,'create',{name:'Player 0',title:'Six players',alias:'six-room',settings:{...settings,capacity:6,spies:2}},null);
for(let i=1;i<6;i++)current=await call(i,'join',{name:'Player '+i,code:'six-room'},null);
current=await host('deal');let multiSecret=(await db.query('select * from jasoos_private.secrets where round_id=$1',[current.state.round_id])).rows[0];check(multiSecret.spies.length===2,'two spies dealt');
for(let i=0;i<6;i++){current=await call(i,'snapshot');current=await call(i,'ready',{ready:true})}current=await host('start');
const ids=current.players.map(p=>p.id);current=await host('early');
const ballots=[[1,2],[0,2],[0,1],[0,1],[0,2],[0,3]];
for(let i=0;i<6;i++){current=await call(i,'snapshot');current=await call(i,'vote',{picks:ballots[i].map(j=>ids[j])})}
current=await host('lock_votes');check(current.state.stage==='RUNOFF_WAIT','boundary tie creates runoff');check(current.state.fixed.length===1&&current.state.fixed[0]===ids[0],'fixed top candidate preserved');check(current.state.slots===1&&current.state.candidates.length===2,'only tied slots rerun');
current=await host('runoff');for(let i=0;i<6;i++){current=await call(i,'snapshot');current=await call(i,'vote',{picks:[ids[[1,2,1,2,1,2][i]]]})}current=await host('lock_votes');check(current.state.winner==='spies'&&current.state.reason==='TIE','second boundary tie awards spies');
current=await host('next');current=await host('settings',{settings:{...settings,capacity:6,spies:2,mode:'advanced'}});current=await host('deal');multiSecret=(await db.query('select * from jasoos_private.secrets where round_id=$1',[current.state.round_id])).rows[0];
for(let i=0;i<6;i++){current=await call(i,'snapshot');current=await call(i,'ready',{ready:true})}current=await host('start');current=await host('hint',{count:3});check(current.state.safe.length===3,'three ordinary players confirmed');check(!current.state.safe.some(id=>multiSecret.spies.includes(id)),'hint never confirms spies');check(Math.abs((Date.parse(current.state.deadline)-Date.parse(current.server_now))/1000-9)<.5,'advanced high-risk hint sets nine seconds');
await rejects(0,'hint',{count:1},'INVALID_HINT');current=await host('early');for(let i=0;i<6;i++){current=await call(i,'snapshot');const safe=current.state.safe.find(id=>id!==current.me);const other=current.players.find(p=>p.id!==current.me&&p.id!==safe).id;await rejects(i,'vote',{picks:[safe,other]},'INVALID_BALLOT')}
current=await host('cancel',{confirm:'CANCEL'});check(!current.spies&&!current.ordinary_word,'multi-spy cancellation has no disclosure');current=await host('next');
// Host transfer is based on server heartbeats, not a client-supplied host id.
await db.query("update jasoos_private.players set last_seen=clock_timestamp()-interval '70 seconds' where room_id=$1",[current.room_id]);current=await call(1,'snapshot');check(current.is_host,'oldest connected member becomes host');await rejects(0,'deal',{},'HOST_ONLY');
// Invalid settings, custom input and capacity are rejected server-side too.
await rejects(1,'settings',{settings:{...settings,capacity:6,spies:5}},'INVALID_SETTINGS');
await rejects(1,'settings',{settings:{...settings,capacity:6,custom:[{spyWord:'test'}]}},'INVALID_CUSTOM_WORDS');
// A retry with the same create idempotency key never creates another room.
const req=crypto.randomUUID();const payload={name:'retry',title:'retry',alias:'retry-room',settings};const a=await call(3,'create',payload,null,null,req);const b=await call(3,'create',payload,null,null,req);check(a.room_id===b.room_id,'idempotent create');

// RLS/grants deny all direct reads and unauthenticated RPCs.
await db.exec('set role authenticated');try{await db.query('select * from jasoos_private.secrets');throw Error('READ_LEAK')}catch(e){check(e.message!=='READ_LEAK','secrets inaccessible to authenticated')};await db.exec('reset role;set role anon');try{await db.query("select public.jasoos_api('snapshot')");throw Error('ANON_RPC')}catch(e){check(e.message!=='ANON_RPC','RPC requires authenticated')};await db.exec('reset role');
console.log('PASS',checks,'database assertions');await db.close();
