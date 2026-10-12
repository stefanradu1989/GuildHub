# GuildHub

A World of Warcraft addon for WoW Forever (beta, interface 16001): a small hub for your guild.

- **Events:** create guild events, sign up as Tank / Healer / DPS, optional slot limits per role (the host can edit them), and a chat reminder at login for events happening today. Times are shown in each player's local time.
- **Requests:** post craft requests, claim them, mark them done.
- **Crafters:** a searchable directory of who in the guild can craft what. Open your profession windows to share your recipes.

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

- `/gh` opens the window.
- `/gh who <text>` lists guild members who can craft a recipe.
- For errors, run `/console scriptErrors 1` and `/reload`.

## Status

Early and untested in the live client. Expect bugs; issues and notes welcome.
