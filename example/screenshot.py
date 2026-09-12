#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["playwright"]
# ///
"""shot.py HTML OUT WIDTH HEIGHT [CLICK_TEXT]: screenshot the viewport after clicking a tree node."""
import sys
from playwright.sync_api import sync_playwright
html, out, width, height = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
with sync_playwright() as p:
    b = p.chromium.launch()
    page = b.new_page(viewport={"width": width, "height": height}, device_scale_factor=2)
    page.goto("file://" + html)
    page.wait_for_timeout(300)
    if len(sys.argv) > 5:
        page.click(f"#tree .node:has-text('{sys.argv[5]}')")
        page.wait_for_timeout(300)
    page.screenshot(path=out)
    b.close()
print("ok")
