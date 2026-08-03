# Safari

Yes, it works. I reworked the script so it lives equally well in Chrome and in Safari — version 0.5.0 figures out for itself what's available to it.

## What to know before you choose

Technically everything is there. Highlighting is drawn through the CSS Custom Highlight API, which WebKit shipped in Safari 17.2 back at the end of 2023 — on your new Mac, Safari is much fresher than that. Highlighting, notes, topics, the side panel, search, export — all the same.

The difference is in one thing: the userscript manager. Safari has two.

**Userscripts** — free, open source, [in the App Store](https://apps.apple.com/us/app/userscripts/id1463298887). It takes a folder on disk and picks up scripts from there. My pick if you're staying in Safari.

**Tampermonkey for Safari** — [$2.99 one-time](https://apps.apple.com/us/app/tampermonkey/id6738342400), the same interface as in Chrome. If you're used to it in another browser, three dollars is worth it: the editor is nicer and the storage is more reliable.

## The one real downside of Safari

Userscripts gives scripts asynchronous storage only, and Safari on top of that clears site data more aggressively. So my working storage is plain localStorage, and GM storage runs as a mirror. If Safari ever wipes claude.ai's data, the script will see emptiness at startup, pull the highlights up from the mirror and say "restored 47".

There's one practical takeaway: export to the library more often. It was worth doing anyway — the panel has a counter showing how much hasn't left yet.

In Chrome with Tampermonkey this problem doesn't come up at all, the storage there is its own and synchronous. If you don't care which browser you read long chats in, I'd read in Chrome. If Safari is your home, stay — the construction doesn't fall apart because of it.

## Installation

Run bootstrap with a flag so it doesn't drag Chrome in:

```bash
bash bootstrap.sh --safari
```

After that it's like the main instructions: Google Drive, Hammerspoon, then `bash install.sh`.

The script gets loaded into Safari differently than into Chrome.

**Through Userscripts.** Install the app from the App Store. Open Safari → Settings → Extensions → turn on Userscripts and give it access to all sites (the button is in the same panel, "Always Allow on Every Website"). Click the Userscripts icon in the Safari toolbar — it will ask you to pick a folder for scripts. Create, say, `~/Documents/Userscripts` and select it.

Now just drop the `chat-marker.user.js` file from the kit folder in there:

```bash
cp ~/Downloads/chat-marker-kit/chat-marker.user.js ~/Documents/Userscripts/
```

It gets picked up on its own. Reload the claude.ai tab — a round button with a counter will show up in the bottom right.

**Through Tampermonkey.** Everything like in Chrome: icon → Create a new script → select the template, replace it with the contents of the file, Cmd+S.

## What to watch out for

On the first export Safari will ask whether to allow downloads from claude.ai. Allow it, otherwise the "Download .json" button will silently do nothing.

If you put the script in the Userscripts folder and it didn't show up — check that the extension's settings have access enabled for claude.ai specifically. Safari by default grants permission for one day or for one site, and that's easy to miss.

The Alt+1…4 hotkeys work the same in Safari. As for the system-wide `⌃⌥⌘1…4` from Hammerspoon — those have nothing to do with the browser at all, they work the same everywhere.

## You can have both

The script is the same, but each browser has its own storage. If you install it in both Chrome and Safari, you get two independent databases — export from both, they'll merge in the library by identifier, there won't be duplicates.
