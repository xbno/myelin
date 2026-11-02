# Google Tasks desktop widget (macOS 14+)

A native WidgetKit widget in the same gallery as the Reminders widget.
- Small, medium and large sizes.
- Shows one list, such as one client or project, or all lists grouped by list.
- Subtasks are indented. Due dates show as Today, Tomorrow or a date, and overdue dates are red.
- Click the circle to complete a task.
- Click anywhere else to open tasks.google.com.

It uses the same Apps Script bridge as the MCP server. The small GTasks app imports `bridge.json` once, and after that the widget calls the bridge directly.

## Build (about 15 minutes, mostly waiting on Xcode)

1. Install **Xcode** from the App Store, open it once, and accept the license.
2. Generate the project:
   ```bash
   brew install xcodegen
   cd tasks/widget          # from your checkout
   xcodegen
   open GTasksWidget.xcodeproj
   ```
3. Set up signing. Go to **Xcode → Settings → Accounts** and add any Apple ID. A free personal one works; this only signs the app so it runs locally. For **both** targets (`GTasks` and `GTasksWidgetExtension`), open **Signing & Capabilities** and set **Team** to your Personal Team.
   To keep this setting when you regenerate the project, put your team ID in `DEVELOPMENT_TEAM` in `project.yml`.
4. Pick the `GTasks` scheme and **My Mac**, then press **Cmd+R**.
5. In the GTasks window:
   - Click **Import bridge.json…** and pick `bridge.json` in your `tasks/` folder. In the file picker, press Cmd+Shift+G to type the path. The file is written by `bridge-init` and `bridge-url`.
   - Click **Test connection**. It should list your task lists.
6. Right-click the desktop, choose **Edit Widgets**, search for **Google Tasks**, and drag a size onto the desktop.
7. To pick a list, right-click the widget, choose **Edit "Google Tasks"**, and set **List**. Leave it empty to show all lists. Add one widget per list if you like.

## Keep it installed without Xcode

In Xcode, choose **Product → Show Build Folder in Finder**. Copy `Products/Debug/GTasks.app` to `/Applications` and open it once. The widget keeps working after you quit Xcode.

## Notes

- **Refresh:** the widget reloads about every 15 minutes, on a schedule macOS controls. After Claude changes tasks, click **Refresh widgets** in the GTasks app to update right away. Completing a task from the widget refreshes it straight away.
- **Where the secret lives:** the bridge URL and secret are stored in the app's shared App Group preferences (`~/Library/Group Containers/<TEAMID>.gtasks.widget/`). Only your user account can read them, the same as `bridge.json`. **Disconnect** in the app removes them.
- **If it stops working** (for example "Unauthorized" or non-JSON errors): check that the web app is still deployed with access "Anyone". If you changed the secret or URL, re-import `bridge.json`.
- **If the widget doesn't appear in the gallery:** run the app once from `/Applications`, then log out and back in.
- **If signing fails:** make sure both targets use the same Team. The App Group ID is built from that team's ID.
