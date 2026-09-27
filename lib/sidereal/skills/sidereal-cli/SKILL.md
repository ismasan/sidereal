---
name: sidereal-cli
description: Work with this Sidereal app from the terminal using bin/sid. Use to find out which commands the app has and what attributes they take, to dispatch (send or trigger) a command, or to open a console with the app loaded.
---

# bin/sid

`bin/sid` is this app's command line. Run it from the app's root, and start with:

```bash
bin/sid --help
```

It lists what it can do, including listing the app's commands, inspecting a command's payload and dispatching a command. Every subcommand takes `--help` too.

What `bin/sid` shows comes from the app's command classes, so ask it which commands exist and what they take, rather than searching the code for a list.

- `bin/sid commands list --schemas` lists every command with its payload's JSON Schema on the line below it: all you need to dispatch any of them, in one call. `bin/sid commands info NAME --json` prints one command's payload schema.
- `bin/sid commands dispatch --help` explains how to write attributes.
- Errors say what's wrong and exit with status 1. Fix the command line from the message.

Dispatching a command changes the app's data, like submitting a form. Only dispatch when you've been asked to, or to test the app on a development machine.
