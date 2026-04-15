# frozen_string_literal: true

require 'sidereal'
require 'pstore'
require 'securerandom'

# -- Messages --

SelectAmount = Sidereal::Message.define('donations.select_amount') do
  attribute :donation_id, Sidereal::Types::AutoUUID
  attribute :amount, Sidereal::Types::String.present
end

EnterDonorDetails = Sidereal::Message.define('donations.enter_donor_details') do
  attribute :donation_id, Sidereal::Types::UUID::V4
  attribute :name, Sidereal::Types::String.present
  attribute :email, Sidereal::Types::Email.present
end

SendVerificationEmail = Sidereal::Message.define('donations.send_verification_email') do
  attribute :donation_id, Sidereal::Types::UUID::V4
end

DeliverVerificationEmail = Sidereal::Message.define('donations.deliver_verification_email') do
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

  FILE = File.expand_path('donations.pstore', __dir__)
  KEY = :donations

  def all = load_all.values

  def find(donation_id)
    load_all[donation_id]
  end

  def find_by_token(token)
    load_all.values.find { |donation| donation.verification_token == token }
  end

  def upsert(donation)
    store.transaction do
      donations = store[KEY] || {}
      donations[donation.donation_id] = donation_to_h(donation)
      store[KEY] = donations
    end
    donation
  end

  def clear
    store.transaction do
      store[KEY] = {}
    end
  end

  def load_all
    store.transaction(true) do
      (store[KEY] || {}).transform_values { |attrs| donation_from_h(attrs) }
    end
  end

  def store
    @store ||= PStore.new(FILE)
  end

  def donation_to_h(donation)
    donation.to_h
  end

  def donation_from_h(attrs)
    Donation.new(**attrs)
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
  layout DonationsLayout

  get '/verify/:token' do |token:|
    if (donation = DonationStore.find_by_token(token))
      store.append VerifyEmailAddress.new(payload: {token:}).with_metadata(channel: donation_channel(donation.donation_id))
      redirect to("/#{donation.donation_id}")
    else
      status 404
      body 'Verification link not found.'
    end
  end

  handle SelectAmount do |cmd|
    dispatch(cmd.with_metadata(channel: donation_channel(cmd.payload.donation_id)))
    browser.redirect "/#{cmd.payload.donation_id}"
  end

  handle EnterDonorDetails do |cmd|
    dispatch(cmd.with_metadata(channel: donation_channel(cmd.payload.donation_id)))
  end

  handle PresentCard do |cmd|
    dispatch(cmd.with_metadata(channel: donation_channel(cmd.payload.donation_id)))
  end

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
    DonationStore.upsert(donation)

    dispatch SendVerificationEmail, donation_id: donation.donation_id
  end

  command SendVerificationEmail do |cmd|
    donation = DonationStore.find(cmd.payload.donation_id)
    next unless donation

    donation.status = 'email_sent'
    DonationStore.upsert(donation)

    dispatch DeliverVerificationEmail, donation_id: donation.donation_id
  end

  command DeliverVerificationEmail do |cmd|
    donation = DonationStore.find(cmd.payload.donation_id)
    next unless donation

    sleep 3

    donation.verification_token = SecureRandom.urlsafe_base64(18)
    donation.verification_link = "/verify/#{donation.verification_token}"
    donation.status = 'verification_email_sent'
    DonationStore.upsert(donation)
  end

  command VerifyEmailAddress do |cmd|
    donation = DonationStore.find_by_token(cmd.payload.token)
    next unless donation

    donation.status = 'email_verified'
    donation.verified_at = Time.now
    DonationStore.upsert(donation)

    dispatch ShowPaymentButton, donation_id: donation.donation_id
  end

  command ShowPaymentButton do |cmd|
    donation = DonationStore.find(cmd.payload.donation_id)
    next unless donation

    donation.status = 'payment_ready'
    DonationStore.upsert(donation)
  end

  command PresentCard do |cmd|
    donation = DonationStore.find(cmd.payload.donation_id)
    next unless donation

    donation.status = 'card_presented'
    DonationStore.upsert(donation)
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
    DonationStore.upsert(donation)
  end

  get '/' do
    component self.class.layout.new(DonationPage.new)
  end

  page DonationPage

  private def donation_channel(donation_id)
    "donations.#{donation_id}"
  end
end
