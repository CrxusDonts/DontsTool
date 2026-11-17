import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { JSDOM } from 'jsdom';

const resources = new URL('../../../Resources/NotesEditor/', import.meta.url);
test('committed offline bundle boots the native API with local resources and restrictive CSP', async () => {
  const html = await readFile(new URL('index.html', resources), 'utf8');
  const bundle = await readFile(new URL('editor.js', resources), 'utf8');
  assert.match(html, /default-src 'none'/);
  assert.match(html, /connect-src 'none'/);
  assert.match(html, /img-src 'self'/);
  assert.doesNotMatch(html, /https?:\/\//);
  const dom = new JSDOM(html, { runScripts: 'outside-only', pretendToBeVisual: true, url: 'donts-note://11111111-1111-4111-8111-111111111111/index.html' });
  try {
    const messages = [];
    dom.window.webkit = { messageHandlers: { dontsNote: { postMessage: message => messages.push(message) } } };
    dom.window.structuredClone = structuredClone;
    dom.window.eval(bundle);
    for (const name of ['load', 'snapshot', 'insertImage', 'resolvePaste', 'setAppearance', 'setEditable', 'focus']) assert.equal(typeof dom.window.dontsNote[name], 'function', name);
    assert.equal(messages[0].type, 'ready');
    assert.equal(messages[0].version, 1);
    dom.window.dontsNote.load({ noteID: '11111111-1111-4111-8111-111111111111', content: { markdown: '# 离线便笺' }, appearance: 'light' });
    assert.equal(dom.window.dontsNote.snapshot().plainText, '离线便笺');
    assert.equal(messages.filter(message => message.type === 'change').length, 0);
    const css = await readFile(new URL('editor.css', resources), 'utf8');
    assert.match(css, /#18181a/);
    assert.match(css, /#fafafb/);
    const notices = await readFile(new URL('THIRD_PARTY_NOTICES.txt', resources), 'utf8');
    assert.match(notices, /@tiptap\/core@3\.34\.0/);
    assert.match(notices, /prosemirror-view/);
  } finally { dom.window.close(); }
});
