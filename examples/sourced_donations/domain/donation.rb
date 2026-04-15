# frozen_string_literal: true

require 'securerandom'
require_relative 'payment'

class Donation < Sourced::Decider
  consumer_group 'donations'
  partition_by :donation_id

  AMOUNTS = [5, 10, 30, 50].freeze

  # ---- Browser-facing commands ----

  SelectAmount = Sourced::Command.define('donations.select_amount') do
    attribute :donation_id, Sourced::Types::AutoUUID
    attribute :amount, Sourced::Types::String.present
  end

  EnterDonorDetails = Sourced::Command.define('donations.enter_donor_details') do
    attribute :donation_id, Sourced::Types::UUID::V4
    attribute :name, Sourced::Types::String.present
    attribute :email, Sourced::Types::Email.present
  end

  StartPayment = Sourced::Command.define('donations.start_payment') do
    attribute :donation_id, Sourced::Types::UUID::V4
  end

  VerifyEmailAddress = Sourced::Command.define('donations.verify_email_address') do
    attribute :donation_id, Sourced::Types::UUID::V4
  end

  # ---- Internal commands (issued by reactions) ----

  SendVerificationEmail = Sourced::Command.define('donations.send_verification_email') do
    attribute :donation_id, Sourced::Types::UUID::V4
  end

  DeliverVerificationEmail = Sourced::Command.define('donations.deliver_verification_email') do
    attribute :donation_id, Sourced::Types::UUID::V4
  end

  ShowPaymentButton = Sourced::Command.define('donations.show_payment_button') do
    attribute :donation_id, Sourced::Types::UUID::V4
  end

  ConfirmPayment = Sourced::Command.define('donations.confirm_payment') do
    attribute :donation_id, Sourced::Types::UUID::V4
  end

  # ---- Events ----

  AmountSelected = Sourced::Event.define('donations.amount_selected') do
    attribute :donation_id, Sourced::Types::UUID::V4
    attribute :amount, Integer
  end

  DonorDetailsEntered = Sourced::Event.define('donations.donor_details_entered') do
    attribute :donation_id, Sourced::Types::UUID::V4
    attribute :name, String
    attribute :email, String
  end

  EmailSent = Sourced::Event.define('donations.email_sent') do
    attribute :donation_id, Sourced::Types::UUID::V4
  end

  VerificationEmailSent = Sourced::Event.define('donations.verification_email_sent') do
    attribute :donation_id, Sourced::Types::UUID::V4
    attribute :token, String
  end

  EmailVerified = Sourced::Event.define('donations.email_verified') do
    attribute :donation_id, Sourced::Types::UUID::V4
    attribute :verified_at, Sourced::Types::Forms::Time
  end

  PaymentReady = Sourced::Event.define('donations.payment_ready') do
    attribute :donation_id, Sourced::Types::UUID::V4
  end

  PaymentStarted = Sourced::Event.define('donations.payment_started') do
    attribute :donation_id, Sourced::Types::UUID::V4
  end

  PaymentConfirmed = Sourced::Event.define('donations.payment_confirmed') do
    attribute :donation_id, Sourced::Types::UUID::V4
    attribute :payment_reference, String
    attribute :paid_at, Sourced::Types::Forms::Time
  end

  # ---- State ----

  State = Struct.new(
    :donation_id,
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

  state { |values| State.new(donation_id: values[:donation_id]) }

  evolve(AmountSelected) do |s, e|
    s.amount = e.payload.amount
    s.status = 'amount_selected'
  end

  evolve(DonorDetailsEntered) do |s, e|
    s.name = e.payload.name
    s.email = e.payload.email
    s.status = 'details_entered'
  end

  evolve(EmailSent) do |s, _|
    s.status = 'email_sent'
  end

  evolve(VerificationEmailSent) do |s, e|
    s.verification_token = e.payload.token
    s.verification_link = "/verify/#{s.donation_id}/#{e.payload.token}"
    s.status = 'verification_email_sent'
  end

  evolve(EmailVerified) do |s, e|
    s.verified_at = e.payload.verified_at
    s.status = 'email_verified'
  end

  evolve(PaymentReady) do |s, _|
    s.status = 'payment_ready'
  end

  evolve(PaymentStarted) do |s, _|
    s.status = 'payment_started'
  end

  evolve(PaymentConfirmed) do |s, e|
    s.payment_reference = e.payload.payment_reference
    s.paid_at = e.payload.paid_at
    s.status = 'payment_confirmed'
  end

  # ---- Pure command handlers ----

  command(SelectAmount) do |_state, cmd|
    amount = cmd.payload.amount.to_i
    raise "invalid amount #{amount}" unless AMOUNTS.include?(amount)

    event AmountSelected, donation_id: cmd.payload.donation_id, amount:
  end

  command(EnterDonorDetails) do |state, cmd|
    raise 'amount must be selected first' unless state.amount

    event DonorDetailsEntered,
      donation_id: cmd.payload.donation_id,
      name: cmd.payload.name,
      email: cmd.payload.email
  end

  command(SendVerificationEmail) do |_, cmd|
    event EmailSent, donation_id: cmd.payload.donation_id
  end

  command(DeliverVerificationEmail) do |_, cmd|
    sleep 3 # demo: simulate slow email service
    event VerificationEmailSent,
      donation_id: cmd.payload.donation_id,
      token: SecureRandom.urlsafe_base64(18)
  end

  command(VerifyEmailAddress) do |_, cmd|
    event EmailVerified, donation_id: cmd.payload.donation_id, verified_at: Time.now
  end

  command(ShowPaymentButton) do |_, cmd|
    event PaymentReady, donation_id: cmd.payload.donation_id
  end

  command(StartPayment) do |_, cmd|
    event PaymentStarted, donation_id: cmd.payload.donation_id
  end

  command(ConfirmPayment) do |state, cmd|
    payment_reference = MockPaymentService.charge(state)
    event PaymentConfirmed,
      donation_id: cmd.payload.donation_id,
      payment_reference:,
      paid_at: Time.now
  end

  # ---- Reactions: model "automations" ----

  # email_sender automation (Event Lanes model node `aut:email_sender`)
  reaction(DonorDetailsEntered) do |_, evt|
    dispatch SendVerificationEmail, donation_id: evt.payload.donation_id
  end

  reaction(EmailSent) do |_, evt|
    dispatch DeliverVerificationEmail, donation_id: evt.payload.donation_id
  end

  # `aut:email_sender` chain implicitly continues into `ui:payment_screen` via `cmd:show_payment_button`
  reaction(EmailVerified) do |_, evt|
    dispatch ShowPaymentButton, donation_id: evt.payload.donation_id
  end

  # TODO: review this. Slow API call should happen in reaction, not command handler.
  # PaymentService automation: enqueue ConfirmPayment. The slow Stripe call runs
  # inside ConfirmPayment's handler so that PaymentStarted can publish to the UI
  # first (reactions run synchronously inside handle_batch — sleeping here would
  # block after_sync and the Process step would never render).
  reaction(PaymentStarted) do |_, evt|
    dispatch ConfirmPayment, donation_id: evt.payload.donation_id
  end

  # ---- Bridge to Sidereal SSE ----

  after_sync do |state:, events:, **|
    events.each do |evt|
      channel = evt.metadata[:channel] || "donations.#{state.donation_id}"
      Sidereal.pubsub.publish(channel, evt)
    end
  end
end
