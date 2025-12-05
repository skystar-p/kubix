import requests
import sys
import os
import re
import subprocess

VERSIONS = {
    "1.30": "v1.30.1-standalone-strict",
    "1.31": "v1.31.14-standalone-strict",
    "1.32": "v1.32.10-standalone-strict",
    "1.33": "v1.33.6-standalone-strict",
    "1.34": "v1.34.2-standalone-strict",
}

# e.g. pod-v1.json
FILE_NAME_PATTERN = re.compile(r"^.+\-v\d+\.json$")

def get_nix_hash(url):
    # nix-prefetch-url
    prefetch = subprocess.run(
        ['nix-prefetch-url', '--type', 'sha256', url],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )

    base32_hash = prefetch.stdout.strip()

    # nix hash convert
    convert = subprocess.run(
        ['nix', 'hash', 'convert', '--hash-algo', 'sha256', base32_hash],
        capture_output=True,
        text=True
    )

    result = convert.stdout.strip()
    if not result:
        raise RuntimeError(f"Failed to convert hash for URL {url}: {convert.stderr.strip()}")

    return result


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: python generate.py <output-dir>")
        sys.exit(1)

    output_dir = sys.argv[1].strip()
    os.makedirs(output_dir, exist_ok=True)


    for version, dir_name in VERSIONS.items():
        schemas = []
        print(f"Processing version {version}...")
        api_url = f"https://api.github.com/repos/yannh/kubernetes-json-schema/contents/{dir_name}"
        response = requests.get(api_url)

        for file_info in response.json():
            file_name = file_info["name"]

            # check file name pattern
            if not FILE_NAME_PATTERN.match(file_name):
                continue

            # download content and check apiVersion and kind
            print(f"  Processing file {file_name}...")
            download_url = file_info["download_url"]
            schema_content = requests.get(download_url).json()

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
            nix_hash = get_nix_hash(download_url)

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
