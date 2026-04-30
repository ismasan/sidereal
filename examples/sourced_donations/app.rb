# frozen_string_literal: true

require_relative 'ui/layout'
require_relative 'ui/campaigns_list_page'
require_relative 'ui/donation_page'

class DonationsApp < Sidereal::App
  layout DonationsLayout

  get '/blank' do
    body <<~HTML
      <!doctype html>
      <html>
        <head>
          <title>Blank</title>
          <style>html,body{margin:0;padding:0;background:#fff;min-height:100vh}</style>
        </head>
        <body></body>
      </html>
    HTML
  end

  # Frozen-snapshot view: renders the DonationPage with state replayed up
  # to the Nth command/event of this donation's stream. Static — no SSE
  # subscription. Position links in the EventList sidebar point here.
  get '/:campaign_id/:donation_id/:step' do |campaign_id:, donation_id:, step:|
    step_int = Integer(step, 10) rescue nil
    halt 404, 'Not found' unless step_int && step_int > 0

    state, messages = DonationPage.load_donation_with_history(
      campaign_id, donation_id, upto: step_int
    )
    halt 404, 'Not found' if messages.length < step_int

    component self.class.layout.new(
      DonationPage.new(donation: state, messages: messages, current_step: step_int)
    )
  end

  get '/:campaign_id/:donation_id/verify/:token' do |campaign_id:, donation_id:, token:|
    decider, events = Sourced.load(Donation, campaign_id:, donation_id:)
    if decider.state.verification_token == token
      cmd = Donation::VerifyEmailAddress.new(payload: { donation_id:, campaign_id: })
      Sidereal.dispatch!(cmd)
      redirect to("/#{campaign_id}/#{donation_id}")
    else
      [404, { 'content-type' => 'text/plain' }, ['Verification link not found.']]
    end
  end

  before_command do |cmd|
    cmd.with_metadata(producer: 'UI')
  end

  channel_name do |msg|
    if msg.payload.attributes.key?(:donation_id)
      "campaigns.#{msg.payload.campaign_id}.donations.#{msg.payload.donation_id}"
    else
      "campaigns.#{msg.payload.campaign_id}"
    end
  end

  handle Campaign::CreateCampaign, Campaign::CloseCampaign

  handle Donation::StartDonation do |cmd|
    dispatch cmd
    browser.redirect "/#{cmd.payload.campaign_id}/#{cmd.payload.donation_id}"
  end

  handle Donation::SelectAmount, Donation::EnterDonorDetails, Donation::StartPayment

  page CampaignsListPage
  page DonationPage
end
