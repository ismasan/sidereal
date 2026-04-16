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
          expect(result.state.campaign_name).to eq('Park benches')
          expect(result.state.campaign_target_amount).to eq(500)
          expect(result.state.status).to be_nil
        }
    end

    it 'transitions through donation statuses' do
      with_reactor(DonationView, campaign_id:, donation_id:)
        .given(Campaign::CampaignCreated, campaign_id:, name: 'X', target_amount: 100)
        .and(Donation::DonationStarted, donation_id:, campaign_id:)
        .and(Donation::AmountSelected, donation_id:, campaign_id:, amount: 10)
        .and(Donation::DonorDetailsEntered, donation_id:, campaign_id:, name: 'Ada', email: 'ada@x.com')
        .then { |result|
          state = result.state
          expect(state.status).to eq('details_entered')
          expect(state.amount).to eq(10)
          expect(state.name).to eq('Ada')
          expect(state.email).to eq('ada@x.com')
          # Campaign info preserved across donation evolves
          expect(state.campaign_name).to eq('X')
        }
    end

    it 'builds the verification link from campaign_id and donation_id' do
      with_reactor(DonationView, campaign_id:, donation_id:)
        .given(Donation::DonationStarted, donation_id:, campaign_id:)
        .and(Donation::VerificationEmailSent, donation_id:, campaign_id:, token: 'TOKEN123')
        .then { |result|
          expect(result.state.verification_token).to eq('TOKEN123')
          expect(result.state.verification_link).to eq("/#{campaign_id}/#{donation_id}/verify/TOKEN123")
        }
    end

    it 'records payment confirmation details' do
      paid_at = Time.now
      with_reactor(DonationView, campaign_id:, donation_id:)
        .given(Donation::DonationStarted, donation_id:, campaign_id:)
        .and(Donation::PaymentConfirmed, donation_id:, campaign_id:, amount: 10, payment_reference: 'ref-1', paid_at:)
        .then { |result|
          expect(result.state.status).to eq('payment_confirmed')
          expect(result.state.payment_reference).to eq('ref-1')
          expect(result.state.paid_at).to eq(paid_at)
        }
    end
  end
end
