---
name: sidereal-ui
description: Build this Sidereal app's UI out of Phlex pages and components that carry their own behaviour. Use to add a form and handle the command it sends, to give a page or component its own stylesheet, script or file, to install a component in the App, or to test a page's or component's command handlers with Sidereal::Testing::Harness. Also use when a handler never runs, or a stylesheet isn't linked. These are UI components under web/ui/, not the config-tree components that `dep` injects (see the sidereal-components skill).
---

# Pages and components that carry their own behaviour

The UI lives in `web/ui/`: pages (`Sidereal::Page`), components (`Sidereal::Components::BaseComponent`) and the layout. Each can declare what it needs next to its own code:

- the **commands** its forms send, and how to handle them, with `handle`;
- the **stylesheets, scripts and files** it uses, with `stylesheet`, `javascript`, `file`, `css` and `js`.

Put these declarations in the component that renders the form or uses the styles, not in `web/app.rb` or `web/assets/`. `web/app.rb` keeps what's app-wide: the session, `before_command`, the background `command` handlers, and which pages and components the app has.

## Install it, or nothing happens

Declaring only records. The App registers a component's handlers and assets when it installs the component:

```ruby
class App < Sidereal::App
  layout UI::Layout              # sets the layout, and installs its declarations
  component UI::Components::Chat # installs a component
  page UI::ChatPage              # mounts a page, and installs its declarations
end
```

**Rendering a component doesn't install it.** If `UI::ChatPage` renders `UI::Components::Chat`, then `page UI::ChatPage` installs the page's declarations, not Chat's. The app needs `component UI::Components::Chat` too. When it's missing, nothing raises: the form posts a command the app doesn't accept, or the page renders unstyled. So whenever you add `handle` or a stylesheet to a component, check that `web/app.rb` installs it.

## Handling the commands a form sends

```ruby
module UI
  module Components
    class Chat < Sidereal::Components::BaseComponent
      # Runs in the request, in the App that installs Chat, with its helpers:
      # browser, session, params, reject, dispatch, halt.
      handle Chats::SendMessage do |cmd|
        reject(text: 'is too long') if cmd.payload.text.size > 500

        # Hand slow or side-effecting work to a background handler.
        dispatch Chats::StoreMessage, text: cmd.payload.text, author: session[:username]
        browser.patch_elements Composer.new
      end

      # No block: the default dispatches the command itself, for a background
      # `command` handler in the App (or a Sourced decider) to handle.
      handle Chats::ClearChat

      def view_template
        command Chats::SendMessage do |f|
          f.text_field :text
          button(type: :submit) { 'Send' }
        end
      end
    end
  end
end
```

- `handle` runs while the browser waits. Keep it to validating, rejecting and answering the browser. Do slow work in a background `command` handler, reached with `dispatch`.
- The command reaching the block has been decoded, validated and passed through the App's `before_command`. An invalid form is rejected before the block runs.
- A page with a form for a command re-renders once that command is handled, unless the page calls `disable_causal_reactivity!` (see the docs on pages).
- A UI-only command, such as selecting something, can be defined inside the component that handles it: `Chat::SelectThread = Sidereal::Message.define('chat.select_thread') { ... }`. It's still a command the App accepts.
- If two installed components handle the same command, the last one installed wins.

## A component's own stylesheets, scripts and files

```ruby
class Chat < Sidereal::Components::BaseComponent
  stylesheet 'ui/chat.css', path: 'chat.css'   # web/ui/components/chat.css
  javascript 'ui/chat.js', path: 'chat.js'
  file 'ui/chat/avatar.svg', path: 'avatar.svg'

  # Inline, named after the class: ui/components/chat-1.css, -2.css...
  css <<~CSS
    .chat { display: grid; gap: 8px; }
  CSS
end
```

- A relative `path:` is relative to the file that calls `stylesheet`, as with `require_relative`, so the file sits next to the component.
- The first argument is the asset's name in the app. It must not clash with a file in `web/assets/`, or with another component's asset, so prefix it, as with `ui/`.
- The layout links stylesheets and scripts. A component links a file with `asset_url('ui/chat/avatar.svg')`.
- Stylesheets cascade in the order `web/app.rb` installs them: the layout first, then the components and pages, in the order of their lines. Put shared rules, such as variables, resets and buttons, in `web/assets/` or the layout, and a component's rules in the component.

## Testing the handlers

`spec/web/ui/welcome_page_spec.rb` is an example. `Sidereal::Testing::Harness` posts each command to a small app that subclasses `App` and has the component installed, so it goes through the same decoding, validation, `before_command` and session as a browser's form. What the handler dispatches is recorded instead of run.

```ruby
RSpec.describe UI::Components::Chat do
  subject(:harness) { Sidereal::Testing::Harness.new(described_class, app: App) }

  it 'stores the message' do
    result = harness.handle(Chats::SendMessage, { text: 'hi' }, session: { username: 'ada' })

    expect(result.dispatched.map(&:class)).to eq([Chats::StoreMessage])
    expect(result.dispatched.first.payload.author).to eq('ada')
    expect(result.elements.first).to include('id="composer"')
  end

  it 'rejects a blank message' do
    result = harness.handle(Chats::SendMessage, form: { 'text' => '' })

    expect(result).to be_rejected
    expect(result.errors).to have_key(:text)
  end
end
```

- `handle(CommandClass, payload, session:)`, or `form:` with the strings a form would post, to test invalid input.
- The `Result` has `status`, `command` (as the handler got it), `dispatched`, `errors` with `rejected?`, `elements` (the HTML patched into the page), `signals`, `events` and `session`.
- `spec_helper.rb` requires `sidereal/testing`. A spec whose handler uses config-tree components, such as `pubsub` or one injected with `dep`, needs `Sidereal.config.build!` first. So does passing `app: App`, since `App` reads its session secret from them.
- The harness tests the request side. Test background `command` handlers, deciders and the like separately.

## Details

- Command handlers on components, and the harness: https://ismasan.github.io/sidereal/#components-and-pages-own-command-handlers
- Assets on components: https://ismasan.github.io/sidereal/#components-and-pages-own-assets
- Pages, `on`, channels and causal reactivity: https://ismasan.github.io/sidereal/#pages
- Command forms: https://ismasan.github.io/sidereal/#command-forms
