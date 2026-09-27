---
name: sidereal-sourced
description: Understand this app's event-sourced design with bin/sid sourced. Use to see its topology (commands, the events they produce, read models and automations, and how they connect) and the payload schemas of its commands and events, or to find out what happens after a command.
---

# bin/sid sourced

This app stores its data as events with [Sourced](https://github.com/ismasan/sourced). `bin/sid sourced` describes how that works in this app. Run it from the app's root, and start with:

```bash
bin/sid sourced --help
```

It lists the commands for inspecting the app's Sourced setup. Every subcommand takes `--help` too.

- `bin/sid sourced topology` prints the app as a tree: each command, the events it produces, the read models (projectors) and automations (reactions) that consume those events, and the commands those automations dispatch. Use it to answer "what happens after this command?" and to see which events a read model depends on.
- `bin/sid sourced topology --schemas` adds each command's and event's payload JSON Schema: what every message carries, in one call.

Ask `bin/sid sourced` about the app's commands, events, read models and automations rather than reading every decider and projector to piece it together. Then open the class it names (in `system/`) for the details. The topology is worked out from the handlers' source code, so a message a handler builds dynamically may be missing from it.

These commands only describe the app; they change nothing. To dispatch a command, use `bin/sid commands` (see the sidereal-cli skill).
