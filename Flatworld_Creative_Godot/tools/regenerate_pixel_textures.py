#!/usr/bin/env python3
"""Compatibility alias for the safe all-block texture generator.

This entry point intentionally does not use the retired generator that could mutate
blocks.json. It regenerates registered 16x16 swatches only, never adds/removes block
IDs and never rewrites the atlas map or tile indices.
"""
from improve_all_block_textures import main

if __name__ == "__main__":
    main()
