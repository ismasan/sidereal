# frozen_string_literal: true

require 'securerandom'
require_relative 'payment'

class Donation < Sourced::Decider
  consumer_group 'donations'
  # Partition by both ids so the decider's history load includes the parent
  # Campaign events too (CampaignCreated / CampaignClosed, which only declare
  # campaign_id). Donation's own events declare both ids and stay scoped.
  partition_by :campaign_id, :donation_id

  AMOUNTS = [5, 10, 30, 50].freeze

  # ---- Browser-facing commands ----

  StartDonation = Sourced::Command.define('donations.start_donation') do
    attribute :donation_id, Sourced::Types::AutoUUID
    attribute :campaign_id, Sourced::Types::UUID::V4
  end

  SelectAmount = Sourced::Command.define('donations.select_amount') do
    attribute :donation_id, Sourced::Types::UUID::V4
    attribute :campaign_id, Sourced::Types::UUID::V4
    attribute :amount, Sourced::Types::String.present
  end

  EnterDonorDetails = Sourced::Command.define('donations.enter_donor_details') do
    attribute :donation_id, Sourced::Types::UUID::V4
    attribute :campaign_id, Sourced::Types::UUID::V4
    attribute :name, Sourced::Types::String.present
    attribute :email, Sourced::Types::Email.present
  end

  StartPayment = Sourced::Command.define('donations.start_payment') do
    attribute :donation_id, Sourced::Types::UUID::V4
    attribute :campaign_id, Sourced::Types::UUID::V4
  end

  VerifyEmailAddress = Sourced::Command.define('donations.verify_email_address') do
    attribute :donation_id, Sourced::Types::UUID::V4
    attribute :campaign_id, Sourced::Types::UUID::V4
  end

  # ---- Internal commands (issued by reactions) ----

  SendVerificationEmail = Sourced::Command.define('donations.send_verification_email') do
    attribute :donation_id, Sourced::Types::UUID::V4
    attribute :campaign_id, Sourced::Types::UUID::V4
  end

  DeliverVerificationEmail = Sourced::Command.define('donations.deliver_verification_email') do
    attribute :donation_id, Sourced::Types::UUID::V4
    attribute :campaign_id, Sourced::Types::UUID::V4
  end

  ShowPaymentButton = Sourced::Command.define('donations.show_payment_button') do
    attribute :donation_id, Sourced::Types::UUID::V4
    attribute :campaign_id, Sourced::Types::UUID::V4
  end

  ConfirmPayment = Sourced::Command.define('donations.confirm_payment') do
    attribute :donation_id, Sourced::Types::UUID::V4
    attribute :campaign_id, Sourced::Types::UUID::V4
    attribute :payment_reference, String
  end

  # ---- Events ----

  DonationStarted = Sourced::Event.define('donations.donation_started') do
    attribute :donation_id, Sourced::Types::UUID::V4
    attribute :campaign_id, Sourced::Types::UUID::V4
  end

  AmountSelected = Sourced::Event.define('donations.amount_selected') do
    attribute :donation_id, Sourced::Types::UUID::V4
    attribute :campaign_id, Sourced::Types::UUID::V4
    attribute :amount, Integer
  end

  DonorDetailsEntered = Sourced::Event.define('donations.donor_details_entered') do
    attribute :donation_id, Sourced::Types::UUID::V4
    attribute :campaign_id, Sourced::Types::UUID::V4
    attribute :name, String
    attribute :email, String
  end

  EmailSent = Sourced::Event.define('donations.email_sent') do
    attribute :donation_id, Sourced::Types::UUID::V4
    attribute :campaign_id, Sourced::Types::UUID::V4
  end

  VerificationEmailSent = Sourced::Event.define('donations.verification_email_sent') do
    attribute :donation_id, Sourced::Types::UUID::V4
    attribute :campaign_id, Sourced::Types::UUID::V4
    attribute :token, String
  end

  EmailVerified = Sourced::Event.define('donations.email_verified') do
    attribute :donation_id, Sourced::Types::UUID::V4
    attribute :campaign_id, Sourced::Types::UUID::V4
    attribute :verified_at, Sourced::Types::Forms::Time
  end

  PaymentReady = Sourced::Event.define('donations.payment_ready') do
    attribute :donation_id, Sourced::Types::UUID::V4
    attribute :campaign_id, Sourced::Types::UUID::V4
  end

  PaymentStarted = Sourced::Event.define('donations.payment_started') do
    attribute :donation_id, Sourced::Types::UUID::V4
    attribute :campaign_id, Sourced::Types::UUID::V4
  end

  PaymentConfirmed = Sourced::Event.define('donations.payment_confirmed') do
    attribute :donation_id, Sourced::Types::UUID::V4
    attribute :campaign_id, Sourced::Types::UUID::V4
    attribute :amount, Integer
    attribute :payment_reference, String
    attribute :paid_at, Sourced::Types::Forms::Time
  end

  # ---- Display ----

  # Message types shown in the DonationPage event-list sidebar. Union of
  # all commands and events scoped to the donation stream (no Campaign
  # messages — they're shared across donations). Also used as the filter
  # for the partition read that drives the sidebar.
  def self.display_types
    (handled_messages + handled_messages_for_evolve).uniq.map(&:type)
  end

  # ---- State ----

  State = Struct.new(
    :donation_id,
    :campaign_id,
    :amount,
    :email,
    :status,
    :campaign_status,
    :verification_token,
    keyword_init: true
  )

  state do |values|
    State.new(donation_id: values[:donation_id], campaign_id: values[:campaign_id])
  end

  # Parent Campaign events, loaded via the :campaign_id partition key.
  # Tracked on a dedicated campaign_status field so donation commands can
  # distinguish "campaign never created" (raise) from "campaign closed"
  # (silent no-op) without overloading state.status.
  evolve(Campaign::CampaignCreated) do |state, _evt|
    state.campaign_status = 'open'
  end

  evolve(Campaign::CampaignClosed) do |state, _evt|
    state.campaign_status = 'closed'
  end

  evolve(DonationStarted) do |state, _evt|
    state.status = 'started'
  end

  evolve(AmountSelected) do |state, evt|
    state.amount = evt.payload.amount
    state.status = 'amount_selected'
  end

  evolve(DonorDetailsEntered) do |state, evt|
    state.email = evt.payload.email
    state.status = 'details_entered'
  end

  evolve(EmailSent) do |state, _|
    state.status = 'email_sent'
  end

  evolve(VerificationEmailSent) do |state, evt|
    state.verification_token = evt.payload.token
    state.status = 'verification_email_sent'
  end

  evolve(EmailVerified) do |state, _|
    state.status = 'email_verified'
  end

  evolve(PaymentReady) do |state, _|
    state.status = 'payment_ready'
  end

  evolve(PaymentStarted) do |state, _|
    state.status = 'payment_started'
  end

  evolve(PaymentConfirmed) do |state, _|
    state.status = 'payment_confirmed'
  end

  # ---- Pure command handlers ----

  # Guard predicates invoked at the top of every command handler.
  # - campaign_missing? raises: a donation can't exist without its parent
  #   campaign, so this should never happen in practice.
  # - campaign_closed? silently no-ops: the campaign may legitimately close
  #   mid-flow, and donation-level commands become no-ops from that point.
  private def campaign_missing?(state) = state.campaign_status.nil?
  private def campaign_closed?(state) = state.campaign_status == 'closed'

  command(StartDonation) do |state, cmd|
    raise 'campaign not found' if campaign_missing?(state)
    return if campaign_closed?(state)
    raise 'donation already started' if state.status

    event DonationStarted,
      donation_id: cmd.payload.donation_id,
      campaign_id: cmd.payload.campaign_id
  end

  command(SelectAmount) do |state, cmd|
    raise 'campaign not found' if campaign_missing?(state)
    return if campaign_closed?(state)
    raise 'donation must be started first' unless state.status

    amount = cmd.payload.amount.to_i
    raise "invalid amount #{amount}" unless AMOUNTS.include?(amount)

    event AmountSelected,
      donation_id: cmd.payload.donation_id,
      campaign_id: state.campaign_id,
      amount:
  end

  command(EnterDonorDetails) do |state, cmd|
    raise 'campaign not found' if campaign_missing?(state)
    return if campaign_closed?(state)
    raise 'amount must be selected first' unless state.amount

    event DonorDetailsEntered,
      donation_id: cmd.payload.donation_id,
      campaign_id: state.campaign_id,
      name: cmd.payload.name,
      email: cmd.payload.email
  end

  command(SendVerificationEmail) do |state, cmd|
    raise 'campaign not found' if campaign_missing?(state)
    return if campaign_closed?(state)
    event EmailSent,
      donation_id: cmd.payload.donation_id,
      campaign_id: state.campaign_id
  end

  command(DeliverVerificationEmail) do |state, cmd|
    raise 'campaign not found' if campaign_missing?(state)
    return if campaign_closed?(state)
    sleep 3 # demo: simulate slow email service
    event VerificationEmailSent,
      donation_id: cmd.payload.donation_id,
      campaign_id: state.campaign_id,
      token: SecureRandom.urlsafe_base64(18)
  end

  command(VerifyEmailAddress) do |state, cmd|
    raise 'campaign not found' if campaign_missing?(state)
    return if campaign_closed?(state)
    event EmailVerified,
      donation_id: cmd.payload.donation_id,
      campaign_id: state.campaign_id,
      verified_at: cmd.created_at
  end

  command(ShowPaymentButton) do |state, cmd|
    raise 'campaign not found' if campaign_missing?(state)
    return if campaign_closed?(state)
    event PaymentReady,
      donation_id: cmd.payload.donation_id,
      campaign_id: state.campaign_id
  end

  command(StartPayment) do |state, cmd|
    raise 'campaign not found' if campaign_missing?(state)
    return if campaign_closed?(state)
    event PaymentStarted,
      donation_id: cmd.payload.donation_id,
      campaign_id: state.campaign_id
  end

  command(ConfirmPayment) do |state, cmd|
    raise 'campaign not found' if campaign_missing?(state)
    return if campaign_closed?(state)
    event PaymentConfirmed,
      donation_id: cmd.payload.donation_id,
      campaign_id: state.campaign_id,
      amount: state.amount,
      payment_reference: cmd.payload.payment_reference,
      paid_at: cmd.created_at
  end

  # ---- Reactions: model "automations" ----

  # email_sender automation (Event Lanes model node `aut:email_sender`)
  reaction(DonorDetailsEntered) do |_, evt|
    dispatch SendVerificationEmail,
      donation_id: evt.payload.donation_id,
      campaign_id: evt.payload.campaign_id
  end

  reaction(EmailSent) do |_, evt|
    dispatch DeliverVerificationEmail,
      donation_id: evt.payload.donation_id,
      campaign_id: evt.payload.campaign_id
  end

  # `aut:email_sender` chain implicitly continues into `ui:payment_screen` via `cmd:show_payment_button`
  reaction(EmailVerified) do |_, evt|
    dispatch ShowPaymentButton,
      donation_id: evt.payload.donation_id,
      campaign_id: evt.payload.campaign_id
  end

  # PaymentService automation: charge via the gateway, then dispatch
  # ConfirmPayment with the resulting reference. Reactions run in their own
  # batch so the slow Stripe call doesn't block the PaymentStarted event
  # from reaching the UI.
  reaction(PaymentStarted) do |state, evt|
    payment_reference = MockPaymentService.charge(state)
    dispatch ConfirmPayment,
      donation_id: evt.payload.donation_id,
      campaign_id: evt.payload.campaign_id,
      payment_reference:
  end

  # ---- Bridge to Sidereal SSE ----

  after_sync do |state:, events:, **|
    events.each do |evt|
      Sidereal.pubsub.publish(DonationsApp.commander.channel_name(evt), evt)
    end
  end
end
