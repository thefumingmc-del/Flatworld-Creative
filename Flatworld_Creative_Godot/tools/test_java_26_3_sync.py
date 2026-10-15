#!/usr/bin/env python3
"""Offline unit tests for the pinned Java 26.3 importer's schema transforms."""
import unittest
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
import sync_java_26_3_reference as sync

class ReferenceParserTests(unittest.TestCase):
    def test_block_state_report_becomes_explicit_property_domains(self):
        report = {
            "minecraft:wheat": {"states": [
                {"id": 100, "default": True, "properties": {"age": "0"}},
                {"id": 101, "properties": {"age": "1"}},
                {"id": 102, "properties": {"age": "2"}},
            ]},
            "minecraft:air": {"states": [{"id": 0, "default": True}]},
        }
        blocks, states = sync.parse_blocks(report)
        self.assertEqual(set(blocks), {"wheat", "air"})
        self.assertEqual(states["wheat"]["properties"]["age"]["type"], "int")
        self.assertEqual(states["wheat"]["properties"]["age"]["max"], 2)
        self.assertEqual(states["wheat"]["default_state_id"], 100)
        self.assertTrue(states["wheat"]["complete"])

    def test_state_registry_rejects_duplicate_ids_and_missing_default(self):
        blocks = {"stone": {}, "dirt": {}}
        states = {
            "stone": {"state_count": 1, "states": [{"id": 1, "default": True}]},
            "dirt": {"state_count": 1, "states": [{"id": 1}]},
        }
        result = sync.validate_state_registry(blocks, states)
        self.assertTrue(result["all_report_blocks_have_state_record"])
        self.assertFalse(result["all_reported_state_ids_unique"])
        self.assertFalse(result["exactly_one_default_state_per_block"])
        self.assertTrue(result["all_state_rows_have_numeric_ids"])

    def test_boolean_and_enum_state_domains(self):
        report = {"minecraft:oak_leaves": {"states": [
            {"id": 1, "default": True, "properties": {"persistent": "false", "distance": "1"}},
            {"id": 2, "properties": {"persistent": "true", "distance": "2"}},
        ]}}
        _, states = sync.parse_blocks(report)
        props = states["oak_leaves"]["properties"]
        self.assertEqual(props["persistent"]["type"], "bool")
        self.assertEqual(props["distance"]["type"], "int")

    def test_item_registry_reads_components_not_name_heuristics(self):
        report = {
            "minecraft:diamond_sword": {"id": 4, "components": {"minecraft:max_stack_size": 1, "minecraft:max_damage": 1561}},
            "minecraft:stone": {"id": 5, "components": {"minecraft:max_stack_size": 64}},
        }
        report["minecraft:wheat"] = {"id": 6, "components": {"minecraft:food": {"nutrition": 2}}}
        items, components = sync.parse_items(report, {"stone", "wheat"})
        self.assertEqual(items["diamond_sword"]["max_stack_size"], 1)
        self.assertEqual(items["diamond_sword"]["max_damage"], 1561)
        self.assertNotIn("block_id", items["stone"], "item registry must not carry a block identity field")
        self.assertNotIn("block_id", items["wheat"], "same-name food and crop block must not be implicitly coupled")
        self.assertNotIn("block_id", items["diamond_sword"])
        self.assertIn("minecraft:max_damage", components["diamond_sword"])

    def test_explicit_item_to_block_mapping_handles_id_collisions_and_aliases(self):
        blocks = {"stone": {}, "wheat": {}, "redstone_wire": {}, "water": {}, "farmland": {}}
        items = {
            "stone": {"components": {}},
            "wheat": {"components": {"minecraft:food": {"nutrition": 2}}},
            "redstone": {"components": {}},
            "water": {"components": {}},
            "farmland": {"components": {}},
        }
        visuals = {
            "stone": {"placeable": True}, "wheat": {"placeable": True},
            "redstone_wire": {"placeable": True}, "water": {"placeable": True},
            "farmland": {"placeable": True},
        }
        mapping = sync.build_project_block_item_mappings(blocks, items, visuals)
        self.assertEqual(mapping["item_to_block"], {"redstone": "redstone_wire", "stone": "stone"})
        self.assertEqual(mapping["block_to_item"], {"redstone_wire": "redstone", "stone": "stone"})
        self.assertNotIn("wheat", mapping["item_to_block"])
        self.assertNotIn("water", mapping["item_to_block"])
        self.assertNotIn("farmland", mapping["item_to_block"])

    def test_canonical_resource_ids_are_registry_specific(self):
        self.assertEqual(sync.server_registry_id("data/minecraft/recipe/oak_planks.json", "recipes"), "minecraft:oak_planks")
        self.assertEqual(sync.server_registry_id("data/minecraft/tags/block/logs.json", "tags_block"), "minecraft:logs")
        self.assertEqual(sync.server_registry_id("data/minecraft/loot_table/blocks/stone.json", "loot_tables"), "minecraft:blocks/stone")
        self.assertEqual(sync.server_registry_id("data/minecraft/worldgen/biome/plains.json", "worldgen"), "minecraft:plains")
        self.assertEqual(sync.server_tag_registry("data/minecraft/tags/block/logs.json"), ("blocks", "minecraft:logs"))
        self.assertEqual(sync.server_tag_registry("data/minecraft/tags/worldgen/biome/is_overworld.json"), ("biomes", "minecraft:is_overworld"))

    def test_non_vanilla_namespaces_are_not_silently_shortened(self):
        report = {"minecraft:stone": {"states": [{"id": 1}]}, "example:stone": {"states": [{"id": 2}]}}
        blocks, _ = sync.parse_blocks(report)
        self.assertIn("stone", blocks)
        self.assertIn("example:stone", blocks)

    def test_worldgen_tag_registry_types_preserve_worldgen_tag_families(self):
        self.assertEqual(sync.server_tag_registry("data/minecraft/tags/worldgen/structure/village.json"), ("structures", "minecraft:village"))
        self.assertEqual(sync.server_tag_registry("data/minecraft/tags/worldgen/placed_feature/trees.json"), ("placed_features", "minecraft:trees"))
        self.assertEqual(sync.server_tag_registry("data/minecraft/tags/worldgen/biome/is_overworld.json"), ("biomes", "minecraft:is_overworld"))

    def test_visual_filter_removes_project_only_ids_but_keeps_missing_official_ids_missing(self):
        visual_rows = {"stone": {"icon": "stone.png"}, "fake_block": {"icon": "fake.png"}}
        filtered = sync.filter_registry_entries(visual_rows, {"stone", "diamond_block"})
        self.assertEqual(filtered, {"stone": {"icon": "stone.png"}})
        self.assertNotIn("diamond_block", filtered, "missing official visual must not be invented")
        self.assertNotIn("fake_block", filtered, "noncanonical project-only ID must be retired")

    def test_sample_recipes_are_filtered_to_official_items_without_mixing_vanilla_recipes(self):
        source = {"source_status": "sample", "recipes": {
            "valid": {"result": "stone", "ingredients": {"cobblestone": 8}},
            "invalid_result": {"result": "project_fake_block", "ingredients": {"stone": 1}},
            "invalid_ingredient": {"result": "stone", "ingredients": {"not_vanilla": 1}},
        }}
        filtered = sync.filter_runtime_sample_recipes(source, {"stone", "cobblestone"})
        self.assertEqual(set(filtered["recipes"]), {"valid"})
        self.assertEqual(set(filtered["excluded_after_authoritative_item_check"]), {"invalid_result", "invalid_ingredient"})
        self.assertIn("not the complete vanilla recipe registry", filtered["source_status"])

    def test_root_render_and_entity_adapters_are_filtered_to_official_registry(self):
        doc = {"schema_version": 3, "blocks": {"stone": {}, "project_fake": {}}}
        filtered = sync.filter_block_render_document(doc, {"stone", "diamond_block"})
        self.assertEqual(set(filtered["blocks"]), {"stone"})
        self.assertNotIn("diamond_block", filtered["blocks"], "official missing render data is deliberately not synthesized")
        behaviors = sync.filter_registry_entries({"allay": {"runtime_supported": True}, "ghoul": {}}, {"allay"})
        self.assertEqual(set(behaviors), {"allay"})

    def test_entity_registry_is_preserved(self):
        entities = sync.parse_entities({"minecraft:allay": {"id": 1, "width": 0.35, "height": 0.6}, "minecraft:bee": {"id": 2}})
        self.assertEqual(entities["allay"]["width"], 0.35)
        self.assertEqual(entities["bee"]["id"], "bee")

if __name__ == "__main__":
    unittest.main(verbosity=2)
