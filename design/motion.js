/* DontsTool design prototype. All system operations are simulated. No system settings, network translation, or clipboard access. */
(()=>{'use strict';
function init(){
const scene=document.body.dataset.dtScene||location.pathname.split('/').pop().replace('.html','');
const panels=[...document.querySelectorAll('#launcherPanel,#launcher-panel,#launcher-window,[data-dt-panel],main,section,[role=dialog]')];
const panel=panels.find(el=>/w-\[640px\]/.test(el.className)&&/h-\[420px\]/.test(el.className))||panels.find(el=>{const r=el.getBoundingClientRect();return r.width>600&&r.width<850&&r.height>380&&r.height<680})||document.querySelector('main');
if(!panel)return;document.querySelectorAll('#toast,#action-toast').forEach(el=>el.remove());panel.classList.add('dt-panel');panel.classList.remove('panel-enter','animate-panel-in');panel.dataset.dtPanel='true';if(getComputedStyle(panel).position==='static')panel.style.position='relative';
const baseTransform=getComputedStyle(panel).transform;const transform=value=>baseTransform==='none'?value:baseTransform+' '+value;
let forcedReduce=false,hidden=false,selected=0,busy=false,toastTimer;
function navigate(scene){if(parent===window){location.href=scene+'.html'}else parent.postMessage({type:'dt:navigate',scene},location.origin==='null'?'*':location.origin)}
const media=matchMedia('(prefers-reduced-motion: reduce)');
const reduced=()=>forcedReduce||media.matches;
function animate(el,frames,options){el.getAnimations().forEach(a=>a.cancel());if(reduced()){el.style.opacity='1';return Promise.resolve()}return el.animate(frames,options).finished.catch(()=>{})}
function enter(){hidden=false;panel.style.visibility='visible';panel.style.pointerEvents='';return animate(panel,[{opacity:0,transform:transform('translateY(8px) scale(.985)')},{opacity:1,transform:transform('translateY(0) scale(1)')}],{duration:220,easing:'cubic-bezier(.16,1,.3,1)'})}
async function close(){if(hidden)return;hidden=true;await animate(panel,[{opacity:1,transform:transform('translateY(0) scale(1)')},{opacity:0,transform:transform('translateY(4px) scale(.99)')}],{duration:140,easing:'cubic-bezier(.4,0,1,1)'});if(hidden){panel.style.visibility='hidden';panel.style.pointerEvents='none'}}
const labels={
'01-launcher':['Safari','访达','终端','Xcode','格式化 JSON','翻译文本','生成 UUID','Base64 编码'],
'02-search':['备忘录','Notion','notes.md','Meeting Notes.pdf','note-ideas.txt'],
'03-text-tools':['格式化并复制 JSON','压缩并复制 JSON'],
'04-translation':['翻译：Stay curious, keep building.','在网页中翻译']
};
const clean=s=>s.replace(/\s/g,'');
let rows=[...panel.querySelectorAll('.result-row,.row-item,[role=option],[data-dt-row]')];
if(!rows.length&&labels[scene]){
for(const label of labels[scene]){
const nodes=[...panel.querySelectorAll('span,h3,p,div')];
let el=nodes.find(n=>clean(n.textContent)===clean(label)&&![...n.children].some(c=>clean(c.textContent)===clean(label)));
while(el&&el!==panel){const r=el.getBoundingClientRect();if(r.width>400&&r.width<650&&r.height>=38&&r.height<=100){if(!rows.includes(el))rows.push(el);break}el=el.parentElement}
}}
rows.forEach((row,i)=>{row.classList.add('dt-row');row.setAttribute('role','option');row.setAttribute('tabindex','-1');row.dataset.dtRow=i});
const visible=()=>rows.filter(r=>!r.hidden&&r.style.display!=='none');
function select(index,flash=false){const list=visible();if(!list.length)return;selected=Math.max(0,Math.min(index,list.length-1));rows.forEach(row=>{const active=row===list[selected];row.classList.toggle('dt-selected',active);row.setAttribute('aria-selected',String(active));const pill=row.querySelector('.action-pill,.action-badge');if(pill)pill.classList.toggle('hidden',!active)});if(scene==='02-search'){const hint=[...panel.querySelectorAll('footer span')].find(el=>el.textContent.includes('Finder')||el.dataset.dtSecondary);if(hint){hint.dataset.dtSecondary='true';hint.textContent=rows.indexOf(list[selected])>=2?'⌘↵ 在 Finder 中显示':'DontsTool'}}if(flash)animate(list[selected],[{opacity:.65,transform:'translateY(2px)'},{opacity:1,transform:'translateY(0)'}],{duration:140,easing:'ease-out'});list[selected].scrollIntoView({block:'nearest',behavior:reduced()?'auto':'smooth'})}
select(scene==='02-search'?2:0);
function toast(message){clearTimeout(toastTimer);panel.querySelector('.dt-toast')?.remove();const el=document.createElement('div');el.className='dt-toast';el.setAttribute('role','status');el.setAttribute('aria-live','polite');el.innerHTML='<svg viewBox="0 0 20 20" fill="none" aria-hidden="true"><circle cx="10" cy="10" r="8" stroke="currentColor" stroke-width="1.5"/><path d="m6 10 2.5 2.5L14 7" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></svg>';el.append(document.createTextNode(message));panel.append(el);animate(el,[{opacity:0,translate:'0 5px'},{opacity:1,translate:'0 0'}],{duration:180,easing:'cubic-bezier(.16,1,.3,1)'});toastTimer=setTimeout(async()=>{await animate(el,[{opacity:1},{opacity:0}],{duration:140,easing:'ease-in'});el.remove()},1400)}
async function execute(row,secondary=false){if(!row||busy)return;
if(scene==='03-text-tools'){toast(secondary||rows.indexOf(row)===1?'演示：已复制压缩 JSON':'演示：已复制格式化 JSON');return}
if(scene==='04-translation'){if(rows.indexOf(row)===1){toast('演示：使用默认浏览器打开网页翻译');return}busy=true;const status=document.createElement('span');status.className='dt-busy';status.innerHTML='<i class="dt-spinner" aria-hidden="true"></i>翻译中…';status.setAttribute('role','status');row.append(status);setTimeout(()=>{status.remove();busy=false;toast('译文演示：保持好奇，继续创造。')},700);return}
if(scene==='02-search'&&secondary){if(rows.indexOf(row)>=2)toast('演示：在 Finder 中显示文件');return}
if(scene==='01-launcher'&&/JSON/.test(row.textContent)){navigate('03-text-tools');return}
if(scene==='01-launcher'&&/翻译/.test(row.textContent)){navigate('04-translation');return}
if(scene==='01-launcher'&&/UUID|Base64/.test(row.textContent)){toast('演示：已复制工具结果');return}
await close();parent.postMessage({type:'dt:closed'},location.origin==='null'?'*':location.origin)
}
rows.forEach((row,i)=>{row.addEventListener('click',e=>{e.preventDefault();e.stopImmediatePropagation();select(visible().indexOf(row),true);execute(row)},true);row.addEventListener('pointerenter',()=>{})});
panel.querySelectorAll('#clearBtn,#clear-btn').forEach(el=>el.addEventListener('click',e=>{e.preventDefault();e.stopImmediatePropagation();if(scene==='02-search'&&inputForClear()){const el=inputForClear();el.value='';el.dispatchEvent(new Event('input',{bubbles:true}));el.focus()}else close()},true));
function inputForClear(){return panel.querySelector('input[type=text],input[type=search]')}
window.addEventListener('keydown',e=>{if(e.isComposing)return;if(e.altKey&&e.code==='Space'){e.preventDefault();e.stopImmediatePropagation();hidden?enter():close();return}if((e.metaKey||e.ctrlKey)&&e.key===','){e.preventDefault();navigate('05-settings');return}if(e.key==='Escape'){e.preventDefault();e.stopImmediatePropagation();close()}else if((e.key==='ArrowDown'||e.key==='ArrowUp')&&rows.length&&!hidden){e.preventDefault();e.stopImmediatePropagation();select(selected+(e.key==='ArrowDown'?1:-1),true)}else if(e.key==='Enter'&&rows.length&&!hidden){e.preventDefault();e.stopImmediatePropagation();execute(visible()[selected],e.metaKey||e.ctrlKey)}},true);
const input=panel.querySelector('input[type=text],input[type=search],input:not([type])');
if(input){input.setAttribute('aria-label','搜索应用、文件或关键词');input.addEventListener('input',e=>{if(e.isComposing)return;const query=input.value.toLowerCase().trim();if(!['01-launcher','02-search'].includes(scene))return;rows.forEach(row=>{const match=!query||row.textContent.toLowerCase().includes(query);row.hidden=!match;row.style.display=match?'':'none'});new Set(rows.map(r=>r.parentElement)).forEach(group=>{const count=rows.filter(r=>r.parentElement===group&&!r.hidden).length;group.hidden=count===0;if(scene==='02-search'){const label=[...group.querySelectorAll('span')].find(el=>/^(应用|文件) · [0-9]+$/.test(el.textContent.trim()));if(label)label.textContent=label.textContent.trim().split(' · ')[0]+' · '+count}});panel.querySelector('.dt-empty')?.remove();if(!visible().length){const empty=document.createElement('div');empty.className='dt-empty';empty.textContent='没有找到结果 · 可继续调整关键词';(panel.querySelector('#results-container')||rows[0]?.parentElement.parentElement)?.append(empty)}visible().forEach((r,i)=>{if(!reduced())animate(r,[{opacity:0,transform:'translateY(3px)'},{opacity:1,transform:'translateY(0)'}],{duration:120,delay:Math.min(i*14,56),easing:'ease-out'})});select(0)})}
panel.querySelectorAll('[title*=设置],[aria-label*=Settings],[aria-label*=设置],#btn-settings').forEach(el=>el.addEventListener('click',e=>{e.preventDefault();e.stopImmediatePropagation();navigate('05-settings')},true));
if(scene==='05-settings'){
panel.querySelector('#closeBtn')?.addEventListener('click',close);

panel.querySelectorAll('[role=switch]').forEach(el=>{el.classList.add('dt-demo-switch');el.addEventListener('click',e=>{e.preventDefault();e.stopImmediatePropagation();el.setAttribute('aria-checked',String(el.getAttribute('aria-checked')!=='true'))},true)});
panel.querySelectorAll('button').forEach(el=>{if(el.textContent.includes('重新扫描'))el.addEventListener('click',e=>{e.preventDefault();e.stopImmediatePropagation();toast('演示：应用索引已更新')},true)});
}
window.addEventListener('message',e=>{if(e.source!==parent||e.origin!==location.origin)return;if(e.data?.type==='dt:replay')enter();if(e.data?.type==='dt:toggle')hidden?enter():close();if(e.data?.type==='dt:reduce'){forcedReduce=!!e.data.value;document.documentElement.classList.toggle('dt-reduce',forcedReduce);if(forcedReduce)panel.getAnimations().forEach(a=>a.cancel())}});
enter();if(input&&!hidden)input.focus({preventScroll:true});
parent.postMessage({type:'dt:ready',scene,rows:rows.length},location.origin==='null'?'*':location.origin)
}
if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',init);else init();
})();
