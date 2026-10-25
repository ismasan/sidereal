# CLAUDE.md

Sidereal is a Ruby gem for server-driven reactive web apps: a Rack router, typed messages and commands, pages that re-render over SSE (Datastar), Phlex for HTML, Async fibers, run on Falcon. The README is the reference for how it all works. This file only holds what you need to work on the code and what you'd otherwise trip over.

## Commands

- Tests: `bundle exec rspec`, or `bundle exec rspec spec/router_spec.rb:83` for one example
- Console: `bin/console`
- Setup: `bin/setup`
- Example app: `cd examples/todos && bundle exec falcon serve`

## Where things are explained

| Topic | README section |
| --- | --- |
| Commands, commanders, `dispatch`, scheduling | Commands, App |
| Pages, `on`, causal reactivity, channels | Pages |
| Command forms, `with_machine` | Command forms |
| Components, lifecycle, `dep` injection | Configuration |
| Falcon, workers, preload, custom backends, FS store | Running with Falcon |
| Retries, dead letters, exception reporting | Failure handling, retries and dead-lettering |
| JSON and forms codecs, custom types | Serialization |
| Sourced integration, deciders, machines, auto-publish | Using Sourced as a backend |

[sourced-component](https://github.com/ismasan/sourced-component) (local checkout `../sourced-system`) has the config tree, and [Sourced](https://ismasan.github.io/sourced/) (`../sourced`) has deciders, machines and the store.

## Testing rules

- `expect` syntax only. Monkey patching is disabled.
- **Never poke at internals.** No `instance_variable_get`/`_set`, and no `send(:private_method)`. Drive classes through their public API. If a test needs to observe state, add a public predicate. If it needs to set up a state with no public path, rework the test or extend the API.
- `spec_helper` calls `Sidereal.reload!` and `Sidereal.reset_config!` in a `before(:each)`, which RSpec runs inside every `around` hook. So a registry or component a spec installs has to go in a `before`, not an `around`, or it's dropped before the example runs.
- Specs that read components call `Sidereal.config.build!` once they've implemented what they need. A Sourced spec also calls `Sourced.reset!`, and `Sourced::Store::MessageCodec.reset!` when it defines message types the store must persist. A spec that starts Sourced sets `config.config!('sourced.store.install_tables') { true }` first.
- Store tests use `Sync { }` and `task.async` for concurrency.

## Traps

- **Rack 3:** response bodies are arrays (`[200, headers, [body]]`). **Phlex 2:** `view_template`, not `template`.
- **Payload schemas use real types** (`Types::Integer`, not `Types::Lax::Integer`). The codecs coerce at the edge. `Types::Integer.default(0)` plus a blank input is an error, because `''` is present. Use `.nullable` for optional numbers.
- **A custom payload type needs an encoder on each format it crosses.** Register it on `Plumb::Codec::JSON` and on `Plumb::Codec::Forms`, at load time, before any message type is defined. `examples/donations1/money.rb` shows how.
- **Codecs compile explicitly.** Nothing compiles on first use. An uncompiled codec raises `UnregisteredTypeError`.
- **The config tree locks at prepare.** `build!` and `start!` prepare too, so every message type, encoder and component declaration must be loaded first. Re-implementing a component replaces its hooks too.
- **`Sidereal.config` is untouched by `reload!`**, on purpose: it holds connections.
- **Generated `boot.rb` order is load-bearing:** requires → `LOADER.setup` → `use_file_system!` → `config/components/**` → `LOADER.eager_load`. Components come after `use_file_system!` because both implement `sidereal.store` and the last implementation wins. `eager_load` comes last because component files require the libraries app classes subclass. Specs guard this.
- **Sourced on SQLite:** never do IO while a store transaction holds the write lock. SQLite's busy timeout is C-level and freezes every fiber in the process.
- **Sourced tables come from a migration** (`bin/sid sourced install`). The store refuses to start without them.
- **Inside `Sidereal::Integrations::Sourced`**, a bare `Sourced` is the integration and a bare `CLI` is the integration's CLI. Inside its CLI, a bare `Error` is `Sidereal::Error`, which `Application.call` doesn't rescue. Qualify them all.
- **Samovar:** option keys are underscored (`@options[:skip_bundle]`). `one :name` and `one :path` collide with `Command` methods.
- **Sequel migrations are pinned to `Sequel::TimestampMigrator`.** `Sequel::Migrator.run` picks the integer migrator for an empty directory and raises.
- **console 1.38 truncates an attached exception's message at its first `(`**, so put the important part in the log message itself.
- **Falcon:** a boot failure has to stop the whole host, not one worker. `Service#run` does this through `boot_failed!` (see `lib/sidereal/falcon/environment.rb`).
