# frozen_string_literal: true

class CampaignPage < Sidereal::Page
  path '/campaigns/:campaign_id'

  on Campaign::CampaignClosed do |evt|
    next unless evt.payload.campaign_id == params[:campaign_id]

    browser.patch_elements load(params)
  end

  def self.load(params, _ctx)
    campaign = CampaignsProjector.read_campaign(params[:campaign_id])
    new(campaign:, campaign_id: params[:campaign_id])
  end

  def initialize(campaign:, campaign_id:)
    @campaign = campaign
    @campaign_id = campaign_id
  end

  def channel_name = 'campaigns'

  def view_template
    div(id: 'campaign-page') do
      header(class: 'header') do
        p(class: 'eyebrow') { 'Community Fund' }
        h1 { 'Campaign' }
      end

      main(class: 'kiosk') do
        section(class: 'panel') do
          if @campaign.nil?
            render NotFound.new
          else
            render CampaignDetails.new(@campaign)
          end
        end
      end
    end
  end

  class CampaignDetails < Sidereal::Components::BaseComponent
    def initialize(campaign)
      @campaign = campaign
    end

    def view_template
      div(class: 'step-screen') do
        h2 { @campaign[:name] }
        if @campaign[:target_amount]
          p(class: 'lede') { "Target: €#{@campaign[:target_amount]}" }
        end

        if @campaign[:status] == 'open'
          command Donation::StartDonation, class: 'tap-form' do |f|
            f.payload_fields(campaign_id: @campaign[:campaign_id])
            button(type: :submit, class: 'primary-button') { 'Start a donation' }
          end
        else
          div(class: 'notice') do
            p { 'This campaign is closed and is no longer accepting donations.' }
          end
          a(href: '/', class: 'secondary-button') { 'Back to campaigns' }
        end
      end
    end
  end

  class NotFound < Sidereal::Components::BaseComponent
    def view_template
      div(class: 'step-screen') do
        h2 { 'Campaign not found' }
        p(class: 'lede') { "We couldn't find that campaign." }
        a(href: '/', class: 'primary-button') { 'Back to campaigns' }
      end
    end
  end
end
