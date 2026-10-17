# frozen_string_literal: true

require 'spec_helper'

RSpec.describe DonationView do
  include Sourced::Testing::RSpec

  let(:campaign_id) { 'campaign-1' }
  let(:donation_id) { 'donation-1' }

  describe 'evolve' do
    it 'projects campaign metadata from CampaignCreated' do
      with_reactor(DonationView, campaign_id:, donation_id:)
        .given(Campaign::CampaignCreated, campaign_id:, name: 'Park benches', target_amount: 500)
        .then { |result|
          expect(result.context.campaign_name).to eq('Park benches')
          expect(result.context.campaign_target_amount).to eq(500)
          expect(result.context.status).to be_nil
        }
    end

    it 'transitions through donation statuses' do
      with_reactor(DonationView, campaign_id:, donation_id:)
        .given(Campaign::CampaignCreated, campaign_id:, name: 'X', target_amount: 100)
        .and(Donation::DonationStarted, donation_id:, campaign_id:)
        .and(Donation::AmountSelected, donation_id:, campaign_id:, amount: 10)
        .and(Donation::DonorDetailsEntered, donation_id:, campaign_id:, name: 'Ada', email: 'ada@x.com')
        .then { |result|
          context = result.context
          expect(context.status).to eq('details_entered')
          expect(context.amount).to eq(10)
          expect(context.name).to eq('Ada')
          expect(context.email).to eq('ada@x.com')
          # Campaign info preserved across donation evolves
          expect(context.campaign_name).to eq('X')
        }
    end

    it 'builds the verification link from campaign_id and donation_id' do
      with_reactor(DonationView, campaign_id:, donation_id:)
        .given(Donation::DonationStarted, donation_id:, campaign_id:)
        .and(Donation::VerificationEmailSent, donation_id:, campaign_id:, token: 'TOKEN123')
        .then { |result|
          expect(result.context.verification_token).to eq('TOKEN123')
          expect(result.context.verification_link).to eq("/#{campaign_id}/#{donation_id}/verify/TOKEN123")
        }
    end

    it 'records payment confirmation details' do
      paid_at = Time.now
      with_reactor(DonationView, campaign_id:, donation_id:)
        .given(Donation::DonationStarted, donation_id:, campaign_id:)
        .and(Donation::PaymentConfirmed, donation_id:, campaign_id:, amount: 10, payment_reference: 'ref-1', paid_at:)
        .then { |result|
          expect(result.context.status).to eq('payment_confirmed')
          expect(result.context.payment_reference).to eq('ref-1')
          expect(result.context.paid_at).to eq(paid_at)
        }
    end
  end
end
