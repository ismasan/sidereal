---
name: sidereal-components
description: Give this Sidereal app's classes the things they depend on (a database connection, an API client, a repository, a setting) as components, with `dep`. Use to add a connection, client or setting, to use one from a commander, App, decider, projector or other class, to write a class in system/ that other classes depend on, to replace one of Sidereal's own components, or to fix a boot error about a missing, undeclared or unbuilt component. Not for Phlex UI components and pages (see the sidereal-ui skill).
---

# Components and `dep`

The app's dependencies are **components**: values in a tree, `Sidereal.config`, each with a key, a type and a way to build it. Classes ask for them by key with `dep`, and get a reader for each. Don't open connections or build clients in a class, at the top of a file, or in a global constant. Make them components.

Nothing is built while the app loads. Each process builds its own components when it boots, in dependency order, so connections are never shared across a fork.

## Using a component in a class

```ruby
class Orders < Sidereal::Commander
  dep :db                          # a `db` reader, for the `db` component
  dep 'repos.orders' => 'orders'   # an `orders` reader, for `repos.orders`

  command PlaceOrder do |cmd|
    orders.insert(cmd.payload)
  end
end
```

- The reader is named after the key's last segment. A hash renames it. A name the class already has a method for raises `Sourced::Component::InjectionError`, so rename it: `dep 'sidereal.store' => 'commands'`.
- `Sidereal::Commander` and `Sidereal::App` take `dep`, and with the Sourced integration so do `Sourced::Decider` and `Sourced::Projector`. Any other class needs `extend Sidereal::Deps` first.
- On an App, `dep` covers its `handle` and `command` blocks.
- `dep` adds keyword arguments to the constructor, which default to the components' values. They're read when an object is created, not when the class loads. A test can pass its own: `Orders.new(db: test_db)`.

## Declaring a component

Put declarations for connections, clients and settings in a file in `config/components/`. `boot.rb` loads every file there.

```ruby
# config/components/mailer.rb
require 'mailer_sdk'   # requires at the top, outside the blocks

Sidereal.config.declare('mailer', MailerSDK::Client, description: 'Sends transactional email')
Sidereal.config.component!('mailer') do
  build { MailerSDK::Client.new(api_key: ENV.fetch('MAILER_API_KEY')) }
  teardown(&:close)
end

# Built from other components: the block gets their values, in order
Sidereal.config.declare('notifier', Notifier)
Sidereal.config.config!('notifier', ['mailer']) { |mailer| Notifier.new(mailer) }

# A setting with a default
Sidereal.config.declare('orders.page_size', Integer) { 20 }
```

- `declare(key, type, description:)` adds a typed component. A block gives it a default. Building a value that doesn't match the type fails the boot. Give it a `description:` saying what it's for: `bin/sid system tree` and `bin/sid system graph` print it under the component.
- `component!(key, deps) { build ...; start ...; stop ...; teardown ... }` implements a component. It's built once per process.
- `config!(key, deps) { |*values| ... }` is the short form for a component that only builds.
- Implementing a key again replaces it, hooks included. The last one wins. That's how an app replaces one of Sidereal's own, such as `sidereal.store` or `sidereal.workers.count`.

## Classes in system/ as components

A class in a directory under `system/` that includes `Sourced::Component::Installable` is a component, keyed by its path. `system/mailers/client.rb`, which defines `Mailers::Client`, is the `mailers.client` component. Its `dep`s are what it's built with.

```ruby
# system/mailers/client.rb
class Mailers::Client
  include Sourced::Component::Installable
  extend Sidereal::Deps
  dep :mailer

  def welcome(email) = mailer.deliver(to: email, template: 'welcome')
end

# Anywhere else in system/ or web/
dep 'mailers.client'   # a `client` reader
```

- **A new instance is built on every read.** Keep state in the components it `dep`s, not in the instance.
- **A module, or a class used through its class methods,** is a component through its own `__install_component`, with the module itself as the value. `Installable` doesn't work for these, because it builds the value with `new`:

  ```ruby
  # system/pricing/rules.rb: the pricing.rules component
  module Pricing::Rules
    def self.__install_component(c) = c.declare(Module).config { self }

    def self.discount(total) = total > 100 ? 10 : 0
  end

  dep 'pricing.rules'   # elsewhere: a `rules` reader, which returns Pricing::Rules
  ```

  For a class, use `c.declare(Class).config { self }`. `dep` injects through the constructor, so class methods can't use it. A component that needs other components has to be an `Installable` class.
- **Only files in a directory count.** A file directly in `system/` can't be a component.
- **Each directory owns its keys.** Don't declare `mailers.*` anywhere else, or it's dropped.
- **Don't `dep` them from `config/components/`.** A class a file there loads, such as one passed to `Sourced.register`, loads before the `system/` components are declared, so it can't `dep` them. Sourced deciders and projectors in `system/` are registered by the scan that declares those components, so they can.

## Inspecting and debugging

- `bin/sid system tree` prints every component, its status, who implemented it and what it's for.
- `bin/sid system graph` shows what depends on what.
- The tree locks when the app prepares, which happens on boot. Every declaration has to load before then. A boot error names the component that's undeclared, unimplemented, part of a cycle or of the wrong type.
- Outside a running app (rake tasks, scripts, specs), reading a component raises `Sourced::Component::NotBuiltError` until `Sidereal.config.build!` has been called, after the app has loaded.

## Details

- Sidereal's docs on configuration, the lifecycle and `dep`: https://ismasan.github.io/sidereal/#configuration and https://ismasan.github.io/sidereal/#injecting-components-into-classes
- Sidereal's own components, which the app can replace: https://ismasan.github.io/sidereal/#sidereals-components
- Everything a component can do (hooks, ENV components, aliases, wildcard deps, directories): https://github.com/ismasan/sourced-component
