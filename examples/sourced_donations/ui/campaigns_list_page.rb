# frozen_string_literal: true

class CampaignsListPage < Sidereal::Page
  path '/'

  on Campaign::CampaignCreated, Campaign::CampaignClosed do |_evt|
    browser.patch_elements load(params)
  end

  def self.load(_params, _ctx)
    new(campaigns: CampaignsProjector.all_campaigns)
  end

  def initialize(campaigns: [])
    @campaigns = campaigns
  end

  def channel_name = 'campaigns'

  def view_template
    div(id: 'campaigns-page') do
      header(class: 'header') do
        p(class: 'eyebrow') { a(href: '/') { 'Community Fund' } }
        h1 { 'Campaigns' }
      end

      main(class: 'kiosk') do
        section(class: 'panel') do
          h2 { 'Start a new campaign' }
          render NewCampaignForm.new
        end

        section(class: 'panel') do
          h2 { 'All campaigns' }
          render CampaignsList.new(@campaigns)
        end
      end
    end
  end

  class NewCampaignForm < Sidereal::Components::BaseComponent
    def view_template
      command Campaign::CreateCampaign, class: 'details-form', autocomplete: 'off' do |f|
        label do
          span { 'Name' }
          f.text_field :name, placeholder: 'Help us repaint the park benches'
        end
        label do
          span { 'Target amount (€, optional)' }
          f.number_field :target_amount, placeholder: '500'
        end
        button(type: :submit, class: 'primary-button') { 'Create campaign' }
      end
    end
  end

  class CampaignsList < Sidereal::Components::BaseComponent
    def initialize(campaigns)
      @campaigns = campaigns
    end

    def view_template
      if @campaigns.empty?
        p(class: 'lede') { 'No campaigns yet — create one above to get started.' }
      else
        ul(class: 'campaigns-list') do
          @campaigns.each do |c|
            li(class: "campaigns-list__item campaigns-list__item--#{c[:status]}") do
              div(class: 'campaigns-list__body') do
                strong(class: 'campaigns-list__name') { c[:name] }
                if c[:target_amount]
                  span(class: 'campaigns-list__target') { "Target: €#{c[:target_amount]}" }
                end
                span(class: "campaigns-list__status campaigns-list__status--#{c[:status]}") { c[:status] }
              end

              div(class: 'campaigns-list__actions') do
                if c[:status] == 'open'
                  command Donation::StartDonation, class: 'inline-form' do |f|
                    f.payload_fields(campaign_id: c[:campaign_id])
                    button(type: :submit, class: 'primary-button') { 'Donate' }
                  end
                  command Campaign::CloseCampaign, class: 'inline-form' do |f|
                    f.payload_fields(campaign_id: c[:campaign_id])
                    button(type: :submit, class: 'secondary-button') { 'Close' }
                  end
                end
              end
            end
          end
        end
      end
    end
  end
end
