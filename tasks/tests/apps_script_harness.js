// Runs apps_script/Code.gs under Node with an in-memory stand-in for the Apps Script
// Tasks advanced service. State persists in a JSON file between invocations.
//
// Usage: node apps_script_harness.js <Code.gs> <state.json> <secret>  < request.json  > response.json
const fs = require('fs');
const vm = require('vm');

const [codePath, statePath, secret] = process.argv.slice(2);
const load = () => (fs.existsSync(statePath)
  ? JSON.parse(fs.readFileSync(statePath, 'utf8'))
  : { seq: 0, lists: { L0: { id: 'L0', title: 'My Tasks' } }, tasks: { L0: {} } });
const state = load();
const nextId = (p) => `${p}${++state.seq}`;
const need = (cond, msg) => { if (!cond) throw new Error(msg); };
const listId = (id) => (id === '@default' ? 'L0' : id);

const Tasks = {
  Tasklists: {
    list: (opts) => ({ items: Object.values(state.lists) }),
    get: (id) => { need(state.lists[listId(id)], 'Not Found'); return state.lists[listId(id)]; },
    insert: (body) => { const id = nextId('L'); state.lists[id] = { id, title: body.title }; state.tasks[id] = {}; return state.lists[id]; },
    patch: (body, id) => Object.assign(state.lists[id], body),
    remove: (id) => { delete state.lists[id]; delete state.tasks[id]; },
  },
  Tasks: {
    list: (tl, opts) => {
      need(state.tasks[tl], 'Not Found');
      if (opts.showCompleted !== undefined && typeof opts.showCompleted !== 'boolean') throw new Error('showCompleted must be boolean');
      let items = Object.values(state.tasks[tl]);
      if (opts.showCompleted === false) items = items.filter((t) => t.status !== 'completed');
      if (opts.dueMin) items = items.filter((t) => t.due && t.due >= opts.dueMin);
      if (opts.dueMax) items = items.filter((t) => t.due && t.due <= opts.dueMax);
      return { items };
    },
    get: (tl, id) => JSON.parse(JSON.stringify(state.tasks[tl][id])),
    insert: (body, tl, opts) => {
      need(state.tasks[tl], 'Not Found');
      const id = nextId('T');
      const t = Object.assign({ id, status: 'needsAction', position: String(1e9 - state.seq).padStart(20, '0') }, body);
      if (opts.parent) t.parent = opts.parent;
      state.tasks[tl][id] = t;
      return t;
    },
    patch: (body, tl, id) => {
      for (const k of Object.keys(body)) need(body[k] !== null, 'patch received null; should have used update');
      return Object.assign(state.tasks[tl][id], body);
    },
    update: (task, tl, id) => { state.tasks[tl][id] = task; return task; },
    move: (tl, id, opts) => {
      const t = state.tasks[tl][id]; delete state.tasks[tl][id];
      delete t.parent; if (opts.parent) t.parent = opts.parent;
      state.tasks[opts.destinationTasklist || tl][id] = t;
      return t;
    },
    remove: (tl, id) => { delete state.tasks[tl][id]; },
  },
};

const ContentService = {
  MimeType: { JSON: 'json' },
  createTextOutput: (s) => ({ text: s, setMimeType() { return this; } }),
};
const Session = { getEffectiveUser: () => ({ getEmail: () => 'user@example.com' }) };

const code = fs.readFileSync(codePath, 'utf8').replace("'__SECRET__';", `'${secret}';`);
const ctx = { Tasks, ContentService, Session, console };
vm.createContext(ctx);
vm.runInContext(code, ctx);

const body = fs.readFileSync(0, 'utf8');
const out = ctx.doPost({ postData: { contents: body } });
fs.writeFileSync(statePath, JSON.stringify(state));
process.stdout.write(out.text);
