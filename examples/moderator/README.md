# Moderator — comment moderation pipeline (Sourced backend)

A small event-sourced comment moderation board. Comments arrive in an inbox, a moderator takes one, gives it a vibe (positive / neutral / negative) or flags it as spam, and every open board updates live over SSE.

Based on this Event Lanes model: [Moderator](https://eventlanes.app/models/aad4bcea-7dfc-4fcf-b17f-a98aca8b13c5).

## Run

```bash
cd examples/moderator
bundle install
cp .env.example .env   # optional — every value has a default
bundle exec rake db:migrate
bundle exec falcon host
```

Optionally fill the inbox with 50 sample comments before or while the server runs:

```bash
bundle exec rake db:seed
```

Then:

- <http://localhost:9297/> — the comment box (`ui:CommentBox`)
- <http://localhost:9297/comments> — the pipeline board (`ui:PipelineView`)
- <http://localhost:9297/comments/:comment_id> — one comment's detail card over the board (`ui:DetailView`)
- <http://localhost:9297/comments/:comment_id/:step> — that comment replayed up to the Nth message of its stream
- <http://localhost:9297/sourced> — the Sourced event-store dashboard

Runs three Falcon workers by default (`COUNT=1` for one), so two moderators on different processes still see each other's moves through the Unix-socket pubsub.

## Flow

```
CommentBox → CreateComment → CommentCreated            (status: pending)
Inbox card → /comments/:id → StartModeration → ModerationStarted   (status: moderating)
DetailView → MarkPositive | MarkNeutral | MarkNegative → Marked*   (status: approved, vibe: …)
DetailView → MarkSpam → MarkedSpam                                 (status: spam)
```

Clicking an inbox card only navigates to the detail view. The "Start moderating" button there sends the command, and it only shows while the comment is still pending.

## Pieces

| | |
| --- | --- |
| `domain/comment.rb` | `Sourced::Decider` — commands, events, state, guards |
| `domain/comments_projector.rb` | `StateStored` projector → `comments` table; its auto-generated `Projected` signal drives board re-renders |
| `domain/subjects.rb` | hard-coded list of things being commented on |
| `ui/pipeline_page.rb` | the board, subscribed to `comments.>` |
| `ui/comment_detail_page.rb` | subclass of the board with the detail card in the middle column |
| `ui/components/event_feed.rb` | the global log (`read_all`) on the board, one comment's stream (`read_partition`) with step links on the detail view |

## Time travel

The detail view's event feed lists only that comment's own stream, read from its partition. Each row links to `/comments/:comment_id/:step`, which rebuilds the comment from the first N messages of its log and renders that frozen state; arrows in the feed header step back and forward one message at a time. The sidebar always shows the whole history, so you can jump in either direction from any snapshot.

A snapshot subscribes to nothing (`channel_name` is `static`) and suppresses its `page_key`, so `Page.subscribe` returns early and live events never overwrite the frozen render. The card drops its buttons too: the past is not moderatable.

The replay runs through the `Comment` decider itself rather than a separate view class. A decider is already the event-sourced model of one comment, and its `State` struct carries exactly the fields the card reads, so `Comment.new(comment_id:).evolve(messages)` *is* the projection. The chess and donations demos add a `GameView` / `DonationView` because they need derived fields or a merge of two streams; this one does not.

## Concurrency

Two moderators can open the same pending comment and both click "Start moderating". Sourced serializes commands per partition: the second handler sees `moderating` and emits nothing. If the two appends collide instead, the optimistic-lock conflict flows through Sidereal's error handling and shows up as a failure toast, and the page still converges via the next SSE render.

Marking a comment that isn't `moderating` (a stale detail page, a double click after a verdict) is a silent no-op. Sourced's default error strategy fails the whole consumer group when a handler raises, which would halt moderation for every comment over one bad click; only real invariant breaches in `CreateComment` raise. A failed group can be reset from the Sourced dashboard at `/sourced`.

## Handheld layout

Below 860px the three columns collapse into tabs driven by a Datastar `tab` signal (declared with `__ifmissing`, so SSE re-renders don't reset the chosen tab). The detail view opens on the middle tab and adds a Back link.

## Tests

```bash
bundle exec rspec
```

Decider and projector specs use Sourced's Given/When/Then helpers; no server or SQLite file needed.

## Configuration

Settings come from the environment, loaded from a local `.env` by [dotenv](https://github.com/bkeepers/dotenv). The file is optional: with no `.env` at all every setting falls back to the same default, and a real environment variable always beats the file, so `PORT=8080 bundle exec falcon host` wins regardless. `.env` is gitignored; `.env.example` is the template.

| Variable | Default | Used by |
| --- | --- | --- |
| `HOST` | `localhost` | `falcon.rb` |
| `PORT` | `9297` | `falcon.rb` |
| `COUNT` | `3` | `falcon.rb` — worker processes; needs to be > 1 to exercise cross-process pubsub |
| `DATABASE_PATH` | `storage/moderator.db` | `boot.rb` |
| `SESSION_SECRET` | a fixed dev value | `app.rb` — Rack wants 64+ bytes |
| `FIXTURES` | `config/fixtures.yml` | `rake db:seed` |

`config/env.rb` does the loading and is required from **both** `falcon.rb` and `boot.rb`, because they run in different processes. The Falcon controller loads `falcon.rb` for the host and port and never loads the app; each forked worker loads `boot.rb` through `config.ru`. Having `falcon.rb` require `boot.rb` instead would open a SQLite connection in the controller, which the fork model deliberately avoids. The path is resolved against the file rather than the working directory, so a rake task or console started from elsewhere still finds it.

## Fixtures

`config/fixtures.yml` holds 50 `Comment::CreateComment` commands across the three subjects: a mix of positive, neutral and negative comments plus some spam, from a dozen recurring commenters. `rake db:seed` builds each one through the message registry and appends it with `Sidereal.dispatch!`.

The task appends but does not run the commands. The decider and projector consume them from a worker, so seed against a live server to watch the board fill, or seed first and they are picked up when the server boots. Point it at another file with `FIXTURES=path/to/other.yml`.

## Reset

```bash
bundle exec rake db:reset
```
