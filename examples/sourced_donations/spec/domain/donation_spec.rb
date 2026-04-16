# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Donation do
  include Sourced::Testing::RSpec

  let(:donation_id) { 'donation-1' }
  let(:campaign_id) { 'campaign-1' }

  # ---- Browser-facing commands ----

  describe Donation::StartDonation do
    it 'emits DonationStarted with campaign_id' do
      with_reactor(Donation, donation_id:)
        .when(Donation::StartDonation, donation_id:, campaign_id:)
        .then(Donation::DonationStarted, donation_id:, campaign_id:)
    end

    it 'rejects starting an already-started donation' do
      with_reactor(Donation, donation_id:)
        .given(Donation::DonationStarted, donation_id:, campaign_id:)
        .when(Donation::StartDonation, donation_id:, campaign_id:)
        .then(RuntimeError, 'donation already started')
    end
  end

  describe Donation::SelectAmount do
    it 'emits AmountSelected with the integer amount' do
      with_reactor(Donation, donation_id:)
        .given(Donation::DonationStarted, donation_id:, campaign_id:)
        .when(Donation::SelectAmount, donation_id:, campaign_id:, amount: '10')
        .then(Donation::AmountSelected, donation_id:, campaign_id:, amount: 10)
    end

    it 'rejects when the donation has not started' do
      with_reactor(Donation, donation_id:)
        .when(Donation::SelectAmount, donation_id:, campaign_id:, amount: '10')
        .then(RuntimeError, 'donation must be started first')
    end

    it 'rejects unknown amounts' do
      with_reactor(Donation, donation_id:)
        .given(Donation::DonationStarted, donation_id:, campaign_id:)
        .when(Donation::SelectAmount, donation_id:, campaign_id:, amount: '7')
        .then(RuntimeError, 'invalid amount 7')
    end
  end

  describe Donation::EnterDonorDetails do
    it 'emits DonorDetailsEntered when amount has been selected' do
      with_reactor(Donation, donation_id:)
        .given(Donation::DonationStarted, donation_id:, campaign_id:)
        .and(Donation::AmountSelected, donation_id:, campaign_id:, amount: 10)
        .when(Donation::EnterDonorDetails, donation_id:, campaign_id:, name: 'Ada', email: 'ada@example.com')
        .then(Donation::DonorDetailsEntered, donation_id:, campaign_id:, name: 'Ada', email: 'ada@example.com')
    end

    it 'rejects when amount has not been selected' do
      with_reactor(Donation, donation_id:)
        .given(Donation::DonationStarted, donation_id:, campaign_id:)
        .when(Donation::EnterDonorDetails, donation_id:, campaign_id:, name: 'Ada', email: 'ada@example.com')
        .then(RuntimeError, 'amount must be selected first')
    end
  end

  describe Donation::VerifyEmailAddress do
    it 'emits EmailVerified with verified_at from the command timestamp' do
      cmd = Donation::VerifyEmailAddress.new(payload: { donation_id:, campaign_id: })

      with_reactor(Donation, donation_id:)
        .given(Donation::DonationStarted, donation_id:, campaign_id:)
        .when(cmd)
        .then { |result|
          expect(result.messages.size).to eq(1)
          evt = result.messages.first
          expect(evt).to be_a(Donation::EmailVerified)
          expect(evt.payload.to_h).to eq(donation_id:, campaign_id:, verified_at: cmd.created_at)
        }
    end
  end

  # ---- Internal commands ----

  describe Donation::SendVerificationEmail do
    it 'emits EmailSent' do
      with_reactor(Donation, donation_id:)
        .given(Donation::DonationStarted, donation_id:, campaign_id:)
        .when(Donation::SendVerificationEmail, donation_id:, campaign_id:)
        .then(Donation::EmailSent, donation_id:, campaign_id:)
    end
  end

  describe Donation::DeliverVerificationEmail do
    before do
      allow_any_instance_of(Donation).to receive(:sleep)
      allow(SecureRandom).to receive(:urlsafe_base64).and_return('TEST_TOKEN')
    end

    it 'emits VerificationEmailSent with a generated token' do
      with_reactor(Donation, donation_id:)
        .given(Donation::DonationStarted, donation_id:, campaign_id:)
        .when(Donation::DeliverVerificationEmail, donation_id:, campaign_id:)
        .then(Donation::VerificationEmailSent, donation_id:, campaign_id:, token: 'TEST_TOKEN')
    end
  end

  describe Donation::ShowPaymentButton do
    it 'emits PaymentReady' do
      with_reactor(Donation, donation_id:)
        .given(Donation::DonationStarted, donation_id:, campaign_id:)
        .when(Donation::ShowPaymentButton, donation_id:, campaign_id:)
        .then(Donation::PaymentReady, donation_id:, campaign_id:)
    end
  end

  describe Donation::StartPayment do
    it 'emits PaymentStarted' do
      with_reactor(Donation, donation_id:)
        .given(Donation::DonationStarted, donation_id:, campaign_id:)
        .when(Donation::StartPayment, donation_id:, campaign_id:)
        .then(Donation::PaymentStarted, donation_id:, campaign_id:)
    end
  end

  describe Donation::ConfirmPayment do
    it 'emits PaymentConfirmed using payment_reference and the command timestamp' do
      cmd = Donation::ConfirmPayment.new(
        payload: { donation_id:, campaign_id:, payment_reference: 'stripe_mock_abc' }
      )

      with_reactor(Donation, donation_id:)
        .given(Donation::DonationStarted, donation_id:, campaign_id:)
        .when(cmd)
        .then { |result|
          evt = result.messages.first
          expect(evt).to be_a(Donation::PaymentConfirmed)
          expect(evt.payload.to_h).to eq(
            donation_id:, campaign_id:,
            payment_reference: 'stripe_mock_abc',
            paid_at: cmd.created_at
          )
        }
    end
  end

  # ---- Reactions (automations) ----

  describe 'reactions' do
    it 'reacts to DonorDetailsEntered by dispatching SendVerificationEmail' do
      with_reactor(Donation, donation_id:)
        .given(Donation::DonationStarted, donation_id:, campaign_id:)
        .and(Donation::AmountSelected, donation_id:, campaign_id:, amount: 10)
        .when(Donation::DonorDetailsEntered, donation_id:, campaign_id:, name: 'A', email: 'a@x.com')
        .then(Donation::SendVerificationEmail, donation_id:, campaign_id:)
    end

    it 'reacts to EmailSent by dispatching DeliverVerificationEmail' do
      with_reactor(Donation, donation_id:)
        .given(Donation::DonationStarted, donation_id:, campaign_id:)
        .when(Donation::EmailSent, donation_id:, campaign_id:)
        .then(Donation::DeliverVerificationEmail, donation_id:, campaign_id:)
    end

    it 'reacts to EmailVerified by dispatching ShowPaymentButton' do
      with_reactor(Donation, donation_id:)
        .given(Donation::DonationStarted, donation_id:, campaign_id:)
        .when(Donation::EmailVerified, donation_id:, campaign_id:, verified_at: Time.now)
        .then(Donation::ShowPaymentButton, donation_id:, campaign_id:)
    end

    it 'reacts to PaymentStarted by charging via MockPaymentService and dispatching ConfirmPayment' do
      allow(MockPaymentService).to receive(:charge).and_return('stripe_mock_xyz')

      with_reactor(Donation, donation_id:)
        .given(Donation::DonationStarted, donation_id:, campaign_id:)
        .and(Donation::AmountSelected, donation_id:, campaign_id:, amount: 10)
        .and(Donation::DonorDetailsEntered, donation_id:, campaign_id:, name: 'A', email: 'a@x.com')
        .when(Donation::PaymentStarted, donation_id:, campaign_id:)
        .then(Donation::ConfirmPayment, donation_id:, campaign_id:, payment_reference: 'stripe_mock_xyz')
    end
  end
end
