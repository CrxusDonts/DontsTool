import { Editor, mergeAttributes } from '@tiptap/core';
import StarterKit from '@tiptap/starter-kit';
import Image from '@tiptap/extension-image';
import TaskList from '@tiptap/extension-task-list';
import TaskItem from '@tiptap/extension-task-item';
import { Markdown } from '@tiptap/markdown';
import { DOMParser as PMDOMParser, Slice } from '@tiptap/pm/model';
import { closeHistory } from '@tiptap/pm/history';
import { EditorState } from '@tiptap/pm/state';

const UUID = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';
const uuidPattern = new RegExp(`^${UUID}$`, 'i');
const assetPattern = new RegExp(`^assets/${UUID}\\.(png|jpg|gif|webp)$`, 'i');
const ownedPattern = new RegExp(`^donts-note://(${UUID})/(assets/${UUID}\\.(?:png|jpg|gif|webp))$`, 'i');
const imageMimes = new Set(['image/png', 'image/jpeg', 'image/gif', 'image/webp']);
const safeLink = value => /^(https?:|mailto:)/i.test(value || '') && !/[\u0000-\u0020]/.test(value);
const emptyDoc = () => ({ type: 'doc', content: [{ type: 'paragraph' }] });

function ownedImage(src, noteID) {
  if (typeof src !== 'string') return null;
  if (assetPattern.test(src)) return { sourceNoteID: noteID, relativePath: src };
  const match = src.match(ownedPattern);
  return match ? { sourceNoteID: match[1].toLowerCase(), relativePath: match[2] } : null;
}

function canonicalize(json, noteID) {
  const node = structuredClone(json);
  function visit(value) {
    if (value.type === 'image') {
      const owned = ownedImage(value.attrs?.src, noteID);
      if (!owned || owned.sourceNoteID !== noteID) throw new Error('图片必须先导入当前便笺，请粘贴或拖入图片。');
      value.attrs.src = owned.relativePath;
    }
    if (value.marks) value.marks = value.marks.filter(mark => mark.type !== 'link' || safeLink(mark.attrs?.href));
    value.content?.forEach(visit);
  }
  visit(node);
  return node;
}

function comparable(json) {
  return JSON.stringify(json, (key, value) => {
    if (value === null || value === undefined) return undefined;
    if (key === 'attrs' && Object.values(value).every(item => item == null)) return undefined;
    return value;
  });
}

function preferNativeImage(html) {
  if (!html) return true;
  if (html.length > 1024 * 1024) return false;
  const inert = new DOMParser().parseFromString(html, 'text/html');
  inert.querySelectorAll('script,style,meta').forEach(element => element.remove());
  return !!inert.body.querySelector('img') && !inert.body.textContent.trim();
}

export function createNotesEditor(root, postMessage = message => window.webkit?.messageHandlers?.dontsNote?.postMessage(message)) {
  let noteID = '', revision = 0, suppress = false, mode = 'wysiwyg';
  let sourceBaseline = '', sourceError = null, sourceReadOnly = false, composing = false;
  let tokenCounter = 0;
  const pending = new Map();
  const token = () => `${Date.now().toString(36)}-${++tokenCounter}`;
  const send = message => postMessage(message);
  root.innerHTML = `<div class="editor-toolbar" role="toolbar" aria-label="正文格式"><div class="format-tools"></div><details class="more-tools"><summary aria-label="更多格式">•••</summary><div class="overflow-tools"></div></details><div class="mode-switch" role="group" aria-label="编辑模式"><button type="button" data-mode="wysiwyg" aria-pressed="true">正文</button><button type="button" data-mode="markdown" aria-pressed="false">Markdown</button></div></div><div class="editor-message" role="status" aria-live="polite" hidden></div><div class="editor-content"></div><textarea class="markdown-source" aria-label="Markdown 源码" spellcheck="false" hidden></textarea><input type="file" class="image-picker" accept="image/png,image/jpeg,image/gif,image/webp" multiple hidden>`;
  const surface = root.querySelector('.editor-content');
  const source = root.querySelector('textarea');
  const notice = root.querySelector('.editor-message');
  const toolbar = root.querySelector('.editor-toolbar');
  const picker = root.querySelector('input');
  const show = message => { notice.textContent = message; notice.hidden = !message; };
  const fail = error => { const message = error?.message || String(error); show(message); send({ type: 'error', message }); };

  const ManagedImage = Image.extend({
    addAttributes() {
      return {
        ...this.parent?.(),
        src: {
          default: null,
          parseHTML: element => ownedImage(element.getAttribute('src'), noteID)?.relativePath ?? null,
          renderHTML: attrs => ({ src: assetPattern.test(attrs.src || '') ? `donts-note://${noteID}/${attrs.src}` : '' }),
        },
      };
    },
    parseHTML() { return [{ tag: 'img[src]', getAttrs: element => ownedImage(element.getAttribute('src'), noteID) ? null : false }]; },
    renderHTML({ HTMLAttributes }) { return ['img', mergeAttributes(this.options.HTMLAttributes, HTMLAttributes)]; },
    addInputRules() { return []; },
  });

  const editor = new Editor({
    element: surface,
    extensions: [StarterKit.configure({ link: { openOnClick: false, autolink: false, linkOnPaste: false, isAllowedUri: safeLink }, trailingNode: false }), ManagedImage, TaskList, TaskItem.configure({ nested: true }), Markdown],
    content: emptyDoc(),
    editorProps: {
      attributes: { 'aria-label': '便笺正文', 'data-placeholder': '写点什么，或粘贴一张截图…', spellcheck: 'false' },
      handlePaste(view, event) {
        event.preventDefault();
        if (view.composing) { show('请先完成当前输入，再粘贴内容。'); return true; }
        requestPaste({ html: event.clipboardData?.getData('text/html') || '', text: event.clipboardData?.getData('text/plain') || '', files: Array.from(event.clipboardData?.files || []) });
        return true;
      },
      handleDrop(view, event, slice, moved) {
        if (moved) return false;
        const files = Array.from(event.dataTransfer?.files || []);
        if (!files.length) { event.preventDefault(); fail(new Error('请拖入图片文件；链接和其他文件不能作为附件。')); return true; }
        event.preventDefault();
        const position = view.posAtCoords({ left: event.clientX, top: event.clientY })?.pos;
        requestFiles(files, position == null ? undefined : { from: position, to: position });
        return true;
      },
      handleDOMEvents: {
        compositionstart() { composing = true; return false; },
        compositionend() { composing = false; return false; },
        click(view, event) {
          const anchor = event.target.closest?.('a[href]');
          if (!anchor) return false;
          event.preventDefault();
          const url = anchor.getAttribute('href');
          if (safeLink(url)) send({ type: 'openLink', url });
          return true;
        },
      },
    },
    onTransaction({ transaction }) {
      if (!transaction.docChanged) return;
      for (const operation of pending.values()) {
        operation.range = { from: transaction.mapping.map(operation.range.from, 1), to: transaction.mapping.map(operation.range.to, 1) };
      }
    },
    onUpdate() {
      if (!suppress) emitChange();
      updateToolbar();
    },
    onSelectionUpdate() { updateToolbar(); },
  });

  function contentSnapshot() {
    if (sourceError) throw sourceError;
    const json = canonicalize(editor.getJSON(), noteID);
    return { json: JSON.stringify(json), markdown: mode === 'markdown' && !sourceReadOnly ? source.value : editor.getMarkdown(), plainText: editor.getText() };
  }
  function snapshot() {
    if (composing || editor.view.composing) throw new Error('输入法仍在组词，请完成输入后重试。');
    if (pending.size) throw new Error('图片或粘贴内容正在导入，请稍后重试。');
    return { ...contentSnapshot(), revision };
  }
  function emitChange() {
    try { send({ type: 'change', revision: ++revision, content: contentSnapshot() }); }
    catch (error) { fail(error); }
  }
  function parseMarkdown(value) {
    const contains = (tokens, type) => tokens?.some(item => item.type === type || contains(item.tokens, type) || contains(item.items, type));
    const tokens = editor.markdown.instance.lexer(value);
    if (contains(tokens, 'html')) throw new Error('源码不支持原始 HTML；请使用 Markdown 格式，或把代码放入代码块。');
    if (contains(tokens, 'table')) throw new Error('暂不支持表格，请改成段落或列表后再保存。');
    const parsed = canonicalize(editor.markdown.parse(value), noteID);
    return parsed.content?.length ? parsed : emptyDoc();
  }
  function setMode(next) {
    if (next === mode) return true;
    if (composing || editor.view.composing) return false;
    if (pending.size) { show('图片正在导入，请完成后再切换编辑模式。'); return false; }
    if (next === 'markdown') {
      sourceBaseline = editor.getMarkdown();
      source.value = sourceBaseline;
      try { sourceReadOnly = comparable(editor.schema.nodeFromJSON(parseMarkdown(sourceBaseline)).toJSON()) !== comparable(editor.getJSON()); }
      catch { sourceReadOnly = true; }
      source.readOnly = sourceReadOnly || !editor.isEditable;
      show(sourceReadOnly ? '这篇便笺包含 Markdown 无法完整表达的格式，源码只读；请在正文中继续编辑。' : '');
    } else if (sourceError) { fail(sourceError); return false; }
    mode = next;
    surface.hidden = mode === 'markdown';
    source.hidden = mode !== 'markdown';
    toolbar.dataset.mode = mode;
    for (const button of toolbar.querySelectorAll('[data-mode]')) button.setAttribute('aria-pressed', String(button.dataset.mode === mode));
    for (const button of toolbar.querySelectorAll('[data-action]')) button.disabled = mode === 'markdown' || !editor.isEditable;
    if (mode === 'markdown') source.focus(); else editor.commands.focus();
    return true;
  }
  source.addEventListener('input', () => {
    if (sourceReadOnly || !editor.isEditable) return;
    try {
      const doc = parseMarkdown(source.value);
      sourceError = null;
      suppress = true;
      editor.commands.setContent(doc, { emitUpdate: false });
      suppress = false;
      show('');
      emitChange();
    } catch (error) { sourceError = error; suppress = false; fail(error); }
  });
  source.addEventListener('compositionstart', () => { composing = true; });
  source.addEventListener('compositionend', () => { composing = false; });

  function bookmark(range) { return range || { from: editor.state.selection.from, to: editor.state.selection.to }; }
  function addPending(range, extra = {}) {
    const id = token();
    pending.set(id, { range: { ...bookmark(range) }, ...extra });
    return id;
  }
  function insertAt(range, content) {
    editor.view.dispatch(closeHistory(editor.state.tr));
    editor.commands.insertContentAt(range, content, { updateSelection: false });
    editor.view.dispatch(closeHistory(editor.state.tr));
  }
  function drain(group) {
    while (group.length && group[0].result) {
      const item = group.shift();
      const operation = pending.get(item.token);
      if (!operation) continue;
      pending.delete(item.token);
      if (item.result.error) { fail(new Error(item.result.error)); continue; }
      const images = item.result.images || [];
      try {
        const nodes = images.map(image => canonicalize({ type: 'image', attrs: { src: image.src, alt: image.alt ?? operation.alt ?? '' } }, noteID));
        if (nodes.length) insertAt(operation.range, nodes);
      } catch (error) { fail(error); }
    }
  }
  function complete(id, result) {
    const operation = pending.get(id);
    if (!operation) return;
    operation.item.result = result;
    drain(operation.group);
  }
  function imageOperation(range, group, payload, alt) {
    const item = {};
    const id = addPending(range, { group, item, alt });
    item.token = id;
    group.push(item);
    send({ ...payload, token: id });
    return id;
  }
  function readFile(file) {
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onerror = () => reject(new Error('无法读取图片，请重试。'));
      reader.onload = () => resolve(String(reader.result).split(',')[1]);
      reader.readAsDataURL(file);
    });
  }
  function requestFiles(files, range) {
    if (!editor.isEditable) return;
    if (mode === 'markdown') { fail(new Error('请切换到正文后插入图片。')); return; }
    const group = [];
    for (const file of files) {
      if (!imageMimes.has(file.type)) { fail(new Error(`无法插入“${file.name}”：支持 PNG、JPEG、GIF 和 WebP 图片。`)); continue; }
      if (file.size > 20 * 1024 * 1024) { fail(new Error('图片超过 20 MB，请缩小后再插入。')); continue; }
      const item = {};
      const id = addPending(range, { group, item });
      item.token = id;
      group.push(item);
      readFile(file).then(base64 => {
        if (pending.has(id)) send({ type: 'importImage', token: id, base64, mime: file.type });
      }).catch(error => complete(id, { error: error.message }));
    }
  }
  function requestPaste(fallback) {
    if (!editor.isEditable) return;
    const id = addPending(undefined, { fallback });
    send({ type: 'paste', token: id, preferNativeImage: preferNativeImage(fallback.html) });
    return id;
  }

  function pasteHTML(range, html) {
    const parsed = new DOMParser().parseFromString(html, 'text/html');
    parsed.querySelectorAll('script,style,iframe,object,embed,link,meta,svg,math,video,audio,source,form,input,button').forEach(element => element.remove());
    const imports = new Map();
    let rejected = false;
    for (const element of parsed.body.querySelectorAll('*')) {
      for (const attribute of Array.from(element.attributes)) {
        if (!['src', 'alt', 'title', 'href', 'data-type', 'data-checked', 'start'].includes(attribute.name)) element.removeAttribute(attribute.name);
      }
      if (element.tagName === 'A' && !safeLink(element.getAttribute('href'))) element.removeAttribute('href');
      if (element.tagName !== 'IMG') continue;
      const src = element.getAttribute('src') || '';
      const owned = ownedImage(src, noteID);
      const data = src.match(/^data:(image\/(?:png|jpeg|gif|webp));base64,([A-Za-z0-9+/=\s]+)$/i);
      if (owned?.sourceNoteID === noteID) { element.setAttribute('src', owned.relativePath); continue; }
      if (!owned && !data) { element.remove(); rejected = true; continue; }
      if (data && data[2].length > 28 * 1024 * 1024) { element.remove(); rejected = true; continue; }
      const temporary = `assets/${globalThis.crypto.randomUUID()}.png`;
      imports.set(temporary, owned ? { type: 'copyImage', ...owned } : { type: 'importImage', mime: data[1].toLowerCase(), base64: data[2].replace(/\s/g, '') });
      element.setAttribute('src', temporary);
    }
    const doc = PMDOMParser.fromSchema(editor.schema).parse(parsed.body);
    const tr = editor.state.tr.replaceRange(range.from, range.to, new Slice(doc.content, 0, 0));
    const positions = [];
    tr.doc.descendants((node, position) => { if (node.type.name === 'image' && imports.has(node.attrs.src)) positions.push({ position, node, payload: imports.get(node.attrs.src) }); });
    const deleteStart = tr.mapping.maps.length;
    for (const image of [...positions].reverse()) tr.delete(image.position, image.position + image.node.nodeSize);
    const mapping = tr.mapping.slice(deleteStart);
    editor.view.dispatch(closeHistory(tr));
    const group = [];
    for (const image of positions) {
      const pos = mapping.map(image.position, -1);
      imageOperation({ from: pos, to: pos }, group, image.payload, image.node.attrs.alt);
    }
    if (rejected) fail(new Error('已保留文字；外部图片或无效图片已移除。请先下载图片，再拖入便笺。'));
  }

  const api = {
    load(value) {
      if (!uuidPattern.test(value.noteID || '')) throw new Error('便笺标识无效。');
      const nextID = value.noteID.toLowerCase();
      // Validate before mutating the visible draft, so a rejected load cannot erase it.
      let json;
      if (value.content?.json) json = canonicalize(JSON.parse(value.content.json), nextID);
      else {
        const oldID = noteID;
        noteID = nextID;
        try { json = value.content?.markdown ? parseMarkdown(value.content.markdown) : emptyDoc(); }
        finally { noteID = oldID; }
      }
      editor.schema.nodeFromJSON(json).check();
      pending.clear();
      noteID = nextID;
      sourceError = null;
      suppress = true;
      editor.commands.setContent(json, { emitUpdate: false, errorOnInvalidContent: true });
      editor.view.updateState(EditorState.create({ schema: editor.schema, doc: editor.state.doc, plugins: editor.state.plugins }));
      suppress = false;
      mode = 'wysiwyg';
      source.hidden = true;
      surface.hidden = false;
      toolbar.dataset.mode = mode;
      for (const button of toolbar.querySelectorAll('[data-mode]')) button.setAttribute('aria-pressed', String(button.dataset.mode === mode));
      for (const button of toolbar.querySelectorAll('[data-action]')) button.disabled = !editor.isEditable;
      show('');
      api.setAppearance(value.appearance || 'dark');
      updateToolbar();
    },
    snapshot,
    insertImage({ token: id, src, alt }) { complete(id, { images: [{ src, alt }] }); },
    resolvePaste({ token: id, handled, images, error }) {
      const operation = pending.get(id);
      if (!operation) return;
      if (operation.item) { complete(id, { images: images || [], error }); return; }
      pending.delete(id);
      if (error) { fail(new Error(error)); return; }
      if (handled) {
        try { if (images?.length) insertAt(operation.range, images.map(image => canonicalize({ type: 'image', attrs: { src: image.src, alt: image.alt || '' } }, noteID))); }
        catch (cause) { fail(cause); }
      } else {
        const fallback = operation.fallback;
        if (fallback.html) pasteHTML(operation.range, fallback.html);
        else if (fallback.files?.length) requestFiles(fallback.files, operation.range);
        else if (fallback.text) {
          try { insertAt(operation.range, parseMarkdown(fallback.text).content || []); }
          catch (cause) { fail(cause); insertAt(operation.range, { type: 'text', text: fallback.text }); }
        }
      }
    },
    setAppearance(appearance) { document.documentElement.dataset.appearance = appearance === 'light' ? 'light' : 'dark'; },
    setEditable(editable) {
      editor.setEditable(Boolean(editable), false);
      if (!editable) { pending.clear(); linkPanel?.remove(); linkPanel = null; }
      source.readOnly = sourceReadOnly || !editable;
      for (const button of toolbar.querySelectorAll('[data-action]')) button.disabled = !editable || mode === 'markdown';
    },
    focus() { if (mode === 'markdown') source.focus(); else editor.commands.focus(); },
  };

  const actions = [
    ['heading', '标题', 'H', () => editor.chain().focus().toggleHeading({ level: 2 }).run(), () => editor.isActive('heading')],
    ['bold', '粗体 ⌘B', 'B', () => editor.chain().focus().toggleBold().run(), () => editor.isActive('bold')],
    ['italic', '斜体 ⌘I', 'I', () => editor.chain().focus().toggleItalic().run(), () => editor.isActive('italic')],
    ['strike', '删除线 ⌘⇧X', 'S', () => editor.chain().focus().toggleStrike().run(), () => editor.isActive('strike')],
    ['bulletList', '无序列表', '• ≡', () => editor.chain().focus().toggleBulletList().run(), () => editor.isActive('bulletList')],
    ['orderedList', '有序列表', '1 ≡', () => editor.chain().focus().toggleOrderedList().run(), () => editor.isActive('orderedList')],
    ['taskList', '任务列表', '☑', () => editor.chain().focus().toggleTaskList().run(), () => editor.isActive('taskList')],
    ['blockquote', '引用', '❞', () => editor.chain().focus().toggleBlockquote().run(), () => editor.isActive('blockquote')],
    ['codeBlock', '代码块', '</>', () => editor.chain().focus().toggleCodeBlock().run(), () => editor.isActive('codeBlock')],
    ['link', '插入链接', '↗', () => showLinkForm(), () => editor.isActive('link')],
    ['image', '插入图片', '▧', () => picker.click()],
    ['horizontalRule', '分隔线', '—', () => editor.chain().focus().setHorizontalRule().run()],
  ];
  const buttons = [];
  for (const [name, label, text, action, active] of actions) {
    const button = document.createElement('button');
    button.type = 'button'; button.dataset.action = name; button.setAttribute('aria-label', label); button.title = label; button.textContent = text;
    button.addEventListener('mousedown', event => event.preventDefault());
    button.addEventListener('click', () => { if (!composing && !editor.view.composing) action(); });
    root.querySelector('.format-tools').append(button);
    buttons.push({ button, active });
  }
  function updateToolbar() {
    if (typeof buttons === 'undefined') return;
    for (const { button, active } of buttons) if (active) button.setAttribute('aria-pressed', String(active()));
  }
  let linkPanel;
  function showLinkForm() {
    if (linkPanel) { linkPanel.remove(); linkPanel = null; return; }
    const selection = bookmark();
    linkPanel = document.createElement('form');
    linkPanel.className = 'link-form';
    linkPanel.innerHTML = '<input type="url" placeholder="https://…" aria-label="链接地址"><button type="submit">应用</button><button type="button">取消</button>';
    const input = linkPanel.querySelector('input');
    input.value = editor.getAttributes('link').href || '';
    linkPanel.addEventListener('submit', event => {
      event.preventDefault();
      const url = input.value.trim();
      if (url && !safeLink(url)) { fail(new Error('请输入 http、https 或 mailto 链接。')); return; }
      const chain = editor.chain().focus().setTextSelection(selection).extendMarkRange('link');
      if (url) chain.setLink({ href: url }).run(); else chain.unsetLink().run();
      linkPanel.remove(); linkPanel = null;
    });
    linkPanel.querySelector('button[type="button"]').addEventListener('click', () => { linkPanel.remove(); linkPanel = null; editor.commands.focus(); });
    toolbar.after(linkPanel); input.focus();
  }
  picker.addEventListener('change', () => { requestFiles(Array.from(picker.files || [])); picker.value = ''; });
  for (const button of toolbar.querySelectorAll('[data-mode]')) button.addEventListener('click', () => setMode(button.dataset.mode));
  const resize = () => {
    const main = root.querySelector('.format-tools');
    const overflow = root.querySelector('.overflow-tools');
    const more = root.querySelector('.more-tools');
    const available = toolbar.clientWidth - root.querySelector('.mode-switch').offsetWidth - 58;
    const count = Math.max(1, Math.min(buttons.length, Math.floor(available / 30)));
    buttons.forEach(({ button }, index) => (index < count ? main : overflow).append(button));
    more.hidden = count === buttons.length;
  };
  const observer = typeof ResizeObserver === 'undefined' ? null : new ResizeObserver(resize);
  observer?.observe(toolbar);
  updateToolbar();
  send({ type: 'ready', version: 1 });
  return { api, editor, setMode, requestPaste, requestFiles, destroy() { observer?.disconnect(); pending.clear(); editor.destroy(); } };
}
