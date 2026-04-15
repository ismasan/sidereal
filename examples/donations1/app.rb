# frozen_string_literal: true

require 'sidereal'
require 'securerandom'

# -- Messages --

SelectAmount = Sidereal::Message.define('donations.select_amount') do
  attribute :donation_id, Sidereal::Types::AutoUUID
  attribute :amount, Sidereal::Types::String.present
end

EnterDonorDetails = Sidereal::Message.define('donations.enter_donor_details') do
  attribute :donation_id, Sidereal::Types::UUID::V4
  attribute :name, Sidereal::Types::String.present
  attribute :email, Sidereal::Types::String.present
end

SendVerificationEmail = Sidereal::Message.define('donations.send_verification_email') do
  attribute :donation_id, Sidereal::Types::UUID::V4
end

VerifyEmailAddress = Sidereal::Message.define('donations.verify_email_address') do
  attribute :token, Sidereal::Types::String.present
end

ShowPaymentButton = Sidereal::Message.define('donations.show_payment_button') do
  attribute :donation_id, Sidereal::Types::UUID::V4
end

PresentCard = Sidereal::Message.define('donations.present_card') do
  attribute :donation_id, Sidereal::Types::UUID::V4
end

ConfirmPayment = Sidereal::Message.define('donations.confirm_payment') do
  attribute :donation_id, Sidereal::Types::UUID::V4
  attribute :payment_reference, Sidereal::Types::String.present
end

require_relative 'ui/layout'
require_relative 'ui/donation_page'

# -- Read model --

Donation = Struct.new(
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

module DonationStore
  module_function

  def all = donations.values

  def find(donation_id)
    donations[donation_id]
  end

  def find_by_token(token)
    donations.values.find { |donation| donation.verification_token == token }
  end

  def upsert(donation)
    donations[donation.donation_id] = donation
  end

  def clear
    donations.clear
  end

  def donations
    @donations ||= {}
  end
end

DONATION_AMOUNTS = [5, 10, 30, 50].freeze

module MockPaymentService
  module_function

  def charge(donation)
    StripeGateway.authorize(amount: donation.amount, email: donation.email)
  end
end

module StripeGateway
  module_function

  def authorize(amount:, email:)
    digest = [amount, email, Time.now.to_f, SecureRandom.hex(2)].join(':')
    "stripe_mock_#{digest.hash.abs.to_s(36)}"
  end
end

class DonationsApp < Sidereal::App
  session secret: 'd' * 64

  layout DonationsLayout

  get '/verify/:token' do |token:|
    if (donation = DonationStore.find_by_token(token))
      session[:donation_id] = donation.donation_id
      store.append VerifyEmailAddress.new(payload: {token:}).with_metadata(channel: channel_name)
      redirect to('/')
    else
      status 404
      body 'Verification link not found.'
    end
  end

  before_command do |cmd|
    if cmd.payload.respond_to?(:donation_id)
      session[:donation_id] = cmd.payload.donation_id
    end

    cmd.with_metadata(channel: channel_name)
  end

  handle SelectAmount, EnterDonorDetails, PresentCard

  command SelectAmount do |cmd|
    amount = cmd.payload.amount.to_i
    next unless DONATION_AMOUNTS.include?(amount)

    DonationStore.upsert Donation.new(
      donation_id: cmd.payload.donation_id,
      amount:,
      status: 'amount_selected'
    )
  end

  command EnterDonorDetails do |cmd|
    donation = DonationStore.find(cmd.payload.donation_id)
    next unless donation

    donation.name = cmd.payload.name
    donation.email = cmd.payload.email
    donation.status = 'details_entered'

    dispatch SendVerificationEmail, donation_id: donation.donation_id
  end

  command SendVerificationEmail do |cmd|
    donation = DonationStore.find(cmd.payload.donation_id)
    next unless donation

    donation.verification_token = SecureRandom.urlsafe_base64(18)
    donation.verification_link = "/verify/#{donation.verification_token}"
    donation.status = 'verification_email_sent'
  end

  command VerifyEmailAddress do |cmd|
    donation = DonationStore.find_by_token(cmd.payload.token)
    next unless donation

    donation.status = 'email_verified'
    donation.verified_at = Time.now

    dispatch ShowPaymentButton, donation_id: donation.donation_id
  end

  command ShowPaymentButton do |cmd|
    donation = DonationStore.find(cmd.payload.donation_id)
    next unless donation

    donation.status = 'payment_ready'
  end

  command PresentCard do |cmd|
    donation = DonationStore.find(cmd.payload.donation_id)
    next unless donation

    donation.status = 'card_presented'
    payment_reference = MockPaymentService.charge(donation)

    dispatch ConfirmPayment,
      donation_id: donation.donation_id,
      payment_reference:
  end

  command ConfirmPayment do |cmd|
    donation = DonationStore.find(cmd.payload.donation_id)
    next unless donation

    donation.payment_reference = cmd.payload.payment_reference
    donation.paid_at = Time.now
    donation.status = 'payment_confirmed'
  end

  page DonationPage
end
