# GuildHub

A World of Warcraft addon for WoW Forever (beta, interface 16001): a hub for your guild.

**Events**
- Raid, Dungeon or Battleground events with a description, optional weekly repeat, and per-role slot limits (hosts can edit slots, time and description).
- Sign up as Tank / Healer / DPS, or Tentative / Declined. A full role puts you on its waitlist and you move up automatically.
- Filters by type, date, free role slot and name. Times are shown in each player's local time.
- Reminders at login and shortly before an event starts; share an event in guild chat (`/gh #CODE` opens it).
- Hosts can record attendance (everyone in their group).

**Crafting**
- Craft requests with materials/notes, a "needed by" date and item tooltips; claim, give back, mark done, or whisper the other person.
- Crafters directory: players, then their professions, then their recipes (gathering professions are skipped).

**Guild**
- Bank requests, attendance stats, and a leaderboard of fulfilled requests.
- Board: announcements from officers, shown on login.

**Other**
- Notifications (new events, your requests, things you can craft, announcements), minimap button, settings window, automatic cleanup of old events and requests.

Everything syncs between guild members who have the addon, over the hidden guild addon channel.

## Install

Clone straight into your AddOns folder so the folder name is `GuildHub`:

```
cd "/Applications/World of Warcraft/_classic_beta_/Interface/AddOns"
git clone https://github.com/stefanradu1989/GuildHub.git
```

Update later with `git pull` inside that folder, then `/reload` in game.

No git? Download the ZIP from GitHub and rename the extracted folder from `GuildHub-main` to `GuildHub`.

## Use

- `/gh` opens the window; the minimap button does too (right-click for settings).
- `/gh who <text>` lists guild members who can craft a recipe.
- `/gh settings` opens the settings window.
- `/gh #CODE` opens an event from a shared guild chat message.
- For errors, run `/console scriptErrors 1` and `/reload`.

## Status

Early and untested in the live client. Expect bugs; issues and notes welcome.
