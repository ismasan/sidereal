# Chat

A multi-process chat room demo for Sidereal. Messages stream live between every connected browser via SSE, and mentioning `@bot ` in a message routes the prompt to an LLM (via [ruby_llm](https://github.com/crmne/ruby_llm)) and streams the reply back into the room.

The chat log is appended to `chat_messages.jsonl` — one JSON message per line — so history survives restarts.

## What it demonstrates

- **Cross-process store + pubsub.** `Sidereal::Store::FileSystem` and `Sidereal::PubSub::Unix` let several Falcon master processes share the same command queue and event bus on one machine. Run two terminals on different ports and they behave like one app.
- **Leader election.** `Sidereal::Elector::FileSystem` ensures only one process at a time runs the scheduled blocks, even with multiple masters up.
- **`schedule` DSL.** A "Tick campaign" runs a one-off after 10s, ticks every 3 seconds, and ends with a one-shot exit message — all defined inline in `app.rb`.
- **LLM integration.** The `command AskLLM` handler builds a `RubyLLM.chat` primed with the last 50 messages, asks the model, and dispatches the answer back as a regular `SendMessage`. A `Working` event renders a "Thinking…" bubble while the call is in flight.
- **Activity sidebar.** Every `SendMessage` also dispatches a `ChatNotify` event; the page's `on ChatNotify` reaction appends a line to a separate activity feed.
- **Session-based identity.** A `Login` command stores the username in the session; `before_command` stamps every subsequent command with that username so handlers never trust client input for the author.
- **Markdown rendering** of message bodies via Kramdown.

## Setup

```sh
cd examples/chat
bundle install
```

Create a `.env` file with your LLM API key:

```sh
OPENAI_API_KEY=sk-...
# or
ANTHROPIC_API_KEY=sk-ant-...
```

(Uncomment the matching `RubyLLM.configure` line in `app.rb` if you switch providers.)

## Run

```sh
bundle exec falcon host
```

Open <http://localhost:9293>, enter a username, and start chatting. Type `@bot what's the weather like on Mars?` to talk to the LLM.

### Multi-process

Spin up more masters in separate terminals, all backed by the same `tmp/sidereal-store/` and `tmp/sidereal-pubsub.sock`:

```sh
PORT=9294 bundle exec falcon host
PORT=9295 bundle exec falcon host
```

Messages posted on any port appear on every port in real time. Only one process holds the scheduler lock at a time — kill it and another takes over.

## Reset

```sh
rm chat_messages.jsonl
rm -rf tmp/sidereal-store tmp/sidereal-pubsub.sock tmp/sidereal-leader.lock
```
