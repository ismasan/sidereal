# frozen_string_literal: true

class CampaignsProjector < Sourced::Projector::StateStored
  consumer_group 'campaigns_projector'
  partition_by :campaign_id

  context do
    { campaign_id: nil, name: nil, target_amount: nil, status: nil, created_at: nil, total_amount: 0 }
  end

  # The campaign's stored row, if any, which the claimed events evolve on top of.
  load_context do |values|
    Sourced.store.db[:campaigns].where(campaign_id: values[:campaign_id]).first
  end

  evolve(Campaign::CampaignCreated) do |context, evt|
    context[:campaign_id] = evt.payload.campaign_id
    context[:name] = evt.payload.name
    context[:target_amount] = evt.payload.target_amount
    context[:status] = 'open'
    context[:created_at] = evt.created_at.iso8601
  end

  evolve(Campaign::CampaignClosed) do |context, _evt|
    context[:status] = 'closed'
  end

  evolve(Donation::PaymentConfirmed) do |context, evt|
    # Legacy PaymentConfirmed events (before amount was added) deserialize
    # with amount: nil — to_i coerces them to 0.
    context[:total_amount] = context[:total_amount].to_i + evt.payload.amount.to_i
  end

  sync do |context:, **|
    next unless context[:campaign_id]

    Sourced.store.db[:campaigns].insert_conflict(:replace).insert(context)
  end

  # A `Projected` signal (attribute: campaign_id) is auto-generated from
  # `partition_by` and published after each committed batch by
  # Sidereal::Integrations::Sourced — routed via Sidereal.channels.for.

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
