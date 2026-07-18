# Manure For All

[![Download Latest Release](https://img.shields.io/badge/Download-Latest_Release-orange?style=for-the-badge&logo=github)](https://github.com/rittermod/FS25_ManureForAll/releases/latest/download/FS25_ManureForAll.zip)

Make every animal husbandry produce collectable manure. Bed chickens, sheep, goats and pastured animals with straw at the food trough and collect manure from a heap - just like cows, pigs and horses.

In the base game only cows, pigs and horses turn straw bedding into manure. Manure For All wires the same straw-to-manure pipeline onto every animal husbandry - chicken coops, sheep and goat barns, and all open pastures, including map- and mod-added animals. No building is replaced and no map is edited: the mod augments the husbandries you already own, at load time, and works with existing savegames.

## Features

- **Manure from every husbandry** - all husbandries can consume straw bedding and produce collectable manure, regardless of animal type
- **Straw in at the food point** - if a husbandry has no straw tip point, tip bulk straw at its food point; it is stored as bedding while food still feeds the animals
- **Right-sized straw storage** - each mod-enabled husbandry gets its own straw storage, sized to its food capacity (at least ~8000 L), so the straw bar fits the barn
- **Manure out at a heap** - produced manure is delivered to a player-placed manure heap near the husbandry
- **Honest warnings** - on-screen and log warning when a producing husbandry has no manure heap in range, so manure is never lost silently
- **Per-animal scaling** - straw use and manure output scale per animal from its food needs; map- and mod-added animals are covered automatically
- **Plays nice with others** - animals that already produce manure (cow, pig, horse) and mods that define their own production (e.g. RealisticLivestock) are never overridden
- **Multiplayer** - tested on host, client, and dedicated server

## Installation

### From GitHub Releases
1. Download the latest release from [Releases](https://github.com/rittermod/FS25_ManureForAll/releases)
2. Place the `.zip` file in your mods folder:
   - **Windows**: `%USERPROFILE%\Documents\My Games\FarmingSimulator2025\mods\`
   - **macOS**: `~/Library/Application Support/FarmingSimulator2025/mods/`
3. Enable the mod in-game

## Usage

1. Place a manure heap (from the build menu) near the husbandry
2. Tip bulk straw at the husbandry's food point (or its own straw tip point where one exists)
3. Animals consume the straw over time and manure accumulates in the heap

## Limitations

- A manure heap must be placed within range of the husbandry; without one, produced manure is discarded every hour (the mod warns about this when placing the husbandry and in the log)
- Straw must be tipped as loose material - the food point has no bale trigger
- On dedicated servers the "no heap in range" warning is written to the server log only (no on-screen client notification)

## Compatibility

- **Game Version**: Farming Simulator 25
- **Multiplayer**: Supported
- **Platform**: PC (Windows/macOS)

## Changelog

See [CHANGELOG.md](CHANGELOG.md)

## License

This mod is provided as-is for personal use with Farming Simulator 25.

## Credits

- **Author**: [Ritter](https://github.com/rittermod)

## Support

Found a bug or have a feature request? [Open an issue](https://github.com/rittermod/FS25_ManureForAll/issues)
