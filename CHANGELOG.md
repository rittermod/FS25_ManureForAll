# Changelog

## 0.2.0.0 (Alpha - 2026-07-05)

- First public alpha
- All husbandries now can consume straw bedding and produce collectable manure, regardless of animal type
- If the husbandry has no straw tip point, tip **bulk straw** at a husbandry's food point to add it
- Produced manure is delivered to a player-placed manure heap near the husbandry
- Warns on screen and in the log when a producing husbandry has no manure heap in range, so manure is never lost silently
- Straw use and manure output scale per animal from its food needs; map- and mod-added animals are covered automatically
- Animals that already produce manure (cow, pig, horse) and mods that define their own production (e.g. RealisticLivestock) are never overridden
- Husbandries that already bring their own straw intake keep it (never a second straw path)
- Multiplayer supported: tested on host, client, and dedicated server
