import test, { beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { JSDOM } from 'jsdom';
import { createNotesEditor } from '../src/editor.js';

const noteID = '11111111-1111-4111-8111-111111111111';
const otherID = '22222222-2222-4222-8222-222222222222';
const imagePath = 'assets/33333333-3333-4333-8333-333333333333.png';
let dom, app, messages;
beforeEach(() => {
  dom = new JSDOM('<main id="app"></main>', { url: `https://localhost/` });
  for (const key of ['window', 'document', 'navigator', 'HTMLElement', 'Element', 'Node', 'DOMParser', 'MutationObserver', 'getComputedStyle', 'FileReader']) {
    Object.defineProperty(globalThis, key, { configurable: true, value: key === 'getComputedStyle' ? dom.window.getComputedStyle.bind(dom.window) : dom.window[key] });
  }
  globalThis.requestAnimationFrame = callback => setTimeout(callback, 0);
  globalThis.cancelAnimationFrame = clearTimeout;
  messages = [];
  app = createNotesEditor(document.querySelector('#app'), message => messages.push(message));
  app.api.load({ noteID, content: { markdown: '' }, appearance: 'dark' });
});
afterEach(() => { app?.destroy(); dom?.window.close(); });

test('loads canonical formatting and owned images without a change echo', () => {
  const json = { type: 'doc', content: [{ type: 'heading', attrs: { level: 2 }, content: [{ type: 'text', text: '标题', marks: [{ type: 'bold' }] }] }, { type: 'image', attrs: { src: imagePath, alt: '截图' } }] };
  app.api.load({ noteID, content: { json: JSON.stringify(json), markdown: 'stale' }, appearance: 'light' });
  assert.equal(messages.filter(m => m.type === 'change').length, 0);
  assert.match(app.api.snapshot().markdown, /标题/);
  assert.match(app.api.snapshot().markdown, /assets\//);
  assert.equal(JSON.parse(app.api.snapshot().json).content[1].attrs.src, imagePath);
  assert.equal(document.querySelector('.tiptap img').getAttribute('src'), `donts-note://${noteID}/${imagePath}`);
  assert.equal(document.documentElement.dataset.appearance, 'light');
});

test('markdown roundtrips headings, lists, tasks, marks, quote, code and relative images', () => {
  const markdown = `# 标题\n\n**粗体** *斜体* ~~删除~~ [链接](https://example.com)\n\n> 引用\n\n- 第一项\n- 第二项\n\n1. 有序\n\n- [x] 完成\n\n\`\`\`js\nconst x = 1\n\`\`\`\n\n---\n\n![截图](${imagePath})`;
  app.api.load({ noteID, content: { markdown } });
  const before = app.api.snapshot();
  app.setMode('markdown');
  app.setMode('wysiwyg');
  assert.equal(app.api.snapshot().json, before.json);
  const types = [...app.api.snapshot().json.matchAll(/"type":"([^"]+)"/g)].map(match => match[1]);
  for (const type of ['heading', 'bold', 'italic', 'strike', 'link', 'blockquote', 'bulletList', 'orderedList', 'taskList', 'codeBlock', 'horizontalRule', 'image']) assert.ok(types.includes(type), type);
});

test('source edits are synchronously reflected and survive a mode switch', () => {
  app.setMode('markdown');
  const textarea = document.querySelector('textarea');
  textarea.value = '# 新标题\n\n**正文**';
  textarea.dispatchEvent(new window.Event('input'));
  assert.equal(app.api.snapshot().markdown, '# 新标题\n\n**正文**');
  assert.match(app.api.snapshot().plainText, /新标题/);
  app.setMode('wysiwyg');
  assert.equal(app.editor.getJSON().content[0].type, 'heading');
});

test('native image insertion maps its saved position and does not steal current cursor; undo works', async () => {
  app.editor.commands.insertContent('AB');
  app.editor.commands.setTextSelection(2);
  app.requestFiles([new window.File(['png'], 'one.png', { type: 'image/png' })]);
  await new Promise(resolve => setTimeout(resolve, 25));
  const message = messages.find(m => m.type === 'importImage');
  assert.ok(message?.base64);
  app.editor.commands.insertContentAt(1, 'X', { updateSelection: false });
  app.editor.commands.setTextSelection(1);
  app.api.insertImage({ token: message.token, src: imagePath, alt: 'one' });
  assert.equal(app.editor.state.selection.from, 1);
  assert.match(app.api.snapshot().json, /"image"/);
  assert.ok(app.editor.commands.undo());
  assert.doesNotMatch(app.api.snapshot().json, /"image"/);
});

test('native paste acknowledgement keeps the original bookmark and inserts in order', () => {
  app.editor.commands.insertContent('AB');
  app.editor.commands.setTextSelection(2);
  app.requestPaste({ html: '', text: 'fallback' });
  const { token } = messages.find(m => m.type === 'paste');
  app.editor.commands.setTextSelection(1);
  app.api.resolvePaste({ token, handled: true, images: [{ src: imagePath, alt: 'first' }, { src: imagePath, alt: 'second' }] });
  const images = JSON.parse(app.api.snapshot().json).content.filter(n => n.type === 'image');
  assert.deepEqual(images.map(n => n.attrs.alt), ['first', 'second']);
  assert.equal(app.editor.state.selection.from, 1);
});

test('image-only clipboard HTML prefers native pixels and ignores hidden script text', () => {
  app.requestPaste({ html: '<html><head><style>body { color: red }</style><meta name="x" content="metadata"></head><body> \n<script>ignored()</script><img src="https://example.com/image.png" alt="替代文字"></body></html>', text: 'https://example.com/image.png' });
  const paste = messages.find(message => message.type === 'paste');
  assert.equal(paste.preferNativeImage, true);
  app.api.resolvePaste({ token: paste.token, handled: true, images: [{ src: imagePath }] });
  assert.match(app.api.snapshot().json, /"image"/);
  assert.equal(messages.some(message => message.type === 'error'), false);
});

test('mixed clipboard HTML keeps text priority over native pixels', () => {
  app.requestPaste({ html: '<p>保留正文<img src="https://example.com/image.png"></p>', text: '保留正文' });
  const paste = messages.find(message => message.type === 'paste');
  assert.equal(paste.preferNativeImage, false);
});

test('clipboard image preference is bounded and requires an image when HTML is present', () => {
  app.requestPaste({ html: '', text: 'plain' });
  app.requestPaste({ html: '<p> </p>', text: '' });
  app.requestPaste({ html: `<p>${' '.repeat(1024 * 1024)}<img src="https://example.com/image.png"></p>`, text: '' });
  assert.deepEqual(messages.filter(message => message.type === 'paste').map(message => message.preferNativeImage), [true, false, false]);
});

test('HTML paste preserves text, strips scripts/external images and copies cross-note assets', () => {
  app.requestPaste({ html: `<p>before<strong>bold</strong><script>danger()</script><img src="https://example.com/track.png"><img src="donts-note://${otherID}/${imagePath}" alt="owned">after</p>`, text: '' });
  const paste = messages.find(m => m.type === 'paste');
  app.api.resolvePaste({ token: paste.token, handled: false });
  const copy = messages.find(m => m.type === 'copyImage');
  assert.equal(copy.sourceNoteID, otherID);
  assert.equal(copy.relativePath, imagePath);
  app.api.insertImage({ token: copy.token, src: imagePath, alt: 'owned' });
  const snapshot = app.api.snapshot();
  assert.match(snapshot.plainText, /beforebold/);
  assert.match(snapshot.plainText, /after/);
  assert.doesNotMatch(snapshot.json, /danger|https:\/\/example.com\/track|data:/);
  assert.ok(messages.some(m => m.type === 'error' && /外部图片/.test(m.message)));
});

test('unsafe source images keep the unsaved source and block snapshot until corrected', () => {
  app.setMode('markdown');
  const textarea = document.querySelector('textarea');
  textarea.value = '正文 ![remote](https://example.com/image.png)';
  textarea.dispatchEvent(new window.Event('input'));
  assert.throws(() => app.api.snapshot(), /图片/);
  assert.equal(app.setMode('wysiwyg'), false);
  assert.match(textarea.value, /remote/);
});

test('loading another note cancels stale asynchronous imports', () => {
  app.requestPaste({ html: '', text: 'stale' });
  const paste = messages.find(m => m.type === 'paste');
  app.api.load({ noteID: otherID, content: { markdown: 'fresh' } });
  app.api.resolvePaste({ token: paste.token, handled: true, images: [{ src: imagePath }] });
  assert.equal(app.api.snapshot().plainText, 'fresh');
});

test('source conversion preserves angle brackets in code and refuses raw HTML', () => {
  app.api.load({ noteID, content: { markdown: '```ts\nconst node: Array<T> = []\n```\n\n`<span>`' } });
  assert.match(app.api.snapshot().plainText, /Array<T>/);
  assert.match(app.api.snapshot().plainText, /<span>/);
  app.setMode('markdown');
  assert.equal(document.querySelector('textarea').readOnly, false);
  document.querySelector('textarea').value = '<script>alert(1)</script>';
  document.querySelector('textarea').dispatchEvent(new window.Event('input'));
  assert.throws(() => app.api.snapshot(), /HTML/);
});

test('formats that Markdown cannot represent remain intact and source is read-only', () => {
  app.api.load({ noteID, content: { json: JSON.stringify({ type: 'doc', content: [{ type: 'image', attrs: { src: imagePath, width: 220, alt: '固定宽度图片' } }] }) } });
  const original = app.api.snapshot().json;
  assert.equal(app.setMode('markdown'), true);
  assert.equal(document.querySelector('textarea').readOnly, true);
  assert.equal(app.api.snapshot().json, original);
  app.setMode('wysiwyg');
  assert.equal(app.api.snapshot().json, original);
});

test('multi-file imports preserve requested order when native acknowledgements arrive reversed', async () => {
  app.requestFiles([new window.File(['a'], 'one.png', { type: 'image/png' }), new window.File(['b'], 'two.png', { type: 'image/png' })]);
  await new Promise(resolve => setTimeout(resolve, 25));
  const imports = messages.filter(m => m.type === 'importImage');
  app.api.insertImage({ token: imports[1].token, src: imagePath, alt: 'second' });
  assert.throws(() => app.api.snapshot(), /正在导入/);
  app.api.insertImage({ token: imports[0].token, src: imagePath, alt: 'first' });
  assert.deepEqual(JSON.parse(app.api.snapshot().json).content.filter(n => n.type === 'image').map(n => n.attrs.alt), ['first', 'second']);
});

test('native read-only mode disables editing and preserves content', () => {
  app.api.setEditable(false);
  assert.equal(app.editor.isEditable, false);
  assert.equal(document.querySelector('[data-action="bold"]').disabled, true);
  app.api.setEditable(true);
  assert.equal(app.editor.isEditable, true);
});

test('native reload resets undo history instead of restoring previous note content', () => {
  app.editor.commands.insertContent('old secret');
  app.api.load({ noteID: otherID, content: { markdown: 'fresh' } });
  app.editor.commands.undo();
  assert.equal(app.api.snapshot().plainText, 'fresh');
});

test('unsupported source tables remain visible and block lossy conversion', () => {
  app.setMode('markdown');
  document.querySelector('textarea').value = '| A | B |\n| --- | --- |\n| one | two |';
  document.querySelector('textarea').dispatchEvent(new window.Event('input'));
  assert.throws(() => app.api.snapshot(), /表格/);
  assert.equal(app.setMode('wysiwyg'), false);
});

test('rich data image imports never persist base64 and retain the original alt text', () => {
  app.requestPaste({ html: '<p>before<img src="data:image/png;base64,YQ==" alt="图片说明">after</p>', text: '' });
  app.api.resolvePaste({ token: messages.find(m => m.type === 'paste').token, handled: false });
  const image = messages.find(m => m.type === 'importImage');
  assert.equal(image.base64, 'YQ==');
  assert.throws(() => app.api.snapshot(), /正在导入/);
  app.api.insertImage({ token: image.token, src: imagePath });
  const content = JSON.parse(app.api.snapshot().json).content;
  assert.deepEqual(content.map(n => n.type), ['paragraph', 'image', 'paragraph']);
  assert.equal(content[1].attrs.alt, '图片说明');
  assert.doesNotMatch(app.api.snapshot().json, /base64|YQ==/);
});

test('unsupported original image formats are rejected before import', () => {
  app.requestFiles([new window.File(['tiff'], 'original.tiff', { type: 'image/tiff' })]);
  assert.equal(messages.filter(message => message.type === 'importImage').length, 0);
  assert.ok(messages.some(message => message.type === 'error' && /PNG、JPEG、GIF/.test(message.message)));
  assert.equal(app.api.snapshot().plainText, '');
});

test('public snapshot exposes its change revision and protects unfinished source composition', () => {
  app.editor.commands.insertContent('正文');
  const change = messages.filter(message => message.type === 'change').at(-1);
  assert.equal(app.api.snapshot().revision, change.revision);
  assert.equal(change.content.revision, undefined);
  app.setMode('markdown');
  const source = document.querySelector('textarea');
  source.dispatchEvent(new window.CompositionEvent('compositionstart'));
  assert.throws(() => app.api.snapshot(), /输入法/);
  source.dispatchEvent(new window.CompositionEvent('compositionend'));
  assert.equal(app.api.snapshot().plainText, '正文');
});
