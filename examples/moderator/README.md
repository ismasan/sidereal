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

Runs three Falcon processes by default. The Sourced runtime runs on the elected leader only; the other two serve pages and append commands, and the Unix-socket pubsub fans SSE updates across all of them (see below). Set `COUNT` to change it.

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
| `domain/classifier.rb` | the automation — an `EventSourced` projector with no `sync`, classifying each comment's vibe and dispatching the verdict |
| `domain/subjects.rb` | hard-coded list of things being commented on |
| `ui/pipeline_page.rb` | the board, subscribed to `comments.>` |
| `ui/comment_detail_page.rb` | subclass of the board with the detail card in the middle column |
| `ui/components/event_feed.rb` | the global log (`read_all`) on the board, one comment's stream (`read_partition`) with step links on the detail view |

## The classifier automation

`Classifier` takes each new comment into moderation and gives it a vibe, using the [feelings](https://github.com/ismasan/feelings) gem to pick the closest of four descriptions. It is a `Projector::EventSourced` with no `sync` block rather than a decider, for two reasons.

It owns no stream. It handles no commands and emits no events; it watches a comment's events and dispatches the next command. That is an automation, and the projector base is the fit.

More importantly, an event-sourced projector rebuilds its state from the comment's full partition history on every batch, so `state.content` is always the comment's text no matter where the consumer group's offset is. Nothing is persisted, since there is no `sync` block — the state lives for the length of one batch and is thrown away.

The history it evolves is the *whole* partition, including messages later than the one being reacted to. So when the classifier runs behind a moderator who already took a comment, `state.taken` is already true while it reacts to `CommentCreated`, and `return if state.taken` keeps the redundant command out of the log.

### Who took the comment

A moderator clicking "Start moderating" and the classifier taking one itself emit the same `ModerationStarted`, so the event records the actor in `started_by` (`moderator` or `classifier`, non-nullable). The classifier only judges what it started; a comment a human claimed is left for that human to judge. The app stamps `started_by: 'moderator'` in `before_command`, which only runs for commands arriving over HTTP, so a crafted POST cannot claim to be the automation.

### When the model call fails

Two layers. The HTTP client inside `ruby_decision_model` already retries twice on 408, 429, 5xx, connection errors and timeouts, with exponential backoff and a 30s total budget, so a brief blip never reaches Sourced at all.

What escapes that budget hits `Classifier.on_exception`, which splits by cause:

| Cause | Policy |
| --- | --- |
| Rate limited, overloaded, timeout, dropped connection | retry the reaction after 10s, 20s, 40s, 80s, then stop the group |
| Rejected or missing key, unusable payload, a judge that cannot answer, a vibe the case statement has no branch for | stop the group immediately |

The second row would fail identically on every attempt, so retrying it only burns model calls to arrive at the same place. Retrying is safe because re-reacting re-runs the classification and a verdict the decider has already applied is a no-op the second time, the comment no longer being `moderating`.

`RETRY_STRATEGY` is a `Sourced::ErrorStrategy` of the classifier's own, since the global one is shared with the decider, where a rejected command is deterministic and should not be retried at all. `boot.rb` subscribes `Sidereal.exceptions` to it so a retry raises an amber toast on the board and a give-up raises a red one, exactly as the global strategy does.

### Why verdicts used to arrive all at once

Worker fibers are shared by every consumer group, and a fiber is held for the
whole of a reaction. The classifier's model call takes the best part of a
second, so at Sourced's default of two fibers both sit inside model calls and
no fiber is left to apply the `Mark*` commands they produce. The commands queue
until the classifier runs out of work, and then one freed fiber drains them in
a single burst — comments appear to jump from "moderating" to "moderated" all
at once at the end.

Measured on 20 comments with a 0.6s stand-in for the model call, counting
messages written per second:

| `worker_count` | classifier output | decider output |
| --- | --- | --- |
| 2 | spread over 6s | all 20 in second 6 |
| 10 | all in second 1 | all in second 1 |

`boot.rb` therefore sets `worker_count` to 10. Size it by how much slow work
runs concurrently, not by CPU. The cost is more in-flight model calls, which
is what the retry policy above is for, and more SQLite connections, which
matters little because a fiber waiting on HTTP holds no lock.

### Replaying it

A brand-new consumer group processes the whole backlog with reactions firing, so adding the classifier to a store that already has comments classifies them all.

Resetting an existing group does **not**. `reset_consumer_group` clears the offsets but leaves the group's `highest_position` watermark, so the re-read messages come back flagged as replaying, and Sourced deliberately skips reactions while replaying — a replay rebuilds state without re-firing side effects. To actually re-classify a backlog, give the class a new `consumer_group` name and restart; the fresh group sees everything as new.

## Time travel

The detail view's event feed lists only that comment's own stream, read from its partition. Each row links to `/comments/:comment_id/:step`, which rebuilds the comment from the first N messages of its log and renders that frozen state; arrows in the feed header step back and forward one message at a time. The sidebar always shows the whole history, so you can jump in either direction from any snapshot.

A snapshot subscribes to nothing (`channel_name` is `static`) and suppresses its `page_key`, so `Page.subscribe` returns early and live events never overwrite the frozen render. The card drops its buttons too: the past is not moderatable.

The replay runs through the `Comment` decider itself rather than a separate view class. A decider is already the event-sourced model of one comment, and its `State` struct carries exactly the fields the card reads, so `Comment.new(comment_id:).evolve(messages)` *is* the projection. The chess and donations demos add a `GameView` / `DonationView` because they need derived fields or a merge of two streams; this one does not.

## Concurrency

Two moderators can open the same pending comment and both click "Start moderating". Sourced serializes commands per partition: the second handler sees `moderating` and emits nothing. If the two appends collide instead, the optimistic-lock conflict flows through Sidereal's error handling and shows up as a failure toast, and the page still converges via the next SSE render.

Marking a comment that isn't `moderating` (a stale detail page, a double click after a verdict) is a silent no-op. Sourced's default error strategy fails the whole consumer group when a handler raises, which would halt moderation for every comment over one bad click; only real invariant breaches in `CreateComment` raise. A failed group can be reset from the Sourced dashboard at `/sourced`.

## Handheld layout

Below 860px the three columns collapse into tabs driven by a Datastar `tab` signal (declared with `__ifmissing`, so SSE re-renders don't reset the chosen tab). The detail view opens on the middle tab and adds a Back link.

## Console

```bash
bundle exec rake console
```

An IRB session with `boot.rb` loaded: the domain (`Comment`, `CommentsProjector`, `Subjects`) and a configured Sourced store. `app.rb` and the pages are not loaded; require them from the prompt if you want to render a component.

```ruby
CommentsProjector.board_for(Subjects.first.id).transform_values(&:size)
# => {pending: 13, moderating: 1, approved: 2}

Sidereal.dispatch!(Comment::CreateComment.new(payload: {
  subject_id: Subjects.first.id, commenter_id: SecureRandom.uuid, content: 'From the console'
}))
```

`dispatch!` appends to the store; a running server's workers pick it up, so the board updates over SSE while you watch.

## Tests

```bash
bundle exec rspec
```

Decider and projector specs use Sourced's Given/When/Then helpers; no server or SQLite file needed.

## SQLite and worker processes

Every Falcon worker loads `boot.rb`, but only the elected leader starts the Sourced dispatcher: `Sidereal::Integrations::Sourced` sets `dispatcher_process = :leader`, and `Sidereal::Host` starts the dispatcher from the elector's promote callback instead of at boot. The other workers serve HTTP, append commands to the store, and receive SSE updates over the Unix-socket pubsub. If the leader dies, its successor is promoted and starts its own dispatcher.

That matters because the event store is SQLite, which takes one write lock at a time. When every worker ran its own dispatcher, boot — with every consumer group discovering partitions and draining the backlog at once — reliably raised `SQLite3::BusyException: database is locked` at three processes. With one dispatcher there is one set of reactor writers, and the only extra contention from more processes is the appends their HTTP requests make.

Concurrency inside the leader comes from Sourced worker fibers (see the classifier section), each with its own connection. `boot.rb` additionally begins transactions as `IMMEDIATE` and allows a 15s wait for the lock, which covers the appends arriving from the other workers.

For genuinely concurrent dispatchers across processes, use Postgres and set `c.dispatcher_process = :all` after `c.use Sidereal::Integrations::Sourced`.

## Configuration

Settings come from the environment, loaded from a local `.env` by [dotenv](https://github.com/bkeepers/dotenv). The file is optional: with no `.env` at all every setting falls back to the same default, and a real environment variable always beats the file, so `PORT=8080 bundle exec falcon host` wins regardless. `.env` is gitignored; `.env.example` is the template.

| Variable | Default | Used by |
| --- | --- | --- |
| `HOST` | `localhost` | `falcon.rb` |
| `PORT` | `9297` | `falcon.rb` |
| `COUNT` | `3` | `falcon.rb` — Falcon worker processes; the Sourced dispatcher runs on the elected leader only |
| `DATABASE_PATH` | `storage/moderator.db` | `boot.rb` |
| `SESSION_SECRET` | a fixed dev value | `app.rb` — Rack wants 64+ bytes |
| `FIXTURES` | `config/fixtures.yml` | `rake db:seed` |
| `OPENROUTER_API_KEY` | none | the classifier, through `feelings`; without it the automation raises and Sourced stops the `classifier` consumer group, while posting and moderating by hand keep working |

`config/env.rb` does the loading and is required from **both** `falcon.rb` and `boot.rb`, because they run in different processes. The Falcon controller loads `falcon.rb` for the host and port and never loads the app; each forked worker loads `boot.rb` through `config.ru`. Having `falcon.rb` require `boot.rb` instead would open a SQLite connection in the controller, which the fork model deliberately avoids. The path is resolved against the file rather than the working directory, so a rake task or console started from elsewhere still finds it.

## Fixtures

`config/fixtures.yml` holds 50 `Comment::CreateComment` commands across the three subjects: a mix of positive, neutral and negative comments plus some spam, from a dozen recurring commenters. `rake db:seed` builds each one through the message registry and appends it with `Sidereal.dispatch!`.

The task appends but does not run the commands. The decider and projector consume them from a worker, so seed against a live server to watch the board fill, or seed first and they are picked up when the server boots. Point it at another file with `FIXTURES=path/to/other.yml`.

## Reset

```bash
bundle exec rake db:reset
```
