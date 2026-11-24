#!/usr/bin/env python3
# 用 GitHub API 推送工程（本环境 git push 常因 SSL 断流失败）
import base64, json, os, pathlib, sys, urllib.request, urllib.error

TOKEN = os.environ.get("GH_TOKEN")
OWNER = "hao1265693413-arch"
REPO = "DYColorComment"
BRANCH = "build/dycolor-r2"
ROOT = pathlib.Path("/var/minis/workspace/DYColorComment")

API = "https://api.github.com"


def call(method, path, body=None, ok=(200, 201, 204)):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(API + path, data=data, method=method)
    req.add_header("Authorization", "token " + TOKEN)
    req.add_header("Accept", "application/vnd.github+json")
    if data:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")
        print(f"HTTP {e.code} {method} {path}: {detail[:400]}", file=sys.stderr)
        if e.code in ok:
            return {}
        raise


def main():
    # 1. 确保仓库存在
    try:
        call("GET", f"/repos/{OWNER}/{REPO}")
        print("repo exists")
    except urllib.error.HTTPError:
        call("POST", "/user/repos", {
            "name": REPO,
            "description": "TrollFools dylib probe: Douyin colored comment",
            "private": False,
            "auto_init": False,
        })
        print("repo created")

    # 空仓库没法建 blob，先用 contents API 落一个初始提交
    try:
        call("GET", f"/repos/{OWNER}/{REPO}/git/refs/heads")
    except urllib.error.HTTPError as e:
        if e.code == 409:
            call("PUT", f"/repos/{OWNER}/{REPO}/contents/README.md", {
                "message": "init",
                "content": base64.b64encode(b"# DYColorComment\n").decode(),
            })
            print("repo initialized with README")

    files = []
    for p in sorted(ROOT.rglob("*")):
        if p.is_file() and ".git" not in p.parts:
            rel = str(p.relative_to(ROOT))
            files.append(rel)

    tree = []
    for rel in files:
        content = (ROOT / rel).read_bytes()
        blob = call("POST", f"/repos/{OWNER}/{REPO}/git/blobs",
                    {"content": base64.b64encode(content).decode(), "encoding": "base64"})
        tree.append({"path": rel, "mode": "100644", "type": "blob", "sha": blob["sha"]})
        print("blob", rel, len(content))

    t = call("POST", f"/repos/{OWNER}/{REPO}/git/trees", {"tree": tree})
    c = call("POST", f"/repos/{OWNER}/{REPO}/git/commits",
             {"message": "DYColorComment probe r1", "tree": t["sha"], "parents": []})
    print("commit", c["sha"][:12])
    try:
        call("POST", f"/repos/{OWNER}/{REPO}/git/refs",
             {"ref": f"refs/heads/{BRANCH}", "sha": c["sha"]})
    except urllib.error.HTTPError:
        call("PATCH", f"/repos/{OWNER}/{REPO}/git/refs/heads/{BRANCH}", {"sha": c["sha"], "force": True})
    call("PATCH", f"/repos/{OWNER}/{REPO}", {"default_branch": BRANCH})
    print("branch ready:", BRANCH)


if __name__ == "__main__":
    main()