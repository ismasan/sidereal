# Chess — Sidereal + Sourced demo

Two-player event-sourced chess board with real-time SSE updates.

https://github.com/user-attachments/assets/478b86ed-56ef-43df-98bd-261b10a600f8

## What it demonstrates

- A `Sourced::Decider` (`Game`) handling commands, validating chess rules, emitting events.
- Per-game pubsub channels driving live SSE updates to two browser sessions plus spectators.
- Server-driven UI built from Phlex components and Datastar signals — no client framework.
- Session-based identity (just a username) wired into commands via Sidereal's `before_command` hook.
- Click-to-move UX implemented entirely with Datastar signals + the standard `command` form helper.

## Run it

```bash
bundle install
bundle exec rake db:sourced_migration
bundle exec rake db:migrate
bundle exec falcon host
```

Then open http://localhost:9296 in two browser windows (one private), log in as different users, and play.

The Sourced event-store dashboard is at http://localhost:9296/sourced.

## How a game flows

1. Visit `/`, enter a username — stored in the session.
2. Click "Start new game" → redirected to `/games/<id>` as **white**.
3. Share the URL with another logged-in user. They visit it as a spectator and click "Sit as black" to claim the seat.
4. Players take turns clicking source square then destination square. Invalid moves are rejected.
5. Sidebar shows captured material, the SAN move list, and current status (turn / check / mate).
6. Either player can resign on their turn. Pawn promotion auto-queens.

## Architecture notes

- Game state lives entirely in the event log — refreshing replays events to rebuild the board (the FEN is cached on the in-memory `GameView` projection).
- The chess gem (`chess`) is wrapped by `domain/chess_engine.rb` so swapping engines is a one-file change.
- Move history in the sidebar is read directly from the Sourced store via `read_partition`.
