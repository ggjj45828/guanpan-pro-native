/* Read-only legacy fund business. Snapshot original localStorage strings before
 * blocking any mutation; ETF/stock data access and original keys stay intact. */
(function(root){'use strict';
 var once=null,status='尚未归档';
 function archive(storage,prefix,at,id){
  var values={};
  for(var i=0;i<storage.length;i++){
   var k=storage.key(i);
   if(k&&k.indexOf(prefix)===0&&k.indexOf('.readonly-history.')<0)values[k]=storage.getItem(k);
  }
  var key=prefix+'.readonly-history.'+String(at)+'.'+String(id),payload=JSON.stringify({schema:1,at:at,values:values});
  if(storage.getItem(key)!==null)throw Error('拒绝覆盖既有历史备份');
  storage.setItem(key,payload);
  if(storage.getItem(key)!==payload)throw Error('历史备份读回校验失败');
  var decoded=JSON.parse(storage.getItem(key));
  Object.keys(values).forEach(function(k){if(decoded.values[k]!==values[k])throw Error('原始字段校验失败');});
  return {key:key,payload:payload,count:Object.keys(values).length};
 }
 function ensure(){
  if(once)return once;
  try{
   if(typeof KEY==='undefined')return null;
   once=archive(root.localStorage,String(KEY),Date.now(),Math.random().toString(36).slice(2));
   status='原始字符串已备份并校验，旧数据未删除';return once;
  }catch(e){status='备份失败，原始数据仍保留：'+e.message;return null;}
 }
 function block(){ensure();return false;}
 function render(){
  ensure();var target=root.document&&root.document.getElementById('pgFund');if(!target)return false;
  target.replaceChildren();
  var title=root.document.createElement('h2');title.textContent='场外历史 · 只读归档';target.appendChild(title);
  var text=root.document.createElement('p');text.textContent='场外申赎、定投、净值应用和分红登记已停用。'+status;target.appendChild(text);
  var pre=root.document.createElement('pre');
  try{var summary=typeof FUND==='object'?{holdings:FUND.hold||[],trades:FUND.trades||[],plans:FUND.plans||[]}:{};pre.textContent=JSON.stringify(summary,null,2);}catch(e){pre.textContent='请使用完整历史导出查看';}
  pre.style.whiteSpace='pre-wrap';target.appendChild(pre);
  if(once){var button=root.document.createElement('button');button.className='btn';button.textContent='导出完整历史备份';button.onclick=function(){
   var url=URL.createObjectURL(new Blob([once.payload],{type:'application/json'})),a=root.document.createElement('a');a.href=url;a.download='guanpan-readonly-history.json';a.click();setTimeout(function(){URL.revokeObjectURL(url);},1000);
  };target.appendChild(button);}return false;
 }
 var api={archive:archive,block:block,render:render};root.GuanpanHistoricalGuard=api;
 if(typeof module!=='undefined'&&module.exports)module.exports=api;
})(typeof globalThis!=='undefined'?globalThis:this);
