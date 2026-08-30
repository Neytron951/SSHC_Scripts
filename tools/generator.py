import os
import json

scripts = []
scripts_dir = "scripts"

for author in os.listdir(scripts_dir):
    author_path = os.path.join(scripts_dir, author)
    if not os.path.isdir(author_path): continue

    for script_name in os.listdir(author_path):
        script_path = os.path.join(author_path, script_name)
        if not os.path.isdir(script_path): continue

        meta_file = os.path.join(script_path, "metadata.json")
        cmd_file = os.path.join(script_path, "command.sh")

        if os.path.exists(meta_file) and os.path.exists(cmd_file):
            with open(meta_file, 'r', encoding='utf-8') as f:
                meta = json.load(f)
            with open(cmd_file, 'r', encoding='utf-8') as f:
                cmd = f.read()

            # Combine into MarketScript format
            script_data = {
                "id": f"{author}_{script_name}",
                "name": meta["name"],
                "description": meta["description"],
                "command": cmd,
                "author": author,
                "category": meta["category"],
                "compatibleOs": meta.get("compatibleOs", []),
                "isDangerous": meta.get("isDangerous", False),
                "githubUrl": f"https://github.com/Neytron951/SSHC_Scripts/tree/main/scripts/{author}/{script_name}"
            }
            scripts.append(script_data)

with open("market.json", "w", encoding='utf-8') as f:
    json.dump(scripts, f, indent=2, ensure_ascii=False)
