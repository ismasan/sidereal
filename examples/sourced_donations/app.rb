# frozen_string_literal: true

require_relative 'ui/layout'
require_relative 'ui/donation_page'

class DonationsApp < Sidereal::App
  layout DonationsLayout

  get '/' do
    component self.class.layout.new(DonationPage.new)
  end

  get '/verify/:donation_id/:token' do |donation_id:, token:|
    decider, _ = Sourced.load(Donation, donation_id:)
    if decider.state.verification_token == token
      cmd = Donation::VerifyEmailAddress.new(payload: { donation_id: })
        .with_metadata(channel: donation_channel(donation_id))
      Sourced.store.append(cmd)
      redirect to("/#{donation_id}")
    else
      [404, { 'content-type' => 'text/plain' }, ['Verification link not found.']]
    end
  end

  handle Donation::SelectAmount do |cmd|
    dispatch cmd.with_metadata(channel: donation_channel(cmd.payload.donation_id))
    browser.redirect "/#{cmd.payload.donation_id}"
  end

  handle Donation::EnterDonorDetails, Donation::StartPayment do |cmd|
    dispatch cmd.with_metadata(channel: donation_channel(cmd.payload.donation_id))
  end

  page DonationPage

  private def donation_channel(donation_id) = "donations.#{donation_id}"
end
