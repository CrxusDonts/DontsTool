import { createNotesEditor } from './editor.js';
import './editor.css';

const app = createNotesEditor(document.getElementById('app'));
window.dontsNote = app.api;
