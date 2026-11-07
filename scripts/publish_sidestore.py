"""Publish an approved app-only GitHub release and Firebase SideStore feed."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
from urllib.error import HTTPError
from urllib.parse import urlparse
from urllib.request import Request, urlopen

from sidestore_source import BASE_URL, RELEASE_REPO, ROOT, build_site


def fetch(url):
    with urlopen(url, timeout=60) as response:
        return response.read()


def publish_binary(ipa, version, notes):
    # Use only the existing GitHub credential in memory; never print or persist it.
    result = subprocess.run(["git", "-C", str(ROOT), "credential", "fill"],
        input="protocol=https\nhost=github.com\nusername=Charger1258\n\n", text=True,
        capture_output=True, check=True,
        env=dict(os.environ, GIT_TERMINAL_PROMPT="0", GCM_INTERACTIVE="Never"))
    credential = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
    token = credential["password"]

    def api(path, payload=None, content_type="application/json"):
        url = path if path.startswith("https://uploads.github.com/") else "https://api.github.com" + path
        data = payload if isinstance(payload, bytes) else json.dumps(payload).encode() if payload is not None else None
        headers = {"Authorization": "Bearer " + token, "Accept": "application/vnd.github+json",
                   "User-Agent": "StreamAnime-release-publisher", "Content-Type": content_type}
        with urlopen(Request(url, data=data, headers=headers), timeout=120) as response:
            return json.load(response)

    try:
        repository = api("/repos/" + RELEASE_REPO)
    except HTTPError as error:
        if error.code != 404:
            raise
        if api("/user")["login"] != "Charger1258":
            raise ValueError("The release repository must be created by Charger1258")
        repository = api("/user/repos", {"name": RELEASE_REPO.split("/")[1], "private": False,
            "description": "Public Stream Anime app downloads. Application source code is kept in a separate private repository.",
            "auto_init": True, "has_issues": False, "has_projects": False, "has_wiki": False})
    if repository["full_name"] != RELEASE_REPO or repository["private"]:
        raise ValueError("Expected the separate public app-download repository")
    tag = "v" + version["version"]
    try:
        release = api(f"/repos/{RELEASE_REPO}/releases/tags/{tag}")
    except HTTPError as error:
        if error.code != 404:
            raise
        release = api(f"/repos/{RELEASE_REPO}/releases", {"tag_name": tag,
            "target_commitish": repository["default_branch"], "name": "Stream Anime " + version["version"],
            "body": notes, "draft": False, "prerelease": False})
    name = Path(urlparse(version["downloadURL"]).path).name
    existing = next((a for a in release["assets"] if a["name"] == name), None)
    digest = hashlib.sha256(ipa.read_bytes()).hexdigest()
    if existing:
        remote_digest = existing.get("digest")
        if remote_digest is None:
            remote_digest = "sha256:" + hashlib.sha256(fetch(existing["browser_download_url"])).hexdigest()
        if existing["size"] != ipa.stat().st_size or remote_digest != "sha256:" + digest:
            raise ValueError("Published release files are immutable; bump the version")
    else:
        upload = release["upload_url"].split("{", 1)[0] + "?name=" + name
        api(upload, ipa.read_bytes(), "application/octet-stream")
    if hashlib.sha256(fetch(version["downloadURL"])).hexdigest() != digest:
        raise ValueError("The public app download checksum did not match")
    print("Verified public app download:", version["downloadURL"])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--notes", required=True)
    parser.add_argument("--date")
    parser.add_argument("--prepare-only", action="store_true")
    args = parser.parse_args()
    previous = None
    try:
        previous = json.loads(fetch(BASE_URL + "/source.json"))
    except HTTPError as error:
        if error.code != 404:
            raise
    output = ROOT / "build/sidestore-site"
    # Only this generated staging directory is replaced, never source or local libraries.
    if output.exists():
        output.resolve().relative_to(ROOT.resolve())
        if output.is_symlink():
            raise ValueError("Refusing to replace a symlinked staging directory")
        shutil.rmtree(output)
    source = build_site(args.ipa, output, args.notes, args.date, previous=previous)
    if not args.prepare_only:
        publish_binary(args.ipa, source["apps"][0]["versions"][0], args.notes)
        firebase = ROOT / "firebase/node_modules/firebase-tools/lib/bin/firebase.js"
        subprocess.run(["node", str(firebase), "deploy", "--only", "hosting", "--config", "firebase-hosting.json",
                        "--project", "crunchyboy-1be9d", "--non-interactive"], cwd=ROOT, check=True)
        # Confirm the published feed points to the just-approved version.
        live = json.loads(fetch(BASE_URL + "/source.json"))
        if live["apps"][0]["versions"][0] != source["apps"][0]["versions"][0]:
            raise RuntimeError("The live update feed did not match the approved release")
        print("Published:", BASE_URL + "/source.json")


if __name__ == "__main__":
    main()
