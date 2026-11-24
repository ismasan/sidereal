# Chess — Sidereal + Sourced demo

Two-player event-sourced chess board with real-time SSE updates.

https://github.com/user-attachments/assets/478b86ed-56ef-43df-98bd-261b10a600f8

## What it demonstrates

- A `Sourced::Decider` (`Game`) handling commands, validating chess rules, emitting events.
- Per-game pubsub channels driving live SSE updates to two browser sessions plus spectators.
- Server-driven UI built from Phlex components and Datastar signals — no client framework.
- Session-based identity (just a username) wired into commands via Sidereal's `before_command` hook.
- Click-to-move UX implemented entirely with Datastar signals + the standard `command` form helper.
- Components that handle the commands their forms send: `Square` (selecting a piece, moving it), `SeatPanel` (sitting as black) and `NewGameButton` (starting a game) each declare `handle` next to their form, and `ChessApp` installs them with `component`. `GamePage` handles resigning the same way.
- Testing those handlers with `Sidereal::Testing::Harness`, in `spec/ui/`: each command is handled as `ChessApp` handles it, with a session, and the spec checks what the handler dispatched and what it sent the browser.
- Components that declare their own stylesheets: `Square` and `SeatPanel` have a `.css` file next to their `.rb` file, and `StatusBanner` has an inline `css` block. Installing a component registers them. The rest of the styles are in `public/css/main.css`.

## Run it

```bash
bundle install
bin/sid db migrations run
bundle exec falcon host
```

Then open http://localhost:9296 in two browser windows (one private), log in as different users, and play.

The Sourced event-store dashboard is at http://localhost:9296/sourced.

Run the specs, the domain's and the components' handlers', with `bundle exec rspec`.

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
- Move history in the sidebar is read directly from the Sourced store, through `Game.history_selector`.
