# frozen_string_literal: true

require 'feelings'
require 'ruby_decision_model'

# The automation: takes each new comment into moderation and gives it a vibe.
#
# An event-sourced projector rather than a decider, because it owns no stream
# of its own — it handles no commands and emits no events, it only watches a
# comment's events and dispatches the next command. `Projector::EventSourced`
# rebuilds its state from the comment's full history on every batch, so the
# content is always there to classify, whatever position the consumer group
# is at. There is no `sync` block, so nothing is persisted: the state lives
# for the length of one batch.
class Classifier < Sourced::Projector::EventSourced
  consumer_group 'classifier'
  partition_by :comment_id

  VIBES = {
    positive: 'A positive or constructive comment. Shows agreement and/or approval',
    neutral: 'Does not pass judgement either way, or is indecisive or on the fence',
    negative: 'A negative comment, shows disagreement or disaproval',
    spam: 'spam content, unrelated to the subject, probably trying to sell something, or scam.'
  }.freeze

  # ---- Retry policy ----
  #
  # The model call is retried twice inside the HTTP client already (exponential
  # backoff from 0.5s, capped at a 30s budget, honouring Retry-After), so an
  # exception reaching here means that budget is spent. Only a fault that could
  # plausibly clear on its own is worth waiting minutes for.
  RETRYABLE_ERRORS = [
    RubyDecisionModel::TransportError, # connection reset, TLS, TimeoutError
    RubyDecisionModel::RateLimited,
    RubyDecisionModel::Overloaded
  ].freeze

  # 10s, 20s, 40s, 80s, then dead. Reacting again re-runs the classification,
  # which is safe: a verdict the decider has already applied is a no-op the
  # second time, since the comment is no longer `moderating`.
  RETRY_STRATEGY = Sourced::ErrorStrategy.new.retry(
    times: 4,
    after: 10,
    backoff: ->(after, count) { after * (2**(count - 1)) }
  )

  # Anything else — a missing or rejected API key, a malformed response, a vibe
  # the case below has no branch for — will fail identically on every attempt,
  # so it takes the
  # default strategy and stops the consumer group immediately rather than
  # burning four more model calls to reach the same place.
  def self.on_exception(exception, message, group)
    strategy = RETRYABLE_ERRORS.any? { |klass| exception.is_a?(klass) } ? RETRY_STRATEGY : Sourced.config.error_strategy
    strategy.call(exception, message, group)
  end

  State = Struct.new(:content, :taken)

  # Minimal local struct to keep track of
  # the state changes we care about here.
  state do |_values|
    State.new('', false)
  end

  # Evolve local state
  # so that the classifier has the info it needs.
  evolve(Comment::CommentCreated) do |state, evt|
    state.content = evt.payload.content
  end

  evolve(Comment::ModerationStarted) do |state, _evt|
    state.taken = true
  end

  # When a comment is created, start moderation immediately
  reaction Comment::CommentCreated do |state, evt|
    return if state.taken

    dispatch Comment::StartModeration,
      comment_id: evt.payload.comment_id,
      started_by: 'classifier'
  end

  # Use Jev (via Feelings gem) to classify this comment.
  reaction Comment::ModerationStarted do |state, evt|
    return unless evt.payload.started_by == 'classifier'

    comment_id = evt.payload.comment_id

    case Feelings(state.content).most_like(VIBES)
    when :positive
      dispatch Comment::MarkPositive, comment_id:
    when :neutral
      dispatch Comment::MarkNeutral, comment_id:
    when :negative
      dispatch Comment::MarkNegative, comment_id:
    when :spam
      dispatch Comment::MarkSpam, comment_id:
    else 
      raise "no verdict for #{comment_id}"
    end
  end

  # Sourced hook
  def should_react?(state, message, replaying: false)
    true
  end

  if ENV['SLOWMO']
    after_sync do |**|
      sleep Float(ENV['SLOWMO'])
    end
  end
end
