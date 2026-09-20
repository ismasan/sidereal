# Moderator — comment moderation pipeline (Sourced backend)

A small event-sourced comment moderation board. Comments arrive in an inbox, a moderator takes one, gives it a vibe (positive / neutral / negative) or flags it as spam, and every open board updates live over SSE.

Based on this Event Lanes model: [Moderator](https://eventlanes.app/models/aad4bcea-7dfc-4fcf-b17f-a98aca8b13c5).

## Run

```bash
cd examples/moderator
bundle install
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
| `ui/components/event_feed.rb` | recent messages from `Sourced.store.read_all` |

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

## Fixtures

`config/fixtures.yml` holds 50 `Comment::CreateComment` commands across the three subjects: a mix of positive, neutral and negative comments plus some spam, from a dozen recurring commenters. `rake db:seed` builds each one through the message registry and appends it with `Sidereal.dispatch!`.

The task appends but does not run the commands. The decider and projector consume them from a worker, so seed against a live server to watch the board fill, or seed first and they are picked up when the server boots. Point it at another file with `FIXTURES=path/to/other.yml`.

## Reset

```bash
bundle exec rake db:reset
```
