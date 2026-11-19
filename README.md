# Margin

Margin is a macOS screen-edge app for sticky notes and Apple Reminders. Launch Margin to open the workspace and click **New Note** to create a sticky. Use the swatches in the editor to choose its color. Saving a note shows its colored marker on the edge. Click a marker to open that sticky.

Close the workspace to leave the colored note markers and one **…** menu on screen. Use the menu for **All Notes**, **New Note**, and **New Task**. It also lets you move the strip or quit Margin. Click the same marker again, use the close button, or press Escape to close a sticky.

The most recently saved note appears first, followed by any favorites. If the edge fills up, the workspace shows all notes.

## Run on macOS 14 or later

With the Xcode command-line tools installed, run these commands from the project folder.

```sh
./Scripts/build.sh
open .build/Margin.app
```

Quit an older copy of Margin before opening a new build. The build produces a locally signed app. To try the interface with sample notes and tasks that reset on quit, launch a separate preview instance.

```sh
open -na .build/Margin.app --args --preview --show
```

## Notes and iCloud

You can create notes as soon as you open the app. Before connecting Apple Notes, they are saved on this Mac. After connecting, new notes are saved directly to a folder in iCloud Notes called **Margin**. To get an existing local note onto your iPhone, open it and click **Copy to iCloud**. This preserves the local original.

1. Enable Notes and Reminders in iCloud settings on your Mac and iPhone. Sign in to the same Apple Account on both.
2. In the notes library, click **Connect Apple Notes** and allow Margin to control Notes.
3. Open **Tasks**, click **Connect Apple Reminders**, and allow Reminders access. Margin uses or creates the **Margin** list in iCloud Reminders.
4. Save a test note and task, then look for them in the corresponding Apple apps on both devices. Edit the note or complete the task on your iPhone. Once iCloud has synced to the Mac, reopen the library or use Refresh to see the update.

To bring an existing Apple note or reminder into Margin, move it into the dedicated folder or list in the relevant Apple app. Margin edits plain-text notes. Formatted, locked, shared, and attachment-bearing notes can be opened in Apple Notes. Colors and favorites stay on this Mac.

## Global shortcuts

Open **… → Settings…** on the screen edge to record global shortcuts for **New Note** and **New Task**. Click **Not set**, then press a key with Command, Control, or Option. Escape cancels recording; Clear removes a shortcut. Assignments are saved automatically and work from other apps while Margin is running. Unavailable shortcuts show an error. No Accessibility permission or polling is required.

In the task title field, press Return to create the task without clicking Save.

## Timed tasks

In **New Task**, type `Docs submit @ 2:10` or `Docs submit @ 2:10 PM Nov 20`. Margin previews the date and time before you save. Without AM or PM it chooses the next upcoming occurrence. Apple Reminders delivers the notification. A timed task gets its own teal edge tab when it comes due. The tab pulses twice, then stays as a dim marker until you open the task, open Tasks, or complete the reminder.

## Idle behavior

When closed, Margin keeps its colored note markers and edge menu on screen. Margin hides its edge in fullscreen. It uses one timer for the next timed task and responds to Apple Reminders changes as they happen. It reads Apple data when you open an iCloud note or library, after changes that need a refresh, and when requested. Apple’s own iCloud and Reminders services handle sync and notifications.
