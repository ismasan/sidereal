---
name: sidereal-cli
description: Work with this Sidereal app from the terminal using bin/sid. Use to find out which commands the app has and what attributes they take, to dispatch (send or trigger) a command, to see which components the app is made of and how they depend on each other, to inspect queued, scheduled and failed (dead-lettered) commands, or to open a console with the app loaded.
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
- `bin/sid system tree` prints the components the app is made of (its database, its integrations and so on) and who implemented each; `bin/sid system graph` shows how they depend on each other. Use them to see how the app is put together, or why it fails to boot.
- `bin/sid store list` shows the commands waiting to run, scheduled, being handled and dead-lettered (failed for good), with each failure's exception; `bin/sid store show ID` prints one message's payload and backtrace. It's only there when the app uses Sidereal's file system store. Use it to find out why a command didn't do what was expected.
- Errors say what's wrong and exit with status 1. Fix the command line from the message.

Dispatching a command changes the app's data, like submitting a form, and so do `bin/sid store requeue` (which runs a failed command again) and `bin/sid store delete`. Only do them when you've been asked to, or to test the app on a development machine.
