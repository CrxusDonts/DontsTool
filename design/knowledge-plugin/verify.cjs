const fs=require('fs');
const path=require('path');
const {chromium}=require('/Users/donts/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright');
(async()=>{
 const browser=await chromium.launch({headless:true});
 const page=await browser.newPage({viewport:{width:1280,height:1000}});
 const requests=[];const errors=[];
 await page.route(/^https?:/,route=>{requests.push(route.request().url());route.abort()});
 page.on('pageerror',e=>errors.push(e.message));
 const result={};
 for(const name of ['home','article']){
  await page.goto('file://'+path.join(__dirname,name+'.html'));
  result[name]=await page.evaluate(()=>({externalScripts:document.querySelectorAll('script[src]').length,brokenImages:[...document.images].filter(i=>!i.complete||i.naturalWidth===0).length,tableCount:document.querySelectorAll('table').length,codeBlocks:document.querySelectorAll('pre code').length,images:document.images.length,horizontalOverflow:document.documentElement.scrollWidth>innerWidth}));
 }
 await page.goto('file://'+path.join(__dirname,'index.html'));
 await page.getByRole('button',{name:'02 完整文章编辑'}).click();
 await page.frameLocator('iframe').getByRole('heading',{name:'编辑器与保存机制',exact:true}).waitFor();
 result.screenSwitch=await page.locator('iframe').getAttribute('src')==='article.html';
 await page.getByRole('button',{name:'01 知识库入口'}).click();
 const opened=page.waitForEvent('popup');
 await page.frameLocator('iframe').locator('main > div').first().dblclick();
 const popup=await opened;await popup.waitForLoadState();
 result.articleOpening=popup.url().endsWith('/article.html');
 await popup.close();
 await page.screenshot({path:path.join(__dirname,'preview.png'),fullPage:true});
 result.externalRequests=requests;result.errors=errors;
 fs.writeFileSync(path.join(__dirname,'verification.json'),JSON.stringify(result,null,2)+'\n');
 console.log(JSON.stringify(result));
 if(requests.length||errors.length||!result.articleOpening||!result.screenSwitch||Object.values(result).some(x=>x&&x.brokenImages))process.exitCode=1;
 await browser.close();
})().catch(e=>{console.error(e);process.exitCode=1});
