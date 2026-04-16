# frozen_string_literal: true

# In-memory projection for the donation page.
#
# Reads events for one (campaign_id, donation_id) pair using AND-filtered
# partition reads, then evolves them into a single State value that has both
# campaign and donation fields. No commands or reactions — just evolves.
class DonationView < Sourced::Decider
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

  state do |values|
    State.new(campaign_id: values[:campaign_id], donation_id: values[:donation_id])
  end

  evolve(Campaign::CampaignCreated) do |state, evt|
    state.campaign_name = evt.payload.name
    state.campaign_target_amount = evt.payload.target_amount
  end

  evolve(Donation::DonationStarted) do |state, _evt|
    state.status = 'started'
  end

  evolve(Donation::AmountSelected) do |state, evt|
    state.amount = evt.payload.amount
    state.status = 'amount_selected'
  end

  evolve(Donation::DonorDetailsEntered) do |state, evt|
    state.name = evt.payload.name
    state.email = evt.payload.email
    state.status = 'details_entered'
  end

  evolve(Donation::EmailSent) do |state, _evt|
    state.status = 'email_sent'
  end

  evolve(Donation::VerificationEmailSent) do |state, evt|
    state.verification_token = evt.payload.token
    state.verification_link =
      "/#{state.campaign_id}/#{state.donation_id}/verify/#{evt.payload.token}"
    state.status = 'verification_email_sent'
  end

  evolve(Donation::EmailVerified) do |state, evt|
    state.verified_at = evt.payload.verified_at
    state.status = 'email_verified'
  end

  evolve(Donation::PaymentReady) do |state, _evt|
    state.status = 'payment_ready'
  end

  evolve(Donation::PaymentStarted) do |state, _evt|
    state.status = 'payment_started'
  end

  evolve(Donation::PaymentConfirmed) do |state, evt|
    state.payment_reference = evt.payload.payment_reference
    state.paid_at = evt.payload.paid_at
    state.status = 'payment_confirmed'
  end
end
