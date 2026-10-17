# frozen_string_literal: true

require 'securerandom'

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
    attribute :verified_at, Time
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
    attribute :paid_at, Time
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

  # Parent Campaign events, loaded via the :campaign_id partition key.
  # Tracked on a dedicated campaign_status field so donation commands can
  # distinguish "campaign never created" (raise) from "campaign closed"
  # (silent no-op) without overloading context.status.
  evolve(Campaign::CampaignCreated) do |context, _evt|
    context.campaign_status = 'open'
  end

  evolve(Campaign::CampaignClosed) do |context, _evt|
    context.campaign_status = 'closed'
  end

  evolve(DonationStarted) do |context, _evt|
    context.status = 'started'
  end

  evolve(AmountSelected) do |context, evt|
    context.amount = evt.payload.amount
    context.status = 'amount_selected'
  end

  evolve(DonorDetailsEntered) do |context, evt|
    context.email = evt.payload.email
    context.status = 'details_entered'
  end

  evolve(EmailSent) do |context, _|
    context.status = 'email_sent'
  end

  evolve(VerificationEmailSent) do |context, evt|
    context.verification_token = evt.payload.token
    context.status = 'verification_email_sent'
  end

  evolve(EmailVerified) do |context, _|
    context.status = 'email_verified'
  end

  evolve(PaymentReady) do |context, _|
    context.status = 'payment_ready'
  end

  evolve(PaymentStarted) do |context, _|
    context.status = 'payment_started'
  end

  evolve(PaymentConfirmed) do |context, _|
    context.status = 'payment_confirmed'
  end

  # ---- Pure command handlers ----

  # Guard predicates invoked at the top of every command handler.
  # - campaign_missing? raises: a donation can't exist without its parent
  #   campaign, so this should never happen in practice.
  # - campaign_closed? silently no-ops: the campaign may legitimately close
  #   mid-flow, and donation-level commands become no-ops from that point.
  private def campaign_missing?(context) = context.campaign_status.nil?
  private def campaign_closed?(context) = context.campaign_status == 'closed'

  command(StartDonation) do |context, cmd|
    raise 'campaign not found' if campaign_missing?(context)
    return if campaign_closed?(context)
    raise 'donation already started' if context.status

    event DonationStarted,
      donation_id: cmd.payload.donation_id,
      campaign_id: cmd.payload.campaign_id
  end

  command(SelectAmount) do |context, cmd|
    raise 'campaign not found' if campaign_missing?(context)
    return if campaign_closed?(context)
    raise 'donation must be started first' unless context.status

    amount = cmd.payload.amount.to_i
    raise "invalid amount #{amount}" unless AMOUNTS.include?(amount)

    event AmountSelected,
      donation_id: cmd.payload.donation_id,
      campaign_id: cmd.payload.campaign_id,
      amount:
  end

  command(EnterDonorDetails) do |context, cmd|
    raise 'campaign not found' if campaign_missing?(context)
    return if campaign_closed?(context)
    raise 'amount must be selected first' unless context.amount

    event DonorDetailsEntered,
      donation_id: cmd.payload.donation_id,
      campaign_id: cmd.payload.campaign_id,
      name: cmd.payload.name,
      email: cmd.payload.email
  end

  command(SendVerificationEmail) do |context, cmd|
    raise 'campaign not found' if campaign_missing?(context)
    return if campaign_closed?(context)
    event EmailSent,
      donation_id: cmd.payload.donation_id,
      campaign_id: cmd.payload.campaign_id
  end

  command(DeliverVerificationEmail) do |context, cmd|
    raise 'campaign not found' if campaign_missing?(context)
    return if campaign_closed?(context)
    sleep 3 # demo: simulate slow email service
    event VerificationEmailSent,
      donation_id: cmd.payload.donation_id,
      campaign_id: cmd.payload.campaign_id,
      token: SecureRandom.urlsafe_base64(18)
  end

  command(VerifyEmailAddress) do |context, cmd|
    raise 'campaign not found' if campaign_missing?(context)
    return if campaign_closed?(context)
    event EmailVerified,
      donation_id: cmd.payload.donation_id,
      campaign_id: cmd.payload.campaign_id,
      verified_at: cmd.created_at
  end

  command(ShowPaymentButton) do |context, cmd|
    raise 'campaign not found' if campaign_missing?(context)
    return if campaign_closed?(context)
    event PaymentReady,
      donation_id: cmd.payload.donation_id,
      campaign_id: cmd.payload.campaign_id
  end

  command(StartPayment) do |context, cmd|
    raise 'campaign not found' if campaign_missing?(context)
    return if campaign_closed?(context)
    event PaymentStarted,
      donation_id: cmd.payload.donation_id,
      campaign_id: cmd.payload.campaign_id
  end

  command(ConfirmPayment) do |context, cmd|
    raise 'campaign not found' if campaign_missing?(context)
    return if campaign_closed?(context)
    event PaymentConfirmed,
      donation_id: cmd.payload.donation_id,
      campaign_id: cmd.payload.campaign_id,
      amount: context.amount,
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
  reaction(PaymentStarted) do |context, evt|
    payment_reference = MockPaymentService.charge(context)
    dispatch ConfirmPayment,
      donation_id: evt.payload.donation_id,
      campaign_id: evt.payload.campaign_id,
      payment_reference:
  end
end
