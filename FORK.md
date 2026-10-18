# oracles-voxel

A fork of [kirby-letsgo/oracles-decomp](https://github.com/kirby-letsgo/oracles-decomp) that adds one
thing to the mod API and ships a mod that uses it.

- **`oracles.rd_bank1(addr)`** reads work RAM bank 1 (`$d000`-`$dfff`), where Link and the other
  objects live. `oracles.rd` is unchanged, and the new function is documented in
  [MODDING.md](MODDING.md) and covered by `tests/test_mods.c`.
- **`mods/voxel-view`** draws the current room as a 3D voxel diorama (a corner map by default, or the
  whole playfield with `DEFAULT_VIEW = 2`). With `rd_bank1` it shows Link at his real pixel position;
  on an unmodified build it still runs, with Link snapped to his tile.

To use the mod, copy `mods/voxel-view` into the app's `mods` folder (see MODDING.md) and restart the game.
