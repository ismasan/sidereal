# Machine

A [Sidereal](https://github.com/ismasan/sidereal) app demonstrating Sourced's statecharts: a holiday booking modelled as a `Sourced::Machine` (`system/holiday_booking.rb`).

- `StartBooking` enters `BookingStarted`, whose **parallel regions** — flight, hotel, extras — are filled in any order.
- The hotel region's `HotelChosen` **nests** room and board regions; choosing another hotel re-enters it and starts both over.
- Each region ends at a final checkpoint; `done` joins move the hotel to `HotelConfirmed` and the booking to `ItineraryReady` in the same decision.
- Checkout holds the itinerary with an `after` timer (`HOLD_SECONDS`, default 180; `HOLD_SECONDS=10 bin/dev` to watch it expire). `Pay => BookingConfirmed | nil` stays put on a declined card (any card ending in 0000).
- `CancelBooking` on `BookingStarted` exits every region at once.

A booking has two tabs sharing one frame (`web/ui/booking_frame.rb`: header, tabs, the trip's basket and the history feed):

- **Booking** (`/bookings/:id`, `web/ui/booking_page.rb`): only the forms the machine's current configuration accepts.
- **Diagram** (`/bookings/:id/diagram`, `web/ui/diagram_page.rb`): `UI::Components::Statechart` draws the machine as SVG from `Machine#to_h`, lighting the active checkpoints and the transitions available next.

Both re-render on every event the machine appends (`on HolidayBooking`). On wide screens the history feed lists every command and event of the booking; each one links to either tab as the booking was at that step (`/bookings/:id/at/:step`, `/bookings/:id/diagram/at/:step`), rendered read-only from the first `step` messages. The Sourced dashboard is mounted at `/sourced`.

The Gemfile points Sourced at a local checkout; swap in the commented-out `github:` line to use Sourced's `main` instead.

## Run

```sh
bundle install
bin/sid db migrations run
bin/dev
```

Then open <http://localhost:9292>. `PORT`, `HOST` and `COUNT` (worker processes) can be set in the environment.

The migrations in `db/migrations/` are committed and `storage/` isn't, so `bin/sid db migrations run` is how a checkout gets its database — copy one over instead if you'd rather keep the data.

`bin/dev` runs `bundle exec falcon host` and reloads the app whenever a Ruby file changes. Reloading needs a file watcher: [watchexec](https://github.com/watchexec/watchexec) (`brew install watchexec`) or fswatch. Without one, the server still runs. In production, run `bundle exec falcon host`.

## Test

```sh
bundle exec rspec
```

## Database

The `db` component in `config/components/db.rb` is a SQLite database under `storage/`, which classes reach with `dep :db`.

```sh
bin/sid db migrations add create_things   # writes db/migrations/<timestamp>_create_things.rb
bin/sid db migrations run
bin/sid db migrations rollback            # just the one that ran last
```

Sourced keeps the app's commands and events in the same database, in tables its own migration creates — `bin/sid sourced install` wrote it. `bin/sid sourced topology` shows how the app's commands, events and read models connect.

## Layout

| Path | What's in it |
| --- | --- |
| `boot.rb` | Loads and configures the app |
| `config/components/` | Components: the connections, clients and other services the app's classes use, declared with `Sidereal.config`. `boot.rb` loads every file here. See `example.rb` |
| `system/` | Backend code that doesn't know about the web: messages, commanders, Sourced deciders and reactors |
| `web/app.rb` | `App`, the web app: commands it accepts, their handlers, and pages |
| `web/ui/` | Pages and the layout, in the `UI` namespace |
| `web/ui/components/` | Components used by pages, in `UI::Components` |
| `web/public/` | Static files |
| `db/migrations/` | Database migrations, run with `bin/sid db migrations run`. Add one with `bin/sid db migrations add <name>` |
| `storage/` | Runtime data, including the SQLite database. Not committed. |
| `falcon.rb` | Falcon server settings |
| `bin/dev` | Development server that reloads on code changes |
| `bin/sid` | Sidereal's command line with this app loaded. `bin/sid --help` lists its commands, e.g. `bin/sid console` |
| `skills/` | Skills that teach AI coding agents to work with this app, such as using `bin/sid`. `.claude/skills` and `.agents/skills` link here, where agents look for them. `bin/sid skills update` refreshes the ones Sidereal and its integrations provide |

Classes in `system/` and `web/` are loaded by [Zeitwerk](https://github.com/fxn/zeitwerk): name a file after the class it defines and use the class anywhere, without `require`. Directories under `web/` are namespaces, so `web/ui/welcome_page.rb` defines `UI::WelcomePage`. Classes in `system/` are top-level.
