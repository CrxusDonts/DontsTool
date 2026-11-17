# 本地便笺编辑器

Tiptap 3.34.0、ProseMirror 和 Markdown 扩展全部离线打包。富文本 JSON 是正文权威，Markdown 是投影。原生窗口负责标题、保存、附件和导出。

```sh
cd Web/NotesEditor
npm ci
npm run build
npm test
```

构建输出到 `Resources/NotesEditor`，包含 `index.html`、`editor.js`、`editor.css` 和按实际 bundle 收集的 `THIRD_PARTY_NOTICES.txt`。没有开发服务器、CDN 或外部字体。所有直接依赖均锁定版本，`package-lock.json` 锁定完整依赖树。

## 原生 API

页面加载完成后发送 `{type:'ready',version:1}`。原生随后调用：

```js
window.dontsNote.load({
  noteID: '11111111-1111-4111-8111-111111111111',
  content: { json: '{"type":"doc","content":[{"type":"paragraph"}]}', markdown: '', plainText: '' },
  appearance: 'dark',
})
window.dontsNote.snapshot() // 同步返回 {json:string, markdown:string, plainText:string, revision:number}
window.dontsNote.setAppearance('light')
window.dontsNote.setEditable(false)
window.dontsNote.focus()
```

`json` 非空时优先，缺失时才解析 `markdown`。`load` 不回发 `change`，并取消旧图片请求、清除旧撤销历史。普通编辑及每次合法源码输入都发送 `{type:'change',revision,content}`，revision 在页面内单调增加。公开快照也携带同级 revision，内部 change.content 仍只有正文三个字段。原生关闭时在同一 JS 调用内先成功取得 snapshot，再 setEditable(false)，冻结后落盘；写入失败恢复编辑。输入法仍在组词时快照抛错，保留窗口等待确认输入。

源码不改动时保留原 JSON。Markdown 无法完整表达当前 JSON 的格式时，源码只读并说明原因。编辑源码中的原始 HTML、外部图片和不支持的表格会保留原文并提示；`snapshot()` 抛错，禁止切回正文，原生应保留窗口供修正。图片或粘贴请求未完成时，公开 `snapshot()` 也抛错，避免关闭时丢掉待导入内容；内部 `change` 仍保存现有文字。

## 图片与粘贴

JS 只向 `window.webkit.messageHandlers.dontsNote.postMessage` 发消息：

- `paste {token,preferNativeImage}`：原生检查剪贴板。无 HTML，或不超过 1M 字符的 HTML 仅含图片而没有实际正文时，`preferNativeImage:true`，原生可优先使用同一剪贴板的 PNG/TIFF 像素；检测在未挂入页面的 DOM 中进行，忽略 script/style/meta。混合正文与图片时为 false，优先走保存的 HTML，保留文字位置。纯图片成功回 `resolvePaste({token,handled:true,images:[{src,alt?}]})`；没有可用原生像素、富文本或普通文字时回 `resolvePaste({token,handled:false})`，JS 使用事先保存的 HTML/text。
- `importImage {token,base64,mime}`：拖入、文件选择器或富文本里的 data 图片。原生验证并保存后回 `insertImage({token,src,alt?})`。
- `copyImage {token,sourceNoteID,relativePath}`：跨便笺的自有图片。原生复制所有权后同样回 `insertImage`。
- 所有图片请求失败均可回 `resolvePaste({token,handled:true,error:'可读错误'})`。图片请求也接受 `resolvePaste({token,handled:true,images:[{src,alt?}]})`。
- `openLink {url}`：仅用户点击 http/https/mailto 链接触发；原生打开浏览器。
- `error {message}`：可读错误，页面同时显示提示。

回包 `src` 必须是 `assets/<UUID>.<扩展名>`。JSON/Markdown 永远保存相对引用；编辑 DOM 的图片地址是 `donts-note://<noteID>/assets/...`，供跨便笺复制识别所有权。外部图片、原文件路径和 base64 不进入正文。富 HTML 先经过标签/属性白名单与 ProseMirror schema，再插入；脚本移除。图片先由原生保存再插入，多个异步回包保持原请求顺序，书签随文档交易映射，不抢当前光标。撤销插图不删除原生附件。

测试使用真实 Tiptap/ProseMirror 与 jsdom，覆盖格式与图片引用、源码保护、异步书签/顺序/撤销、粘贴清理和生成 bundle 启动。真实中文输入法、WebKit scheme/CSP 和系统剪贴板由原生集成验收覆盖。
