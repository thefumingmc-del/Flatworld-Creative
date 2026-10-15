#!/usr/bin/env python3
"""Offline regression tests for the current 26.3 runtime registry subset."""
from __future__ import annotations
import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REG = ROOT / "assets/data/registries/26.3"


def load(name: str) -> dict:
    return json.loads((REG / name).read_text(encoding="utf-8"))


class RuntimeRegistryContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.blocks_doc = load("blocks.json")
        cls.items_doc = load("items.json")
        cls.renders_doc = load("block_render_definitions.json")
        cls.item_visuals_doc = load("item_visual_definitions.json")
        cls.mappings = load("block_item_mappings.json")

    def test_registries_have_separate_root_kinds(self):
        self.assertEqual(self.blocks_doc["registry_kind"], "canonical_block_registry_subset")
        self.assertEqual(self.items_doc["registry_kind"], "canonical_item_registry_subset")
        self.assertIn("blocks", self.blocks_doc)
        self.assertIn("items", self.items_doc)
        self.assertNotIn("items", self.blocks_doc)
        self.assertNotIn("blocks", self.items_doc)

    def test_item_rows_never_embed_block_identity(self):
        self.assertTrue(all("block_id" not in row for row in self.items_doc["items"].values()))

    def test_block_item_maps_are_exact_inverses(self):
        i2b = self.mappings["item_to_block"]
        b2i = self.mappings["block_to_item"]
        self.assertEqual(len(i2b), len(set(i2b)))
        self.assertEqual(len(b2i), len(set(b2i)))
        for iid, bid in i2b.items():
            self.assertIn(iid, self.items_doc["items"])
            self.assertIn(bid, self.blocks_doc["blocks"])
            self.assertIn(bid, self.renders_doc["block_render_definitions"])
            self.assertTrue(self.renders_doc["block_render_definitions"][bid].get("placeable", False))
            self.assertEqual(b2i[bid], iid)
        for bid, iid in b2i.items():
            self.assertEqual(i2b[iid], bid)

    def test_wheat_item_is_not_mapped_to_wheat_crop(self):
        self.assertIn("wheat", self.items_doc["items"])
        self.assertIn("wheat", self.blocks_doc["blocks"])
        self.assertNotIn("wheat", self.mappings["item_to_block"])
        self.assertNotIn("wheat", self.mappings["block_to_item"])

    def test_redstone_item_maps_to_wire_block(self):
        self.assertEqual(self.mappings["item_to_block"].get("redstone"), "redstone_wire")
        self.assertEqual(self.mappings["block_to_item"].get("redstone_wire"), "redstone")
        self.assertNotIn("redstone_wire", self.items_doc["items"])

    def test_transformed_blocks_are_not_fake_inventory_items(self):
        for block_only in ("water", "lava", "farmland", "dirt_path"):
            self.assertIn(block_only, self.blocks_doc["blocks"])
            self.assertNotIn(block_only, self.items_doc["items"])
            self.assertNotIn(block_only, self.mappings["item_to_block"])

    def test_icon_registry_never_adds_items(self):
        item_ids = set(self.items_doc["items"])
        visual_ids = set(self.item_visuals_doc["item_visual_definitions"])
        self.assertLessEqual(visual_ids, item_ids)

    def test_legacy_map_item_migrations_target_filled_map(self):
        migrations = load("id_migrations.json")
        alias_map = migrations["item_id_migrations"]
        for legacy in (
            "abandoned_camp_map", "buried_treasure_map", "ocean_monument_map",
            "woodland_mansion_map", "explorer_map_camp_dappled_forest"
        ):
            self.assertEqual(alias_map.get(legacy), "filled_map")
        for legacy in ("wheat_crop", "beetroot_crop"):
            self.assertNotEqual(alias_map.get(legacy), legacy.split("_crop")[0])

    def test_maps_use_the_single_canonical_filled_map_item(self):
        item_ids = set(self.items_doc["items"])
        self.assertIn("map", item_ids)
        self.assertIn("filled_map", item_ids)
        old_themed_ids = {
            "abandoned_camp_map", "buried_ancient_city_map", "buried_mineshaft_map",
            "buried_treasure_map", "buried_trial_chambers_map", "desert_pyramid_map",
            "desert_village_map", "jungle_pyramid_map", "ocean_monument_map",
            "plains_village_map", "savanna_village_map", "snowy_village_map",
            "swamp_hut_map", "taiga_village_map", "warm_ocean_ruins_map",
            "woodland_mansion_map"
        }
        self.assertFalse(item_ids & old_themed_ids)
        self.assertIn("filled_map", self.item_visuals_doc["item_visual_definitions"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
