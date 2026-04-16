# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CampaignsProjector do
  include Sourced::Testing::RSpec

  let(:test_db) { Sequel.sqlite }

  before do
    test_db.create_table(:campaigns) do
      String :campaign_id, primary_key: true
      String :name, null: false
      Integer :target_amount
      String :status, null: false
      String :created_at, null: false
    end

    allow(Sourced).to receive_message_chain(:store, :db).and_return(test_db)
  end

  let(:campaign_id) { 'campaign-1' }
  let(:created_attrs) do
    { campaign_id:, name: 'Park benches', target_amount: 500 }
  end

  describe 'evolve' do
    it 'projects an open campaign from CampaignCreated' do
      with_reactor(CampaignsProjector, campaign_id:)
        .given(Campaign::CampaignCreated, **created_attrs)
        .then { |result|
          expect(result.state).to include(
            campaign_id:,
            name: 'Park benches',
            target_amount: 500,
            status: 'open'
          )
          expect(result.state[:created_at]).to be_a(String)
        }
    end

    it 'transitions to closed on CampaignClosed' do
      with_reactor(CampaignsProjector, campaign_id:)
        .given(Campaign::CampaignCreated, **created_attrs)
        .and(Campaign::CampaignClosed, campaign_id:)
        .then { |result|
          expect(result.state[:status]).to eq('closed')
        }
    end
  end

  describe 'sync — DB upserts' do
    it 'writes a row to the campaigns table' do
      with_reactor(CampaignsProjector, campaign_id:)
        .given(Campaign::CampaignCreated, **created_attrs)
        .then! { |_result|
          row = test_db[:campaigns].where(campaign_id:).first
          expect(row).to include(name: 'Park benches', target_amount: 500, status: 'open')
        }
    end

    it 'updates the row to closed on CampaignClosed' do
      with_reactor(CampaignsProjector, campaign_id:)
        .given(Campaign::CampaignCreated, **created_attrs)
        .and(Campaign::CampaignClosed, campaign_id:)
        .then! { |_result|
          row = test_db[:campaigns].where(campaign_id:).first
          expect(row[:status]).to eq('closed')
        }
    end
  end

  describe 'class-level queries' do
    def project(attrs)
      with_reactor(CampaignsProjector, campaign_id: attrs[:campaign_id])
        .given(Campaign::CampaignCreated, **attrs)
        .then! { |_| }
    end

    let(:other_attrs) { { campaign_id: 'campaign-2', name: 'Restore fountain', target_amount: nil } }

    it '.read_campaign returns the row for a given id' do
      project(created_attrs)
      result = described_class.read_campaign(campaign_id)
      expect(result).to include(campaign_id:, name: 'Park benches', status: 'open')
    end

    it '.read_campaign returns nil when missing' do
      expect(described_class.read_campaign('does-not-exist')).to be_nil
    end

    it '.all_campaigns returns rows ordered by created_at' do
      project(created_attrs)
      project(other_attrs)
      results = described_class.all_campaigns
      expect(results.map { |r| r[:campaign_id] }).to eq([campaign_id, 'campaign-2'])
    end

    it '.all_campaigns returns empty when no campaigns exist' do
      expect(described_class.all_campaigns).to eq([])
    end
  end
end
