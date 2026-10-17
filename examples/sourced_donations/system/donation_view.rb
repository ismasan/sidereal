# frozen_string_literal: true

# In-memory projection for the donation page.
#
# Reads events for one (campaign_id, donation_id) pair using AND-filtered
# partition reads, then evolves them into a single State value that has both
# campaign and donation fields. Not registered with Sourced and has no `sync`
# block, so no worker runs and nothing is persisted — used purely on demand
# via `Sourced.load(DonationView, ...)`.
class DonationView < Sourced::Projector::EventSourced
  partition_by :campaign_id, :donation_id

  State = Struct.new(
    :campaign_id,
    :donation_id,
    :campaign_name,
    :campaign_target_amount,
    :status,
    :amount,
    :name,
    :email,
    :verification_token,
    :verification_link,
    :verified_at,
    :payment_reference,
    :paid_at,
    keyword_init: true
  )

  context do
    State.new
  end

  # Both ids come from the events: campaign events carry campaign_id, the
  # donation's own events carry both.
  before_evolve do |context, evt|
    ids = evt.payload.to_h
    context.campaign_id ||= ids[:campaign_id]
    context.donation_id ||= ids[:donation_id]
  end

  evolve(Campaign::CampaignCreated) do |context, evt|
    context.campaign_name = evt.payload.name
    context.campaign_target_amount = evt.payload.target_amount
  end

  evolve(Campaign::CampaignClosed) do |context, _evt|
    context.status = 'closed'
  end

  evolve(Donation::DonationStarted) do |context, _evt|
    context.status = 'started'
  end

  evolve(Donation::AmountSelected) do |context, evt|
    context.amount = evt.payload.amount
    context.status = 'amount_selected'
  end

  evolve(Donation::DonorDetailsEntered) do |context, evt|
    context.name = evt.payload.name
    context.email = evt.payload.email
    context.status = 'details_entered'
  end

  evolve(Donation::EmailSent) do |context, _evt|
    context.status = 'email_sent'
  end

  evolve(Donation::VerificationEmailSent) do |context, evt|
    context.verification_token = evt.payload.token
    context.verification_link =
      "/#{context.campaign_id}/#{context.donation_id}/verify/#{evt.payload.token}"
    context.status = 'verification_email_sent'
  end

  evolve(Donation::EmailVerified) do |context, evt|
    context.verified_at = evt.payload.verified_at
    context.status = 'email_verified'
  end

  evolve(Donation::PaymentReady) do |context, _evt|
    context.status = 'payment_ready'
  end

  evolve(Donation::PaymentStarted) do |context, _evt|
    context.status = 'payment_started'
  end

  evolve(Donation::PaymentConfirmed) do |context, evt|
    context.payment_reference = evt.payload.payment_reference
    context.paid_at = evt.payload.paid_at
    context.status = 'payment_confirmed'
  end
end
