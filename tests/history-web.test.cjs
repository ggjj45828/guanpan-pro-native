const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const H=require('../nas-sync-server/web/history-guard.js');
class Storage{constructor(values={}){this.values=new Map(Object.entries(values));}get length(){return this.values.size;}key(i){return [...this.values.keys()][i]??null;}getItem(k){return this.values.get(k)??null;}setItem(k,v){this.values.set(k,String(v));}}
test('web archive preserves original unknown strings exactly without deleting data',()=>{
 const storage=new Storage({gp:'{ "unknown": true }',gp_fund:'{"hold":[{"code":"old"}]}',unrelated:'outside'});
 const r=H.archive(storage,'gp',1,'test');assert.equal(r.count,2);const saved=JSON.parse(r.payload);
 assert.equal(saved.values.gp,'{ "unknown": true }');assert.equal(storage.getItem('gp_fund'),'{"hold":[{"code":"old"}]}');
 assert.equal(storage.getItem('unrelated'),'outside');assert.equal('unrelated'in saved.values,false);
});
test('later archive does not recursively copy previous archives or overwrite them',()=>{
 const storage=new Storage({gp:'first'}),a=H.archive(storage,'gp',1,'one');storage.setItem('gp','second');
 const b=H.archive(storage,'gp',2,'two');assert.equal(JSON.parse(b.payload).values.gp,'second');assert.equal(storage.getItem(a.key),a.payload);assert.equal(b.count,1);
 assert.throws(()=>H.archive(storage,'gp',1,'one'),/覆盖/);
});
test('failed archive readback leaves every source key untouched',()=>{
 const storage=new Storage({gp_fund:'original'}),old=storage.setItem.bind(storage);storage.setItem=(k,v)=>old(k,v+'truncated');
 assert.throws(()=>H.archive(storage,'gp',1,'bad'),/校验/);assert.equal(storage.getItem('gp_fund'),'original');
});
test('all web inline scripts still parse after read-only business guards',()=>{
 const html=fs.readFileSync(require.resolve('../nas-sync-server/web/index.html'),'utf8');let count=0;
 for(const m of html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi)){
  if(/type\s*=\s*["'](?:application\/json|application\/ld\+json)/i.test(m[1])||!m[2].trim())continue;
  new vm.Script(m[2],{filename:'legacy-web-inline-'+(++count)});
 }
 assert.ok(count>0);assert.match(html,/history-guard\.js/);
});
