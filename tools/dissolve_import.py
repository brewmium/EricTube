#!/usr/bin/env python3
"""Dissolve imported.json into the overlay's genre tree.

One-time agentic re-org (2026-07-09): Eric's 59 YouTube playlists become the
local genre -> list -> sub-list structure, and the tier-shaped playlists
(Maybe Later, Maker Later, Macro Later, ericTAB) dissolve into pipeline
tiers. Backs up overlay.json first; merges with any existing overlay
content (palette saves win on tier). YouTube originals are untouched.
"""

import json
import shutil
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path

APP = Path.home() / "Library/Application Support/EricTube"
OVERLAY = APP / "overlay.json"
IMPORTED = APP / "imported.json"

GENRES = [
	"Shop & Metal", "3D & CAD", "Wood & Making", "Home & Land",
	"Tech & AI", "Auto", "Health & Life", "PewPew",
	"Civic & Society", "Games & Media", "Music", "Shared",
]


def L(genre, name, parent=None, tier=None):
	return {"genre": genre, "list": name, "parent": parent, "tier": tier}


MAP = {
	"Machinist": L("Shop & Metal", "Machinist"),
	"machinist - shaper": L("Shop & Metal", "Shaper", parent="Machinist"),
	"Welding": L("Shop & Metal", "Welding"),
	"Plasma CNC": L("Shop & Metal", "Plasma CNC"),
	"Casting": L("Shop & Metal", "Casting"),
	"Melty melt": L("Shop & Metal", "Melty melt"),
	"Blacksmithing": L("Shop & Metal", "Blacksmithing"),
	"2x42 Belt Grinder": L("Shop & Metal", "2x42 Belt Grinder"),
	"2x72": L("Shop & Metal", "2x72"),
	"Tool Geekery": L("Shop & Metal", "Tool Geekery"),
	"3d printing": L("3D & CAD", "3d printing"),
	"3D-Design": L("3D & CAD", "Design"),
	"3D - Slicing": L("3D & CAD", "Slicing", parent="3d printing"),
	"3D - Bambu": L("3D & CAD", "Bambu", parent="3d printing"),
	"Plasticity": L("3D & CAD", "Plasticity"),
	"Fusion 360": L("3D & CAD", "Fusion 360"),
	"Woodworking": L("Wood & Making", "Woodworking"),
	"Homestead": L("Home & Land", "Homestead"),
	"REMODEL": L("Home & Land", "REMODEL"),
	"Water Redo": L("Home & Land", "Water Redo"),
	"Chainsaw": L("Home & Land", "Chainsaw"),
	"energy": L("Home & Land", "energy"),
	"AI": L("Tech & AI", "AI"),
	"AI - Trust": L("Tech & AI", "Trust", parent="AI"),
	"IoT": L("Tech & AI", "IoT"),
	"Streaming Help": L("Tech & AI", "Streaming Help"),
	"prius": L("Auto", "prius"),
	"Subi": L("Auto", "Subi"),
	"AutoRepair": L("Auto", "AutoRepair"),
	"Auto": L("Auto", "Auto"),
	"stretching": L("Health & Life", "stretching"),
	"Body": L("Health & Life", "Body"),
	"Feldenkrais": L("Health & Life", "Feldenkrais"),
	"ADHD": L("Health & Life", "ADHD"),
	"Medicare": L("Health & Life", "Medicare"),
	"retire - prep": L("Health & Life", "retire - prep"),
	"PewPew": L("PewPew", "PewPew"),
	"Reloading": L("PewPew", "Reloading"),
	"Local Govt": L("Civic & Society", "Local Govt"),
	"City": L("Civic & Society", "City"),
	"Audits2Share": L("Civic & Society", "Audits2Share"),
	"non-disinfo": L("Civic & Society", "non-disinfo"),
	"WWTP": L("Civic & Society", "WWTP"),
	"history": L("Civic & Society", "history"),
	"smart": L("Civic & Society", "smart"),
	"Infinity Kingdom": L("Games & Media", "Infinity Kingdom"),
	"Fallout": L("Games & Media", "Fallout"),
	"TW": L("Games & Media", "TW (TopWar)"),
	"Movies": L("Games & Media", "Movies"),
	"Streaming Music": L("Music", "Streaming Music"),
	"Chill Musicscapes": L("Music", "Chill Musicscapes"),
	"Turntable": L("Music", "Turntable (gear)"),
	"Cindy Save": L("Shared", "Cindy Save"),
	"Cindy 2 Watch": L("Shared", "Cindy 2 Watch"),
	# Tier-shaped playlists dissolve into the pipeline.
	"Maybe Later": L(None, None, tier="maybe"),
	"ericTAB": L(None, None, tier="next"),
	"Maker Later": L("Wood & Making", "To Sort", tier="later"),
	"Macro Later": L("Civic & Society", "Macro", tier="later"),
}


def main():
	imported = json.loads(IMPORTED.read_text())
	if OVERLAY.exists():
		overlay = json.loads(OVERLAY.read_text())
		stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
		shutil.copy2(OVERLAY, OVERLAY.with_suffix(f".json.bak-{stamp}"))
	else:
		overlay = {"videos": [], "lists": [], "genres": []}

	fetched_at = imported.get("fetchedAt") or datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

	genres = overlay.get("genres") or []
	genre_id = {g["name"]: g["id"] for g in genres}
	for i, name in enumerate(GENRES):
		if name not in genre_id:
			gid = str(uuid.uuid4())
			genres.append({"id": gid, "name": name, "order": i})
			genre_id[name] = gid

	lists = overlay.get("lists") or []
	list_id = {}  # (genre, name) -> id
	for entry in lists:
		list_id[(entry.get("genreId"), entry["name"])] = entry["id"]

	def ensure_list(genre_name, list_name, yt_playlist_id=None):
		gid = genre_id.get(genre_name)
		key = (gid, list_name)
		if key not in list_id:
			lid = str(uuid.uuid4())
			lists.append({
				"id": lid, "name": list_name, "genreId": gid,
				"parentId": None, "youtubePlaylistId": yt_playlist_id,
			})
			list_id[key] = lid
		return list_id[key]

	# First pass: create every mapped list; second pass wires sub-lists.
	for title, m in MAP.items():
		if m["list"]:
			ensure_list(m["genre"], m["list"])
	for title, m in MAP.items():
		if m["list"] and m["parent"]:
			child = next(e for e in lists if e["id"] == list_id[(genre_id[m["genre"]], m["list"])])
			child["parentId"] = list_id[(genre_id[m["genre"]], m["parent"])]

	videos = {v["videoId"]: v for v in overlay.get("videos") or []}
	tiered = {"next": 0, "later": 0, "maybe": 0}

	for playlist in imported["playlists"]:
		m = MAP.get(playlist["title"]) or L(None, playlist["title"])
		lid = None
		if m["list"]:
			lid = ensure_list(m["genre"], m["list"])
			entry = next(e for e in lists if e["id"] == lid)
			if not entry.get("youtubePlaylistId"):
				entry["youtubePlaylistId"] = playlist["id"]
		for item in playlist["items"]:
			vid = item["videoId"]
			video = videos.get(vid)
			if video is None:
				video = {
					"videoId": vid,
					"title": item["title"],
					"channel": item.get("channelTitle") or "",
					"listIds": [],
					"archived": False,
					"addedAt": fetched_at,
				}
				videos[vid] = video
			if lid and lid not in video["listIds"]:
				video["listIds"].append(lid)
			if m["tier"] and not video.get("tier"):
				video["tier"] = m["tier"]
				tiered[m["tier"]] += 1

	overlay["videos"] = list(videos.values())
	overlay["lists"] = lists
	overlay["genres"] = genres
	OVERLAY.write_text(json.dumps(overlay, indent=2, sort_keys=True, ensure_ascii=False))

	print(f"genres: {len(genres)}")
	print(f"lists: {len(lists)}")
	print(f"videos: {len(videos)}")
	print(f"tiers: next={tiered['next']} later={tiered['later']} maybe={tiered['maybe']}")


if __name__ == "__main__":
	sys.exit(main())
