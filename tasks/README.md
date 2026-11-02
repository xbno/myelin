# tasks: Google Tasks for Claude and the menu bar

A local MCP server that lets Claude manage your Google Tasks, plus a menu bar
view of what is open. Use one list per client or project, one level of
subtasks, and due dates that show up in Google Calendar and on your phone.

Tools: `list_task_lists`, `create_task_list`, `rename_task_list`,
`delete_task_list`, `list_tasks`, `list_all_tasks`, `search_tasks`,
`create_task`, `update_task`, `complete_task`, `move_task`, `delete_task`,
`refresh_menu_bar`. The two delete tools are marked destructive, so Claude asks
before it calls them.

Limits of Google Tasks itself:
- Due dates are date-only. There is no time of day.
- Subtasks go one level deep.

Any Google account works. All paths below are relative to this `tasks/` folder.

## 1. Connect to Google

There are two backends. The server uses the direct API when `token.json`
exists, and the Apps Script bridge otherwise. The credential files stay in this
folder and are ignored by git.

### Option A: direct Google Tasks API

This is the most work, about 15 minutes, but it is the backend that keeps
working. You need a Google Cloud project. It costs nothing, and you do not
need billing. Do it once, signed in to https://console.cloud.google.com with
the Google account whose tasks you want.

**Before you start:** on a work Google account, your Workspace admin may block
you from creating Cloud projects or turning on APIs. If the console refuses, ask
your admin to let you create a project and turn on the Google Tasks API. A
personal Gmail account needs no one's permission.

1. **Create a project.** Open the project picker at the top, then click
   **New project**. Any name works, for example "tasks".
2. **Turn on the API.** Go to **APIs & Services → Library**, search for
   **Google Tasks API**, and click **Enable**.
3. **Set up the consent screen.** Go to **Google Auth Platform → Branding** and
   click **Get started**. Enter an app name and your email, then pick the
   audience:
   - **Work account:** choose **Internal**. Only people in your organization can
     sign in, and nothing more is needed.
   - **Personal account:** choose **External**. Then, under **Audience**, add
     yourself as a test user and click **Publish app** to set the status to
     **In production**. If you leave it in **Testing**, Google cancels your
     sign-in every 7 days. Google then shows "Google hasn't verified this app"
     when you sign in. Click **Advanced → Go to (app name)**. It is your own
     app.
4. **Create the client.** Go to **Google Auth Platform → Clients → Create
   client**, choose **Desktop app**, and click **Create**. Download the JSON and
   save it in this folder as `credentials.json`.
5. **Sign in:**
   ```bash
   uv sync
   uv run server.py auth      # opens the browser, writes token.json
   ```
   It ends by printing `[direct] OK.` and your task lists.

`credentials.json` identifies your app, and `token.json` holds your sign-in.
Keep both private. Git ignores them.

### Option B: Apps Script bridge (no Cloud project)

A small Google Apps Script (`apps_script/Code.gs`) runs as you at
script.google.com and does the Tasks calls. Every request must carry a secret.
Without it the script touches nothing.

```bash
uv sync
uv run server.py bridge-init
```

`bridge-init` creates a random secret, saves it in `bridge.json`, and copies
`Code.gs`, with that secret filled in, to your clipboard. Then, in the browser,
signed in to the Google account whose tasks you want:

1. Open https://script.google.com and click **New project**. Replace everything
   in the editor with the clipboard contents, and save (Cmd+S).
2. In the left sidebar, click **Services (+)**, choose **Google Tasks API**, and
   click **Add**.
3. Click **Deploy → New deployment**, click the gear icon, and choose
   **Web app**. Set **Execute as: Me** and **Who has access: Anyone**. Deploy and
   approve the permission prompt. If Google says the app isn't verified, click
   **Advanced → Go to (project name)**. It is your own script.
4. Copy the **Web app URL** (it ends in `/exec`), then run:
   ```bash
   uv run server.py bridge-url 'https://script.google.com/macros/s/.../exec'
   ```
   It prints the account it connected as, followed by your task lists.

If **Who has access** doesn't offer "Anyone", your Google Workspace admin has
restricted it. Use option A instead.

If you edit `Code.gs` later, go to **Deploy → Manage deployments**, click the
pencil icon, choose **Version: New version**, and deploy. The URL stays the same.

Check either backend with:

```bash
uv run server.py check
```

## 2. Add it to Claude

For Claude Code:

```bash
claude mcp add google-tasks -s user -- "$(which uv)" --directory "$PWD" run server.py
```

For the Claude desktop app, add this entry under `mcpServers` in
`~/Library/Application Support/Claude/claude_desktop_config.json`. Use the
output of `which uv` and the full path of this folder:

```json
"google-tasks": {
  "command": "/path/to/uv",
  "args": ["--directory", "/path/to/myelin/tasks", "run", "server.py"]
}
```

Quit Claude completely (Cmd+Q) and reopen it.

## 3. Menu bar

The menu bar view is a [SwiftBar](https://github.com/swiftbar/SwiftBar) plugin.

```bash
brew install --cask swiftbar
./install.sh
```

`install.sh` creates the Python env, links the plugin into SwiftBar's plugin
folder, and installs a launchd agent (`~/Library/LaunchAgents/com.myelin.swiftbar.plist`).
The agent starts SwiftBar at login and starts it again if it crashes. If you
quit SwiftBar from its menu, it stays quit until the next login. Do not also
turn on SwiftBar's own "Launch at login", or two copies will run.

The menu bar shows how many tasks are due today or overdue. Open it (or press
⌘⌥T) to see tasks grouped by list, and click a task to complete it. It refreshes
every 5 minutes, and right away when Claude changes a task.

To give a list its own color, create `colors.json` here (ignored by git):

```json
{ "acme": ["#9C84CF", "38;5;141"] }
```

Each value is the header color and an ANSI 256-color code for the bullets.
Other lists get a color picked from the list title.

To remove the agent:

```bash
launchctl bootout gui/$(id -u)/com.myelin.swiftbar
rm ~/Library/LaunchAgents/com.myelin.swiftbar.plist
```

**Desktop widget:** see [widget/README.md](widget/README.md). It uses the Apps
Script bridge only.

**Phone:** install the Google Tasks app and add its widget. Tasks with due dates
also appear in Google Calendar.

## Tests

```bash
uv run --group dev pytest -q
```

The tests never touch your real account or your menu bar. `test_bridge.py` runs
the real `Code.gs` under Node against a fake Tasks backend, through a local
server that behaves like the Apps Script web app. It is skipped if Node isn't
installed.

## Troubleshooting

- **"No bridge.json" or "has no url yet":** run `bridge-init` and `bridge-url`
  again, or set up option A.
- **"Bridge returned non-JSON" or a sign-in page:** the web app isn't deployed
  with **Who has access: Anyone**.
- **"Unauthorized":** the secret in `Code.gs` doesn't match `bridge.json`. Run
  `bridge-init` again, re-paste the script, and deploy a new version.
- **"You do not have permission to call tasks...":** the bridge lost its Tasks
  grant. Open the script, run `selfTest` once to approve access again, and
  deploy a new version.
- **"Google token refresh failed":** run `uv run server.py auth` again.
- **Menu bar icon missing after a restart:** check
  `launchctl print gui/$(id -u)/com.myelin.swiftbar` and
  `~/Library/Logs/swiftbar.err`. If the menu bar is full, macOS hides the
  leftmost items; ⌘-drag the icon to the right.
- **Server doesn't appear in the Claude desktop app:** check
  `~/Library/Logs/Claude/mcp-server-google-tasks.log`. Usually the uv path in
  the config is wrong.
