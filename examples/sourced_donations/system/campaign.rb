# frozen_string_literal: true

class Campaign < Sourced::Decider
  consumer_group 'campaigns'
  partition_by :campaign_id

  # ---- Commands ----

  CreateCampaign = Sourced::Command.define('campaigns.create_campaign') do
    attribute :campaign_id, Sourced::Types::AutoUUID
    attribute :name, Sourced::Types::String.present
    attribute? :target_amount, Sourced::Types::String
  end

  CloseCampaign = Sourced::Command.define('campaigns.close_campaign') do
    attribute :campaign_id, Sourced::Types::UUID::V4
  end

  # ---- Events ----

  CampaignCreated = Sourced::Event.define('campaigns.campaign_created') do
    attribute :campaign_id, Sourced::Types::UUID::V4
    attribute :name, String
    # Nullable, not merely optional: a campaign with no target carries an
    # explicit nil (see #create_campaign below), and the store decodes payloads
    # against this schema on read.
    attribute? :target_amount, Sourced::Types::Integer.nullable
  end

  CampaignClosed = Sourced::Event.define('campaigns.campaign_closed') do
    attribute :campaign_id, Sourced::Types::UUID::V4
  end

  # ---- State ----

  State = Struct.new(
    :campaign_id,
    :name,
    :target_amount,
    :status,
    keyword_init: true
  )

  context do
    State.new
  end

  evolve(CampaignCreated) do |context, evt|
    context.campaign_id = evt.payload.campaign_id
    context.name = evt.payload.name
    context.target_amount = evt.payload.target_amount
    context.status = 'open'
  end

  evolve(CampaignClosed) do |context, _|
    context.status = 'closed'
  end

  # ---- Command handlers ----

  command(CreateCampaign) do |context, cmd|
    raise 'campaign already exists' if context.status

    raw_target = cmd.payload.target_amount.to_s.strip
    target_amount = raw_target.empty? ? nil : raw_target.to_i

    event CampaignCreated,
      campaign_id: cmd.payload.campaign_id,
      name: cmd.payload.name,
      target_amount:
  end

  command(CloseCampaign) do |context, cmd|
    raise 'campaign not found' unless context.status
    raise 'campaign already closed' if context.status == 'closed'

    event CampaignClosed, campaign_id: cmd.payload.campaign_id
  end
end
