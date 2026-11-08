#!/usr/bin/env python3
"""Convert the Android app's ic_*.xml vector drawables into template SVG image sets.

Usage: import-android-icons.py ../roamtty/app/src/main/res/drawable App/Roamtty/Resources/Assets.xcassets/Icons
The path data is shared verbatim, so iOS draws the same glyphs as Android.
"""
import json, re, sys, xml.etree.ElementTree as ET
from pathlib import Path

A = "{http://schemas.android.com/apk/res/android}"
SKIP = {"ic_launcher_ghost", "ic_launcher_monochrome", "ic_launcher_terminal", "ic_notification", "ic_startup"}
source, target = Path(sys.argv[1]), Path(sys.argv[2])
target.mkdir(parents=True, exist_ok=True)
(target / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}, "properties": {"provides-namespace": False}}, indent=2))

def paint(value):
    if not value or value.endswith("transparent") or value == "#00000000": return "none"
    return "#000000"

count = 0
for drawable in sorted(source.glob("ic_*.xml")):
    name = drawable.stem
    if name in SKIP or (name.startswith("ic_os_") and name != "ic_os_server"): continue
    root = ET.parse(drawable).getroot()
    if root.tag != "vector": continue
    width, height = root.get(A + "viewportWidth"), root.get(A + "viewportHeight")
    paths = []
    for path in root.iter("path"):
        attrs = {"d": path.get(A + "pathData"), "fill": paint(path.get(A + "fillColor", "#FF000000"))}
        if path.get(A + "strokeColor"):
            attrs.update({"stroke": paint(path.get(A + "strokeColor")), "stroke-width": path.get(A + "strokeWidth", "1"),
                          "stroke-linecap": path.get(A + "strokeLineCap", "butt"), "stroke-linejoin": path.get(A + "strokeLineJoin", "miter")})
        if path.get(A + "fillType") == "evenOdd": attrs["fill-rule"] = "evenodd"
        paths.append("<path " + " ".join(f'{k}="{v}"' for k, v in attrs.items()) + "/>")
    svg = f'<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 {width} {height}">' + "".join(paths) + "</svg>\n"
    folder = target / (name + ".imageset")
    folder.mkdir(exist_ok=True)
    (folder / (name + ".svg")).write_text(svg)
    (folder / "Contents.json").write_text(json.dumps({"images": [{"filename": name + ".svg", "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1},
        "properties": {"preserves-vector-representation": True, "template-rendering-intent": "template"}}, indent=2))
    count += 1
print(f"Imported {count} icons")
