# Changelog

## 1.0.0.0 (Stable - 2026-07-18):
- Changed from Alpha to Stable
- Changed straw capacity on mod-enabled coops to scale with the coop's food capacity, so small coops no longer show an oversized straw bar
- Changed debug logging to be off during normal play in production builds

## 0.2.0.0 (Alpha - 2026-07-05):
- Added the first public alpha release
- Added straw bedding consumption and collectable manure production to all husbandries, regardless of animal type
- Added bulk straw tipping at a husbandry's food point when the husbandry has no straw tip point
- Added delivery of produced manure to a player-placed manure heap near the husbandry
- Added an on-screen and log warning when a producing husbandry has no manure heap in range, so manure is never lost silently
- Added per-animal scaling of straw use and manure output from each animal's food needs, covering map- and mod-added animals automatically
- Kept animals that already produce manure (cow, pig, horse) and mods that define their own production (e.g. RealisticLivestock) untouched
- Kept the existing straw intake on husbandries that already have one, never adding a second straw path
- Added multiplayer support, tested on host, client, and dedicated server
