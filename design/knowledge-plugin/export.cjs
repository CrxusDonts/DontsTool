const fs = require('fs');
const path = require('path');
const { chromium } = require('/Users/donts/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright');
const root = __dirname;
async function main() {
  const browser = await chromium.launch({headless:true});
  const page = await browser.newPage({viewport:{width:1160,height:900},deviceScaleFactor:1});
  for (const name of ['home','article']) {
    let html = fs.readFileSync(path.join(root,'original',name+'.html'),'utf8');
    const fontLinks=[...html.matchAll(/<link[^>]+href="([^"]*fonts\.googleapis[^\"]*)"[^>]*>/g)];
    for(const link of fontLinks){
      if(!link[1].includes('Material+Symbols')){html=html.replace(link[0],'');continue;}
      let css=await (await page.request.get(link[1].replaceAll('&amp;','&'))).text();
      for(const match of [...css.matchAll(/url\((https[^)]+)\)/g)]){
        const asset=await (await page.request.get(match[1])).body();
        css=css.replaceAll(match[1],'data:font/woff2;base64,'+asset.toString('base64'));
      }
      html=html.replace(link[0],'<style>'+css+'</style>');
    }
    html=html.replace(/<link[^>]+fonts\.gstatic[^>]*>/g,'');
    html=html.replace(/src="https:\/\/lh3\.googleusercontent\.com\/[^\"]+"/g,'src="data:image/svg+xml;base64,'+fs.readFileSync(path.join(root,'original','article-flow.svg')).toString('base64')+'"');
    html = html.replaceAll('API就绪','DontsKb').replaceAll('v1.4.2','').replaceAll('Tiptap 核心已就绪','').replaceAll('UTF-8','');
    const copy = {
      'DontsTool 知识助手插件直接挂接知识库底层的编辑服务。在本地触发搜索或快捷呼出时，系统直接在原生 macOS 独立窗口内拉起富文本编辑管线，彻底杜绝切换浏览器标签页打断思路的高昂成本。':'从 DontsTool 搜索文章，打开独立窗口继续阅读和编辑。文章窗口复用知识库现有编辑器，正文占据主要空间。',
      '该窗口拥有轻量化进程沙箱，既保持了与云端实时协同文档的数据一致性，同时确保本地离线草稿、输入缓冲区以及附件预览链路完整映射。':'接入时保留知识库的结构化内容、附件与保存保护。窗口标题显示文章名称，保存状态跟随真实编辑状态变化。',
      '原生视图对富文本复合节点进行逐项校验，保证多源格式在双向序列化时语义完全对称：':'表格、代码块和图片继续在同一正文中编辑，沿用知识库已有的数据结构：',
      '行列编辑、合并单元格':'行列编辑',
      '保留完整 HTML/Markdown 结构':'保留结构',
      '语法高亮、换行制表符保留':'语法高亮',
      '保留语言标识符与原始缩进':'保留语言与缩进',
      '预览、居中对齐与比例缩放':'预览与缩放',
      '引用原附件哈希指针，免重新上传':'引用原附件',
      '编辑器采用乐观并发（Optimistic Local Drafting）结合版本序列检测。每次按键变更先进入本地原子事务栈，随后在静默防抖窗口期提交远程同步：':'保存沿用知识库现有流程，并基于读取时的版本检查变更。以下代码仅表达保存所需的内容与版本：',
      '如检测到服务器存在更高版本的冲突，窗口工具栏会立即切换为冲突防护指示，并提供侧向差异比对方案。当未保存改动仍驻留本地时，强制关闭窗口将唤起标准系统的确认防丢提示弹窗。':'接入时沿用现有版本冲突处理与未保存内容保护。保存失败应保留正文，并在窗口内给出可继续操作的提示。',
      'sync-service.ts':'保存示例',
      '已与云端同步':'文章',
      '连接就绪':'',
      'Markdown 与 JSON Schema 混合渲染规格，支持代码块语言高亮与本地二进制缓存。':'表格、代码块与图片在同一篇文章中保存，保留原有结构与附件引用。',
      '采用平铺层级与空间树混合结构，通过全局唯一短 ID 保证跨工具引用不断裂。':'整理知识库、目录和文章之间的关系，让内容更容易查找与引用。'
    };
    for(const [before,after] of Object.entries(copy))html=html.replaceAll(before,after);
    html=html.replace(/Markdown 与 JSON Schema[^<]+/g,'表格、代码块与图片保留原有结构与附件引用。');
    html = html.replace(/<\/head>/, `<style id="export-overrides">
      :root {color-scheme:light}
      body {background:#d9d8d2!important;font-family:-apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif!important;min-height:100vh!important}
      body * {font-family:inherit}
      code,pre,.font-mono {font-family:ui-monospace,"SFMono-Regular",Menlo,monospace!important}
      button:focus-visible,a:focus-visible,input:focus-visible{outline:2px solid #18786f;outline-offset:2px}
      @media(prefers-reduced-motion:reduce){*{transition:none!important;animation:none!important}}
    </style></head>`);
    await page.setContent(html,{waitUntil:'networkidle'});
    await page.waitForFunction(()=>[...document.querySelectorAll('style')].some(s=>s.textContent.includes('--tw-')),{timeout:20000});
    await page.evaluate(() => {
      document.querySelectorAll('script').forEach(s=>s.remove());
      const viewport=document.querySelector('body > div');
      if(viewport) viewport.id='desktop-preview';
    });
    html=await page.content();
    const interaction=name==='home'?`<script>
      document.querySelectorAll('main > div').forEach(row=>{row.tabIndex=0;row.setAttribute('role','link');row.addEventListener('dblclick',()=>window.open('article.html','_blank'));row.addEventListener('keydown',e=>{if(e.key==='Enter')window.open('article.html','_blank')})});
      document.querySelectorAll('main button').forEach(button=>button.addEventListener('click',()=>window.open('article.html','_blank')));
      const input=document.querySelector('input');if(input)document.addEventListener('keydown',e=>{if(e.metaKey&&e.key==='k'){e.preventDefault();input.focus()}});
    </script>`:'';
    html=html.replace('</body>',interaction+'</body>');
    fs.writeFileSync(path.join(root,name+'.html'),html);
    await page.goto('file://'+path.join(root,name+'.html'),{waitUntil:'load'});
    await page.screenshot({path:path.join(root,name+'.png'),fullPage:true});
    console.log(name,JSON.stringify(await page.evaluate(()=>({width:innerWidth,scrollWidth:document.documentElement.scrollWidth,externalScripts:document.querySelectorAll('script[src]').length,headings:[...document.querySelectorAll('h1,h2')].map(x=>x.textContent.trim())}))));
  }
  await browser.close();
}
main().catch(e=>{console.error(e);process.exitCode=1});
