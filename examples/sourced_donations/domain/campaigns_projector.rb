# frozen_string_literal: true

class CampaignsProjector < Sourced::Projector::StateStored
  consumer_group 'campaigns_projector'
  partition_by :campaign_id

  state do |values|
    db = Sourced.store.db
    db[:campaigns].where(campaign_id: values[:campaign_id]).first ||
      { campaign_id: nil, name: nil, target_amount: nil, status: nil, created_at: nil, total_amount: 0 }
  end

  evolve(Campaign::CampaignCreated) do |state, evt|
    state[:campaign_id] = evt.payload.campaign_id
    state[:name] = evt.payload.name
    state[:target_amount] = evt.payload.target_amount
    state[:status] = 'open'
    state[:created_at] = evt.created_at.iso8601
  end

  evolve(Campaign::CampaignClosed) do |state, _evt|
    state[:status] = 'closed'
  end

  evolve(Donation::PaymentConfirmed) do |state, evt|
    # Legacy PaymentConfirmed events (before amount was added) deserialize
    # with amount: nil — to_i coerces them to 0.
    state[:total_amount] = state[:total_amount].to_i + evt.payload.amount.to_i
  end

  sync do |state:, **|
    next unless state[:campaign_id]

    Sourced.store.db[:campaigns].insert_conflict(:replace).insert(state)
  end

  module System
    Updated = Sourced::Event.define('system.campaigns.updated')
  end

  after_sync do |state:, **|
    Sidereal.pubsub.publish('system', System::Updated.new) if state[:campaign_id]
  end

  def self.on_reset
    Sourced.store.db[:campaigns].delete
  end

  # ---- Class-level queries ----

  def self.read_campaign(campaign_id)
    Sourced.store.db[:campaigns].where(campaign_id:).first
  end

  def self.all_campaigns
    Sourced.store.db[:campaigns].order(:created_at).all
  end
end
