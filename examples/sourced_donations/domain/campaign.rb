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
    attribute? :target_amount, Integer
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

  state do |values|
    State.new(campaign_id: values[:campaign_id])
  end

  evolve(CampaignCreated) do |state, evt|
    state.name = evt.payload.name
    state.target_amount = evt.payload.target_amount
    state.status = 'open'
  end

  evolve(CampaignClosed) do |state, _|
    state.status = 'closed'
  end

  # ---- Command handlers ----

  command(CreateCampaign) do |state, cmd|
    raise 'campaign already exists' if state.status

    raw_target = cmd.payload.target_amount.to_s.strip
    target_amount = raw_target.empty? ? nil : raw_target.to_i

    event CampaignCreated,
      campaign_id: cmd.payload.campaign_id,
      name: cmd.payload.name,
      target_amount:
  end

  command(CloseCampaign) do |state, cmd|
    raise 'campaign not found' unless state.status
    raise 'campaign already closed' if state.status == 'closed'

    event CampaignClosed, campaign_id: cmd.payload.campaign_id
  end

  # ---- Bridge to Sidereal SSE ----

  after_sync do |state:, events:, **|
    events.each do |evt|
      Sidereal.pubsub.publish(DonationsApp.commander.channel_name(evt), evt)
    end
  end
end
