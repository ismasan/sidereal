# Progress

A Sidereal port of the Datastar [progress demo](https://github.com/starfederation/datastar/tree/main/examples/ruby/progress).

Clicking **Start** posts a single `StartProgress` command. Its `handle` block opens two concurrent `browser.stream` blocks — each in its own fiber, both multiplexing onto the same POST `/commands` SSE response:

1. A **progress stream** that mounts a `<circular-progress>` Web Component into `#work`, then patches the `$progress` signal 100 times from `0` to `100`. The custom element re-renders its SVG reactively.
2. An **activity stream** that resets `#activity` and appends log items at a slower cadence.

Demonstrates:

- `handle` with a custom block and multiple `browser.stream` calls for fiber-based concurrency
- `browser.patch_signals` driving a reactive Datastar signal
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

Click **Start** to watch the circular progress fill while activity items stream in on the right.
