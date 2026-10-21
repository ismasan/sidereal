# frozen_string_literal: true

module CrossPost
  # A post, from draft to published on every service it's going to. Started
  # by Account's DraftPost, with the services connected at the time.
  #
  #   Started ─▶ drafting ─Submit [ready]───▶ publishing ─done [all published]──▶ published
  #              (a region   ─Schedule [ready]─▶ scheduled ─PublishScheduled─▶ publishing ─done [some published]─▶ partially_published
  #              per service) ◀─Unschedule (H*)─┘                                         ─done─▶ failed ─Redraft (H*)─▶ drafting
  #   drafting, scheduled, failed ─Discard─▶ discarded
  #
  # drafting is parallel: one Targets region per service, where the service
  # is selected and the draft validated against its Rules. It's ready to
  # submit once at least one service is selected and none is invalid.
  # publishing is parallel too: one Deliveries region per service, skipped
  # for those not selected.
  class Post < Sourced::Machine
    partition_by account_id: Sourced::Types::UUID::V4, post_id: Sourced::Types::UUID::V4
    message_prefix 'cross_post.post'

    # ---- States ----

    Drafting = State(:drafting)
    Scheduled = State(:scheduled)
    Publishing = State(:publishing)
    Published = State(:published)
    PartiallyPublished = State(:partially_published)
    Failed = State(:failed)
    Discarded = State(:discarded)

    stopped Discarded

    # ---- Commands ----

    EditText = Command(:edit_text) do
      attribute :text, Sourced::Types::String
    end

    AttachMedia = Command(:attach_media) do
      attribute :media_id, Sourced::Types::AutoUUID
      attribute :kind, Sourced::Types::String.options(%w[image video])
      attribute :alt, Sourced::Types::String.default('')
    end

    RemoveMedia = Command(:remove_media) do
      attribute :media_id, Sourced::Types::UUID::V4
    end

    Submit = Command(:submit)

    Schedule = Command(:schedule) do
      attribute :publish_at, Sourced::Types::Time
    end

    Unschedule = Command(:unschedule)

    # Dispatched by scheduled's entry, for when the post is due. One for an
    # earlier schedule doesn't match publish_at, and is ignored.
    PublishScheduled = Command(:publish_scheduled) do
      attribute :publish_at, Sourced::Types::Time
    end

    # Back to editing a post that no service took.
    Redraft = Command(:redraft)
    Discard = Command(:discard)

    # ---- Events ----

    TextEdited = Event(:text_edited) do
      attribute :text, Sourced::Types::String
    end

    MediaAttached = Event(:media_attached) do
      attribute :media_id, Sourced::Types::UUID::V4
      attribute :kind, Sourced::Types::String
      attribute :alt, Sourced::Types::String
    end

    MediaRemoved = Event(:media_removed) do
      attribute :media_id, Sourced::Types::UUID::V4
    end

    PublishAtSet = Event(:publish_at_set) do
      attribute :publish_at, Sourced::Types::Time
    end

    # ---- Domain state ----

    class Draft
      Media = Data.define(:kind, :alt)

      attr_accessor :account_id, :post_id, :text, :publish_at
      # Services connected when the post was started; services selected and
      # validated (in Targets' valid or invalid); attempts and successes per
      # service, while publishing.
      attr_reader :services, :media, :targets, :attempts, :published

      def initialize
        @text = ''
        @services = []
        @media = {}
        @targets = Set.new
        @attempts = Hash.new(0)
        @published = Set.new
      end

      def valid_for?(service) = Rules.fetch(service).valid?(text:, media: media.values)
      def errors_for(service) = Rules.fetch(service).errors(text:, media: media.values)
      def all_published? = targets.any? && targets.all? { published.include?(it) }
      def any_published? = published.any?
    end

    context { Draft.new }

    before_evolve do |draft, evt|
      draft.account_id = evt.payload.account_id
      draft.post_id = evt.payload.post_id
    end

    evolve Started do |draft, evt|
      draft.services.replace(evt.payload.input.transform_keys(&:to_sym).fetch(:services, []))
    end

    evolve TextEdited do |draft, evt|
      draft.text = evt.payload.text
    end

    evolve MediaAttached do |draft, evt|
      draft.media[evt.payload.media_id] = Draft::Media.new(kind: evt.payload.kind, alt: evt.payload.alt)
    end

    evolve MediaRemoved do |draft, evt|
      draft.media.delete(evt.payload.media_id)
    end

    evolve PublishAtSet do |draft, evt|
      draft.publish_at = evt.payload.publish_at
    end

    # Each publishing round starts over.
    evolve Publishing do |draft, _evt|
      draft.attempts.clear
      draft.published.clear
    end

    # ---- The statechart ----

    # Whether every selected service is valid, and there's at least one.
    def ready? = Targets::ALL.values.any? { machine.in?(it::Valid) } && Targets::ALL.values.none? { machine.in?(it::Invalid) }

    started Drafting do
      entry do |_draft, _transition|
        dispatch Targets::Sync
      end

      Targets::ALL.each do |service, part|
        region service.to_sym, part
      end

      command EditText do |_draft, cmd|
        event TextEdited, text: cmd.payload.text
      end

      command AttachMedia do |_draft, cmd|
        event MediaAttached, **cmd.payload.to_h.slice(:media_id, :kind, :alt)
      end

      command RemoveMedia do |draft, cmd|
        event MediaRemoved, media_id: cmd.payload.media_id if draft.media.key?(cmd.payload.media_id)
      end

      command Submit => Publishing | nil do |_draft, _cmd|
        to Publishing if ready?
      end

      command Schedule => Scheduled | nil do |_draft, cmd|
        if ready? && cmd.payload.publish_at > Time.now
          event PublishAtSet, publish_at: cmd.payload.publish_at
          to Scheduled
        end
      end

      command Discard => Discarded
    end

    # The draft's selections and validations, kept as they were (deep history)
    # for when it's unscheduled.
    state Scheduled do
      entry do |draft, _transition|
        dispatch(PublishScheduled, publish_at: draft.publish_at).at(draft.publish_at)
      end

      command PublishScheduled => Publishing | nil do |draft, cmd|
        to Publishing if cmd.payload.publish_at == draft.publish_at
      end

      command Unschedule => Drafting.history(deep: true)
      command Discard => Discarded
    end

    state Publishing do
      entry do |_draft, _transition|
        dispatch Deliveries::Begin
      end

      Deliveries::ALL.each do |service, part|
        region :"#{service}_delivery", part
      end

      done Published, if: :all_published?
      done PartiallyPublished, if: :any_published?
      done Failed
    end

    state Failed do
      command Redraft => Drafting.history(deep: true)
      command Discard => Discarded
    end

    final Published
    final PartiallyPublished

    # ---- Regions, as data ----

    Targets::ALL.each do |service, part|
      [part::Valid, part::Invalid].each do |selected|
        evolve selected do |draft, _evt|
          draft.targets << service
        end
      end

      [part::Available, part::Unavailable].each do |unselected|
        evolve unselected do |draft, _evt|
          draft.targets.delete(service)
        end
      end
    end

    Deliveries::ALL.each do |service, part|
      evolve part::Sending do |draft, _evt|
        draft.attempts[service] += 1
      end

      evolve part::Published do |draft, _evt|
        draft.published << service
      end
    end

    # ---- Reactions ----

    # Every edit revalidates the draft for the services it's going to.
    [TextEdited, MediaAttached, MediaRemoved].each do |edit|
      reaction edit do |draft, _evt|
        dispatch Targets::Validate if draft.targets.any?
      end
    end
  end
end
