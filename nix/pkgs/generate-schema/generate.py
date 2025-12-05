import sys
import os
import json
import tempfile
import re
import subprocess

VERSIONS = {
    "1.30": "v1.30.1-standalone-strict",
    "1.31": "v1.31.14-standalone-strict",
    "1.32": "v1.32.10-standalone-strict",
    "1.33": "v1.33.6-standalone-strict",
    "1.34": "v1.34.2-standalone-strict",
}
REPO_URL = "https://github.com/yannh/kubernetes-json-schema.git"
DEFAULT_REPO_REF = "aeab6ebb38b801eb0e6b4dc6692ae68035054401" # 2025-12-06

# e.g. pod-v1.json
FILE_NAME_PATTERN = re.compile(r"^.+\-v\d+\.json$")

def get_nix_hash(file):
    # nix hash convert
    convert = subprocess.run(
        ["nix", "hash", "file", "--type", "sha256", file],
        capture_output=True,
        text=True
    )

    result = convert.stdout.strip()
    if not result:
        raise RuntimeError(f"Failed to convert hash for file {file}: {convert.stderr.strip()}")

    return result


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python generate.py <output-dir> <repo-ref>")
        sys.exit(1)

    output_dir = sys.argv[1].strip()
    os.makedirs(output_dir, exist_ok=True)
    ref = sys.argv[2].strip() if len(sys.argv) >=3 else DEFAULT_REPO_REF

    # prepare repository
    # make temp dir
    temp_dir = tempfile.mkdtemp()

    # sparse clone
    subprocess.run(
        ["git", "clone", "--filter=blob:none", "--sparse", REPO_URL],
        cwd=temp_dir,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    repository_dir = os.path.join(temp_dir, os.path.basename(REPO_URL).replace(".git", ""))

    for version, dir_name in VERSIONS.items():
        schemas = []
        print(f"Processing version {version}...")

        # sparse checkout
        subprocess.run(
            ["git", "sparse-checkout", "set", dir_name],
            cwd=repository_dir,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

        # checkout to ref
        subprocess.run(
            ["git", "checkout", ref],
            cwd=repository_dir,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

        manifest_dir = os.path.join(repository_dir, dir_name)

        # list files in dir
        file_names = os.listdir(manifest_dir)

        for file_name in file_names:
            file_path = os.path.join(manifest_dir, file_name)
            if not os.path.isfile(file_path):
                continue

            with open(file_path, "r") as f:
                schema_content = json.loads(f.read())

            # check file name pattern
            if not FILE_NAME_PATTERN.match(file_name):
                continue

            # read content and check apiVersion and kind
            print(f"  Processing file {file_name}...")

            # check content format
            if not schema_content.get("properties"):
                continue
            properties = schema_content["properties"]

            if not properties.get("apiVersion"):
                continue
            api_version_enum = properties["apiVersion"].get("enum")

            if not properties.get("kind"):
                continue
            kind_enum = properties["kind"].get("enum")

            if not api_version_enum or not kind_enum or len(api_version_enum) != 1 or len(kind_enum) != 1:
                continue

            api_version = api_version_enum[0]
            kind = kind_enum[0]

            # get hash
            nix_hash = get_nix_hash(file_path)
            download_url = f"https://raw.githubusercontent.com/yannh/kubernetes-json-schema/{ref}/{dir_name}/{file_name}"

            schemas.append({
                "apiVersion": api_version,
                "kind": kind,
                "url": download_url,
                "hash": nix_hash,
            })

        # write file
        schemas.sort(key=lambda x: (x["kind"], x["apiVersion"]))
        lines = []
        lines.append('[')
        for schema in schemas:
            lines.append('  {')
            lines.append(f'    apiVersion = "{schema["apiVersion"]}";')
            lines.append(f'    kind = "{schema["kind"]}";')
            lines.append(f'    url = "{schema["url"]}";')
            lines.append(f'    hash = "{schema["hash"]}";')
            lines.append('  }')
        lines.append(']')
        lines.append('')

        output_content = "\n".join(lines)

        output_path = os.path.join(output_dir, f"{version}.nix")
        with open(output_path, "w") as f:
            f.write(output_content)
