---
name: sidereal-sourced
description: Understand and inspect this app's event-sourced design with bin/sid sourced. Use to see its topology (commands, the events they produce, read models and automations, and how they connect) and the payload schemas of its commands and events, to find out what can happen or what did happen after a command, to read the messages in the store, or to check whether its consumer groups are running or failing.
---

# bin/sid sourced

This app stores its data as events with [Sourced](https://github.com/ismasan/sourced). `bin/sid sourced` describes how that works in this app. Run it from the app's root, and start with:

```bash
bin/sid sourced --help
```

It lists the commands for inspecting the app's Sourced setup. Every subcommand takes `--help` too.

## The design: what can happen

- `bin/sid sourced topology` prints the app as a tree: each command, the events it produces, the read models (projectors) and automations (reactions) that consume those events, and the commands those automations dispatch. Use it to answer "what happens after this command?" and to see which events a read model depends on.
- `bin/sid sourced topology --schemas` adds each command's and event's payload JSON Schema: what every message carries, in one call.

Ask `bin/sid sourced` about the app's commands, events, read models and automations rather than reading every decider, machine and projector to piece it together. Then open the class it names (in `system/`) for the details. If `boot.rb` declares components from `system/` with `from_dir`, each decider, projector or machine there is registered as the app boots, one per file as Zeitwerk names it (`system/todos.rb` defines `Todos`), so a new one needs no `Sourced.register`, unless `config/components/sourced.rb` passes `reactors: false`. Otherwise, register it in that file with `Sourced.register(Todos)`. The topology comes from the outputs each handler declares, and Sourced refuses to append or dispatch anything undeclared, so it lists everything that can happen. The one exception is a machine's data events: the topology lists the states a command moves a machine to, but not the other events its handler appends.

Machines (`Sourced::Machine`) appear in the topology like deciders. The event a machine appends when it enters a state is labelled `state`, such as `state door.runtime.opened`. What a machine does in a state (entry and exit actions, timers, starting and stopping child machines) appears as automations that name it: `automation actions(opened)  in door, state opened`. A machine accepts each of its commands only in some states. A command dispatched while no active state accepts it is acknowledged with no events, so it does nothing even when its payload is valid; `messages correlation` shows that it produced nothing. The topology doesn't show which states accept which commands; the machine's class does.

## The data: what did happen

- `bin/sid sourced messages list` prints the most recent messages in the store, oldest first, one per line with its id. `--limit N` shows more or fewer (default 100); `--tail` keeps printing new messages as they arrive. `--types 'todos.added,billing.*'` shows only those message types, and `--partition course_id=c1` only messages carrying that reference or tag (with several pairs, a message matches if every key it carries matches); both apply to `--tail` too.
- `bin/sid sourced messages correlation ID` prints every message in one workflow as a tree of what caused what: the command, the events it produced, the commands automations dispatched in response, and so on. `ID` is any message in the workflow, as `messages list` prints it. Use it to check what a dispatched command actually did.
- `bin/sid sourced groups list` lists the consumer groups (one per reactor) with their status, partitions, the furthest position each has read, and its retries. Use it to find a reactor that has failed, is retrying or was stopped, and why. Groups are registered when the app runs, so an app that has never run has none.

## Commands that change things

`groups stop NAME`, `groups start NAME` and `groups reset NAME` change what the running app does. Stopping a group stops its reactor consuming, and resetting one makes its reactor process every message again, which can re-run its side effects. `install` and `migration` write files into the app. Only run these when you've been asked to. To dispatch a command, use `bin/sid commands` (see the sidereal-cli skill).
