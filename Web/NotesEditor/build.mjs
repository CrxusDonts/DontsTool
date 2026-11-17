import { build } from 'esbuild';
import { readFile, writeFile, mkdir, readdir, access } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const directory = path.dirname(fileURLToPath(import.meta.url));
const output = path.resolve(directory, '../../Resources/NotesEditor');
await mkdir(output, { recursive: true });
const result = await build({
  absWorkingDir: directory,
  entryPoints: ['src/bootstrap.js'],
  bundle: true,
  minify: true,
  format: 'iife',
  target: ['safari17'],
  outfile: path.join(output, 'editor.js'),
  metafile: true,
  legalComments: 'none',
  charset: 'utf8',
  logLevel: 'warning',
});
await writeFile(path.join(output, 'index.html'), await readFile(path.join(directory, 'src/index.html')));

const packages = new Map();
for (const input of Object.keys(result.metafile.inputs)) {
  if (!input.includes('node_modules/')) continue;
  let current = path.dirname(path.resolve(directory, input));
  while (current.startsWith(directory)) {
    try {
      const info = JSON.parse(await readFile(path.join(current, 'package.json'), 'utf8'));
      if (info.name && info.version) { packages.set(`${info.name}@${info.version}`, { directory: current, info }); break; }
    } catch { /* Continue from a package's dist directory to its package root. */ }
    current = path.dirname(current);
  }
}
const notices = ['DontsTool Notes Editor — bundled third-party notices', 'All runtime code is bundled locally. No fonts, scripts, or styles are loaded from a CDN.'];
for (const [name, entry] of [...packages].sort(([a], [b]) => a.localeCompare(b))) {
  notices.push(`\n${'='.repeat(72)}\n${name}\nLicense: ${entry.info.license}\nSource: ${typeof entry.info.repository === 'string' ? entry.info.repository : entry.info.repository?.url || entry.info.homepage || ''}\n`);
  const files = (await readdir(entry.directory)).filter(file => /^(LICENSE|COPYING|NOTICE)(\.|$)/i.test(file)).sort();
  if (!files.length) throw new Error(`Missing license text for ${name}`);
  for (const file of files) notices.push(await readFile(path.join(entry.directory, file), 'utf8'));
  const additional = path.join(entry.directory, 'THIRD_PARTY_LICENSES.md');
  try { await access(additional); notices.push(await readFile(additional, 'utf8')); } catch { /* Optional upstream attribution file. */ }
}
await writeFile(path.join(output, 'THIRD_PARTY_NOTICES.txt'), notices.join('\n'));
console.log(`Built ${packages.size} bundled packages into Resources/NotesEditor`);
