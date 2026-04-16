# frozen_string_literal: true

require 'securerandom'
require_relative 'payment'

class Donation < Sourced::Decider
  consumer_group 'donations'
  partition_by :donation_id

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
    attribute :payment_reference, String
    attribute :paid_at, Sourced::Types::Forms::Time
  end

  # ---- State ----

  State = Struct.new(
    :donation_id,
    :campaign_id,
    :amount,
    :name,
    :email,
    :status,
    :verification_token,
    :verification_link,
    :verified_at,
    :payment_reference,
    :paid_at,
    keyword_init: true
  )

  state do |values|
    State.new(donation_id: values[:donation_id])
  end

  evolve(DonationStarted) do |state, evt|
    state.campaign_id = evt.payload.campaign_id
    state.status = 'started'
  end

  evolve(AmountSelected) do |state, evt|
    state.amount = evt.payload.amount
    state.status = 'amount_selected'
  end

  evolve(DonorDetailsEntered) do |state, evt|
    state.name = evt.payload.name
    state.email = evt.payload.email
    state.status = 'details_entered'
  end

  evolve(EmailSent) do |state, _|
    state.status = 'email_sent'
  end

  evolve(VerificationEmailSent) do |state, evt|
    state.verification_token = evt.payload.token
    state.verification_link = "/verify/#{state.donation_id}/#{evt.payload.token}"
    state.status = 'verification_email_sent'
  end

  evolve(EmailVerified) do |state, evt|
    state.verified_at = evt.payload.verified_at
    state.status = 'email_verified'
  end

  evolve(PaymentReady) do |state, _|
    state.status = 'payment_ready'
  end

  evolve(PaymentStarted) do |state, _|
    state.status = 'payment_started'
  end

  evolve(PaymentConfirmed) do |state, evt|
    state.payment_reference = evt.payload.payment_reference
    state.paid_at = evt.payload.paid_at
    state.status = 'payment_confirmed'
  end

  # ---- Pure command handlers ----

  command(StartDonation) do |state, cmd|
    raise 'donation already started' if state.status

    event DonationStarted,
      donation_id: cmd.payload.donation_id,
      campaign_id: cmd.payload.campaign_id
  end

  command(SelectAmount) do |state, cmd|
    raise 'donation must be started first' unless state.status

    amount = cmd.payload.amount.to_i
    raise "invalid amount #{amount}" unless AMOUNTS.include?(amount)

    event AmountSelected,
      donation_id: cmd.payload.donation_id,
      campaign_id: state.campaign_id,
      amount:
  end

  command(EnterDonorDetails) do |state, cmd|
    raise 'amount must be selected first' unless state.amount

    event DonorDetailsEntered,
      donation_id: cmd.payload.donation_id,
      campaign_id: state.campaign_id,
      name: cmd.payload.name,
      email: cmd.payload.email
  end

  command(SendVerificationEmail) do |state, cmd|
    event EmailSent,
      donation_id: cmd.payload.donation_id,
      campaign_id: state.campaign_id
  end

  command(DeliverVerificationEmail) do |state, cmd|
    sleep 3 # demo: simulate slow email service
    event VerificationEmailSent,
      donation_id: cmd.payload.donation_id,
      campaign_id: state.campaign_id,
      token: SecureRandom.urlsafe_base64(18)
  end

  command(VerifyEmailAddress) do |state, cmd|
    event EmailVerified,
      donation_id: cmd.payload.donation_id,
      campaign_id: state.campaign_id,
      verified_at: cmd.created_at
  end

  command(ShowPaymentButton) do |state, cmd|
    event PaymentReady,
      donation_id: cmd.payload.donation_id,
      campaign_id: state.campaign_id
  end

  command(StartPayment) do |state, cmd|
    event PaymentStarted,
      donation_id: cmd.payload.donation_id,
      campaign_id: state.campaign_id
  end

  command(ConfirmPayment) do |state, cmd|
    payment_reference = MockPaymentService.charge(state)
    event PaymentConfirmed,
      donation_id: cmd.payload.donation_id,
      campaign_id: state.campaign_id,
      payment_reference:,
      paid_at: Time.now # <= paid at time should be in the command
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

  # TODO: review this. Slow API call should happen in reaction, not command handler.
  # Why is slow reaction block blocking previous PaymentStarted event?
  #
  # PaymentService automation: enqueue ConfirmPayment. The slow Stripe call runs
  # inside ConfirmPayment's handler so that PaymentStarted can publish to the UI
  # first (reactions run synchronously inside handle_batch — sleeping here would
  # block after_sync and the Process step would never render).
  reaction(PaymentStarted) do |_, evt|
    dispatch ConfirmPayment,
      donation_id: evt.payload.donation_id,
      campaign_id: evt.payload.campaign_id
  end

  # ---- Bridge to Sidereal SSE ----

  after_sync do |state:, events:, **|
    events.each do |evt|
      channel = evt.metadata[:channel] || "donations.#{state.donation_id}"
      Sidereal.pubsub.publish(channel, evt)
    end
  end
end
