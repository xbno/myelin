/**
 * Google Tasks bridge. Runs as you in Apps Script, so no Google Cloud project or billing.
 *
 * Setup (see README):
 *   1. Paste this file into a new project at https://script.google.com
 *      (`uv run server.py bridge-init` copies it to your clipboard with SECRET filled in).
 *   2. Left sidebar: Services (+) -> Google Tasks API -> Add.
 *   3. Deploy -> New deployment -> Web app. Execute as: Me. Who has access: Anyone.
 *   4. Copy the Web app URL and run `uv run server.py bridge-url <URL>`.
 *
 * Every request must carry SECRET. Without it the endpoint returns an error and touches nothing.
 */
const SECRET = '__SECRET__';

function doPost(e) {
  let req;
  try {
    req = JSON.parse((e && e.postData && e.postData.contents) || '{}');
  } catch (err) {
    return reply_({ error: 'Request body is not JSON.' });
  }
  if (!SECRET || SECRET === '__SECRET__' || req.secret !== SECRET) {
    return reply_({ error: 'Unauthorized.' });
  }
  try {
    return reply_({ result: dispatch_(req.op, req.args || {}) });
  } catch (err) {
    return reply_({ error: String((err && err.message) || err) });
  }
}

function doGet() {
  return reply_({ ok: true, service: 'google-tasks-bridge' });
}

function dispatch_(op, a) {
  if (op !== 'ping' && typeof Tasks === 'undefined') {
    throw new Error('Tasks service is not enabled in the deployed version. Add it (appsscript.json), save, then Deploy > Manage deployments > edit > Version: New version.');
  }
  switch (op) {
    case 'ping':
      return { ok: true, user: Session.getEffectiveUser().getEmail(), tasksService: typeof Tasks !== 'undefined' };

    case 'tasklists.list':
      return Tasks.Tasklists.list(clean_({ maxResults: a.maxResults, pageToken: a.pageToken }));
    case 'tasklists.get':
      return Tasks.Tasklists.get(a.tasklist);
    case 'tasklists.insert':
      return Tasks.Tasklists.insert(a.body);
    case 'tasklists.patch':
      return Tasks.Tasklists.patch(a.body, a.tasklist);
    case 'tasklists.delete':
      Tasks.Tasklists.remove(a.tasklist);
      return {};

    case 'tasks.list':
      return Tasks.Tasks.list(a.tasklist, clean_({
        maxResults: a.maxResults,
        pageToken: a.pageToken,
        showCompleted: a.showCompleted,
        showHidden: a.showHidden,
        dueMin: a.dueMin,
        dueMax: a.dueMax,
      }));
    case 'tasks.insert':
      return Tasks.Tasks.insert(a.body, a.tasklist, clean_({ parent: a.parent, previous: a.previous }));
    case 'tasks.patch':
      return patchTask_(a.tasklist, a.task, a.body || {});
    case 'tasks.move':
      return Tasks.Tasks.move(a.tasklist, a.task, clean_({
        parent: a.parent,
        previous: a.previous,
        destinationTasklist: a.destinationTasklist,
      }));
    case 'tasks.delete':
      Tasks.Tasks.remove(a.tasklist, a.task);
      return {};

    default:
      throw new Error('Unknown op: ' + op);
  }
}

/** Patch, but a null field means "clear it" (e.g. remove a due date), which needs a full update. */
function patchTask_(tasklist, taskId, body) {
  const clears = Object.keys(body).filter(function (k) { return body[k] === null; });
  if (clears.length === 0) {
    return Tasks.Tasks.patch(body, tasklist, taskId);
  }
  const task = Tasks.Tasks.get(tasklist, taskId);
  Object.keys(body).forEach(function (k) {
    if (body[k] === null) {
      delete task[k];
    } else {
      task[k] = body[k];
    }
  });
  return Tasks.Tasks.update(task, tasklist, taskId);
}

function clean_(obj) {
  const out = {};
  Object.keys(obj).forEach(function (k) {
    if (obj[k] !== undefined && obj[k] !== null) out[k] = obj[k];
  });
  return out;
}

function reply_(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj)).setMimeType(ContentService.MimeType.JSON);
}

/** Run this from the editor (function dropdown -> selfTest -> Run) to check the Tasks service and grant access. */
function selfTest() {
  const lists = Tasks.Tasklists.list().items || [];
  Logger.log('Tasks service OK. Lists: ' + lists.map(function (l) { return l.title; }).join(', '));
}
