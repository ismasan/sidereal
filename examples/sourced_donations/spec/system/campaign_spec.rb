# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Campaign do
  include Sourced::Testing::RSpec

  let(:campaign_id) { 'campaign-1' }

  describe Campaign::CreateCampaign do
    it 'creates a campaign with name and target_amount' do
      with_reactor(Campaign, campaign_id:)
        .when(Campaign::CreateCampaign, campaign_id:, name: 'Park benches', target_amount: '500')
        .then(Campaign::CampaignCreated, campaign_id:, name: 'Park benches', target_amount: 500)
    end

    it 'allows omitting target_amount (treats blank as nil)' do
      with_reactor(Campaign, campaign_id:)
        .when(Campaign::CreateCampaign, campaign_id:, name: 'No target', target_amount: '')
        .then(Campaign::CampaignCreated, campaign_id:, name: 'No target', target_amount: nil)
    end

    it 'rejects creating an already-existing campaign' do
      with_reactor(Campaign, campaign_id:)
        .given(Campaign::CampaignCreated, campaign_id:, name: 'X', target_amount: 100)
        .when(Campaign::CreateCampaign, campaign_id:, name: 'Again', target_amount: '50')
        .then(RuntimeError, 'campaign already exists')
    end
  end

  describe Campaign::CloseCampaign do
    it 'closes an open campaign' do
      with_reactor(Campaign, campaign_id:)
        .given(Campaign::CampaignCreated, campaign_id:, name: 'X', target_amount: 100)
        .when(Campaign::CloseCampaign, campaign_id:)
        .then(Campaign::CampaignClosed, campaign_id:)
    end

    it 'rejects closing a campaign that does not exist' do
      with_reactor(Campaign, campaign_id:)
        .when(Campaign::CloseCampaign, campaign_id:)
        .then(RuntimeError, 'campaign not found')
    end

    it 'rejects closing a campaign that is already closed' do
      with_reactor(Campaign, campaign_id:)
        .given(Campaign::CampaignCreated, campaign_id:, name: 'X', target_amount: 100)
        .and(Campaign::CampaignClosed, campaign_id:)
        .when(Campaign::CloseCampaign, campaign_id:)
        .then(RuntimeError, 'campaign already closed')
    end
  end
end
