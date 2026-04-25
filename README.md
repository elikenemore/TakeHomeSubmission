# DonkeySync Test Workspace

This folder is set up for testing and developing with DonkeySync.

## Quick Start

1. Open a terminal in this folder
2. Run `dsync build` to initialize the project
3. Run `dsync serve` to start the sync server
4. Open Roblox Studio and click the DonkeySync plugin button
5. Click "Connect" in the plugin UI

## Folder Structure

```
dsync-test/
├── src/              # Your synced Roblox code will appear here
├── default.project.json  # Project configuration (created on dsync build)
└── README.md         # This file
```

## Testing the Sync

Once connected:
- Edit any `.lua` file in the `src/` folder - changes sync to Roblox Studio
- Create scripts in Roblox Studio - they appear in `src/`
- Delete scripts - changes sync both ways

## Tips

- Scripts are organized by service (Workspace, ReplicatedStorage, etc.)
- `.server.lua` = Script
- `.client.lua` = LocalScript
- `.lua` = ModuleScript
- Each script has a `.meta.json` file with properties
