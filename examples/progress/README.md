# Progress

A Sidereal port of the Datastar [progress demo](https://github.com/starfederation/datastar/tree/main/examples/ruby/progress).

Clicking **Start** posts a single `StartProgress` command, which is picked up by a worker fiber running the `command StartProgress` handler. From there the handler uses `broadcast` to publish a stream of events — `ProgressStarted`, `ProgressTicked`, `ActivityLogged`, `ProgressCompleted` — onto the `'system'` pubsub channel.

`ProgressPage` reacts to those events with `on SomeMessage do |evt| ... end` blocks that patch elements or signals back to the browser over SSE. Because the events travel through pubsub, **every connected tab** sees the updates in real time, not just the one that clicked Start.

Demonstrates:

- `command` handler with `broadcast` for pubsub fan-out across clients
- Sibling fibers via `Async do ... end` for concurrent event streams (fast progress ticks + slow activity log)
- Page `on Message` reactions driving `browser.patch_elements` and `browser.patch_signals`
- Rendering a custom HTML element from Phlex via `register_element`
- Serving static JS/CSS from `public/`

## Setup

```sh
cd examples/progress
bundle install
```

## Run

```sh
bundle exec falcon host
```

Falcon reads `falcon.rb` from the current directory and serves on [http://localhost:9294](http://localhost:9294).

Open the page in two tabs, then click **Start** in one tab — both tabs will render the same progress ring and activity log as the events fan out over pubsub.
