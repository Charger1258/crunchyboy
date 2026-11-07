"""Build a public SideStore source from a verified device IPA. No signing secrets."""
import argparse
from datetime import date
import html
import json
from pathlib import Path
import plistlib
import re
import shutil
from urllib.parse import quote, urlparse
import zipfile

BASE_URL = "https://crunchyboy-1be9d-updates.web.app"
RELEASE_REPO = "Charger1258/crunchyboy-releases"
BUNDLE = "com.streamanime.iphone"
ROOT = Path(__file__).resolve().parents[1]


def build_site(ipa, output, notes, release_date=None, previous=None, base_url=BASE_URL):
    ipa, output = Path(ipa), Path(output)
    address = urlparse(base_url)
    if address.scheme != "https" or not address.netloc or address.query or address.fragment:
        raise ValueError("An HTTPS publishing address is required")
    base_url = base_url.rstrip("/")
    with zipfile.ZipFile(ipa) as archive:
        infos = [n for n in archive.namelist() if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", n)]
        if len(infos) != 1:
            raise ValueError("Expected exactly one device application")
        info = plistlib.loads(archive.read(infos[0]))
        entitlement_path = infos[0].replace("Info.plist", "archived-expanded-entitlements.xcent")
        entitlements = plistlib.loads(archive.read(entitlement_path)) if entitlement_path in archive.namelist() else {}
    if info.get("CFBundleIdentifier") != BUNDLE or "iPhoneOS" not in info.get("CFBundleSupportedPlatforms", []):
        raise ValueError("Expected the Stream Anime iPhone device build")
    version, build = str(info["CFBundleShortVersionString"]), str(info["CFBundleVersion"])
    if not re.fullmatch(r"\d+\.\d+\.\d+", version) or not re.fullmatch(r"\d+", build):
        raise ValueError("Release version and build number must be numeric")
    file_name = f"StreamAnime-{version}-{build}.ipa"
    download_url = f"https://github.com/{RELEASE_REPO}/releases/download/v{version}/{file_name}"
    versions = []
    if previous:
        apps = previous.get("apps", [])
        if len(apps) != 1 or apps[0].get("bundleIdentifier") != BUNDLE:
            raise ValueError("Previous feed belongs to a different application")
        versions = apps[0].get("versions", [])
        if versions:
            old = versions[0]
            if tuple(map(int, version.split("."))) < tuple(map(int, old["version"].split("."))):
                raise ValueError("Refusing to publish an older release")
            if version == old["version"] and download_url != old["downloadURL"]:
                raise ValueError("Bump the marketing version so SideStore detects the update")
    current = {"version": version, "date": release_date or date.today().isoformat(),
               "localizedDescription": notes, "downloadURL": download_url,
               "size": ipa.stat().st_size, "minOSVersion": info.get("MinimumOSVersion", "17.0")}
    if versions and versions[0]["downloadURL"] == download_url:
        current["date"] = versions[0]["date"]
    versions = [current] + [v for v in versions if v["version"] != version][:2]
    app = {"name": "Stream Anime", "bundleIdentifier": BUNDLE, "developerName": "Stream Anime",
           "subtitle": "Your anime library, across your devices.",
           "localizedDescription": "Browse anime, save shows, and keep your profiles and watch progress in sync.",
           "iconURL": f"{base_url}/icon.png", "tintColor": "FF7A00", "category": "entertainment",
           "versions": versions, "version": version, "versionDate": current["date"],
           "downloadURL": download_url, "size": current["size"],
           "appPermissions": {"entitlements": sorted(entitlements), "privacy": {
               k: v for k, v in info.items() if k.startswith("NS") and k.endswith("UsageDescription")}}}
    source = {"name": "Stream Anime", "identifier": "com.streamanime.updates",
              "subtitle": "Stream Anime updates", "website": base_url,
              "iconURL": f"{base_url}/icon.png", "tintColor": "FF7A00", "apps": [app], "news": []}
    output.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(ROOT / "Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png", output / "icon.png")
    (output / "source.json").write_text(json.dumps(source, indent=2) + "\n", encoding="utf-8")
    source_url = f"{base_url}/source.json"
    add_url = "sidestore://source?url=" + quote(source_url, safe="")
    page = '''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow"><title>Stream Anime updates</title>
<style>*{box-sizing:border-box}body{margin:0;background:#0d0d10;color:#f6f6f7;font:16px/1.6 system-ui,sans-serif}main{max-width:620px;margin:auto;padding:64px 24px}img{width:88px;border-radius:22px}h1{font-size:36px;line-height:1.15;margin:24px 0 8px}p{color:#bdbdc6}a{color:#ff962e}.primary{display:block;text-align:center;background:#ff7a00;color:#111;text-decoration:none;font-weight:750;padding:15px;border-radius:12px;margin:28px 0 20px}section{background:#1b1b21;border:1px solid #303038;border-radius:16px;padding:22px;margin:28px 0}h2{font-size:20px;margin:0 0 12px}ol{padding-left:22px;color:#d7d7df}li{margin:12px 0}code{display:block;overflow-wrap:anywhere;background:#101014;padding:14px;border-radius:8px;font-size:13px}small{color:#aaaab5}.version{color:#ff962e}footer{margin-top:32px}</style>
<main><img src="icon.png" alt="Stream Anime icon"><h1>Stream Anime</h1><p>New releases, in SideStore.</p>
<a class="primary" href="ADD_URL">Add to SideStore</a>
<section><h2>Set up once</h2><ol><li>Open this page on your iPhone with SideStore installed.</li><li>Tap <strong>Add to SideStore</strong> and confirm the source.</li><li>Find <strong>Stream Anime</strong> in SideStore. Future releases appear there as updates.</li></ol><small>If the button does not open SideStore, paste this address into SideStore's Add Source screen:</small><code>SOURCE_URL</code></section>
<section><h2>Latest release <span class="version">VERSION</span></h2><p>NOTES</p><a href="DOWNLOAD_URL">Download IPA directly</a></section>
<footer><small>SideStore signs and installs updates on your phone. Keep its local VPN connected while updating. Use the same Apple account and update the existing app; do not delete it first.</small></footer></main></html>'''
    for key, value in {"ADD_URL": add_url, "SOURCE_URL": source_url, "VERSION": version,
                       "NOTES": notes, "DOWNLOAD_URL": download_url}.items():
        page = page.replace(key, html.escape(value, quote=True))
    (output / "index.html").write_text(page, encoding="utf-8")
    return source


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("ipa", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--notes", required=True)
    parser.add_argument("--date")
    args = parser.parse_args()
    build_site(args.ipa, args.output, args.notes, args.date)
