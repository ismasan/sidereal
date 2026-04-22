# frozen_string_literal: true

require_relative 'ui/layout'
require_relative 'ui/campaigns_list_page'
require_relative 'ui/donation_page'

class DonationsApp < Sidereal::App
  layout DonationsLayout

  get '/:campaign_id/:donation_id/verify/:token' do |campaign_id:, donation_id:, token:|
    decider, events = Sourced.load(Donation, campaign_id:, donation_id:)
    if decider.state.verification_token == token
      cmd = Donation::VerifyEmailAddress.new(payload: { donation_id:, campaign_id: })
        .with_metadata(channel: donation_channel(campaign_id, donation_id))
      Sourced.store.append(cmd)
      redirect to("/#{campaign_id}/#{donation_id}")
    else
      [404, { 'content-type' => 'text/plain' }, ['Verification link not found.']]
    end
  end

  before_command do |cmd|
    cmd.with_metadata(producer: 'UI')
  end

  handle Campaign::CreateCampaign, Campaign::CloseCampaign do |cmd|
    dispatch cmd.with_metadata(channel: "campaigns.#{cmd.payload.campaign_id}")
  end

  handle Donation::StartDonation do |cmd|
    dispatch cmd.with_metadata(channel: donation_channel(cmd.payload.campaign_id, cmd.payload.donation_id))
    browser.redirect "/#{cmd.payload.campaign_id}/#{cmd.payload.donation_id}"
  end

  handle Donation::SelectAmount do |cmd|
    dispatch cmd.with_metadata(channel: donation_channel(cmd.payload.campaign_id, cmd.payload.donation_id))
  end

  handle Donation::EnterDonorDetails, Donation::StartPayment do |cmd|
    dispatch cmd.with_metadata(channel: donation_channel(cmd.payload.campaign_id, cmd.payload.donation_id))
  end

  page CampaignsListPage
  page DonationPage

  private def donation_channel(campaign_id, donation_id)
    "campaigns.#{campaign_id}.donations.#{donation_id}"
  end
end
