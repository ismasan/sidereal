# frozen_string_literal: true

require_relative 'event_list'

class DonationPage < Sidereal::Page
  path '/:campaign_id/:donation_id'

  on Donation::DonationStarted,
     Donation::AmountSelected,
     Donation::DonorDetailsEntered,
     Donation::EmailSent,
     Donation::VerificationEmailSent,
     Donation::EmailVerified,
     Donation::PaymentReady,
     Donation::PaymentStarted,
     Donation::PaymentConfirmed do |evt|
    state, messages = DonationPage.load_donation_with_history(
      evt.payload.campaign_id, evt.payload.donation_id
    )
    browser.patch_elements DonationPage.new(donation: state, messages: messages)
  end

  def self.load(params, _ctx)
    state, messages = load_donation_with_history(params[:campaign_id], params[:donation_id])
    new(donation: state, messages: messages)
  end

  def self.load_donation(campaign_id, donation_id)
    view, _ = Sourced.load(DonationView, campaign_id:, donation_id:)
    view.state
  end

  # Loads donation state + the full command/event stream for the sidebar in
  # one partition read. The sidebar always shows the complete history — the
  # +upto+ param only affects which messages contribute to the projected
  # state, so the user can jump forward/backward from any historic snapshot.
  def self.load_donation_with_history(campaign_id, donation_id, upto: nil)
    partition = { campaign_id: campaign_id, donation_id: donation_id }
    # Merge Donation's own messages (for display) with DonationView's evolve
    # types (for campaign context like name/target) so a single read covers
    # both the sidebar list and state computation.
    handled_types = (Donation.display_types +
      DonationView.handled_messages_for_evolve.map(&:type)).uniq
    result = Sourced.store.read_partition(partition, handled_types: handled_types)
    all_messages = result.messages

    display_messages = all_messages.reject { |m| campaign_message?(m) }

    # For the state projection, use all messages up to the chosen step.
    # Campaign messages are kept regardless (campaign_created must still
    # set campaign_name even when viewing step 1 of the donation).
    evolve_messages = if upto
      kept_ids = display_messages.first(upto).map(&:id).to_set
      all_messages.select { |m| campaign_message?(m) || kept_ids.include?(m.id) }
    else
      all_messages
    end

    view = DonationView.new({ campaign_id: campaign_id, donation_id: donation_id })
    view.evolve(evolve_messages)

    [view.state, display_messages]
  end

  def self.campaign_message?(msg)
    msg.type.start_with?('campaigns.')
  end

  def initialize(donation:, messages: [], current_step: nil)
    @donation = donation
    @messages = messages
    @current_step = current_step
  end

  def channel_name
    return 'static' if @current_step
    "campaigns.#{@donation.campaign_id}.donations.#{@donation.donation_id}"
  end

  # Historic snapshots suppress page_key so Page.subscribe returns early and
  # doesn't overwrite the frozen render with current state on SSE connect.
  def page_signals
    @current_step ? {} : { page_key: self.class.page_key }
  end

  def view_template
    div(id: 'donation-page', class: 'donation-layout') do
      div(class: 'donation-layout__main') do
        header(class: 'header') do
          p(class: 'eyebrow') { a(href: '/') { 'Community Fund' } }
          h1 { @donation.campaign_name }
          if @donation.campaign_target_amount
            p(class: 'campaign-tag') { "Target €#{@donation.campaign_target_amount}" }
          end
          if @current_step
            p(class: 'historic-tag') do
              plain "Viewing state at step #{@current_step} — "
              a(href: "/#{@donation.campaign_id}/#{@donation.donation_id}") { 'back to live' }
            end
          end
        end

        main(class: 'kiosk') do
          render Stepper.new(@donation)
          render CurrentStep.new(@donation)
        end
      end

      if @messages.any?
        render EventList.new(
          messages: @messages,
          campaign_id: @donation.campaign_id,
          donation_id: @donation.donation_id,
          current_step: @current_step
        )
      end
    end
  end

  class Stepper < Sidereal::Components::BaseComponent
    STEPS = [
      ['amount_selected', 'Select amount', :user],
      ['details_entered', 'Enter details', :user],
      ['email_sent', 'Send email', :background],
      ['verification_email_sent', 'Verify email', :user],
      ['email_verified', 'Verify', :background],
      ['payment_ready', 'Pay', :user],
      ['payment_started', 'Process', :background],
      ['payment_confirmed', 'Thank you!', :user]
    ].freeze

    STATUS_INDEX = {
      'started' => -1,
      'amount_selected' => 0,
      'details_entered' => 1,
      'email_sent' => 2,
      'verification_email_sent' => 3,
      'email_verified' => 4,
      'payment_ready' => 5,
      'payment_started' => 6,
      'payment_confirmed' => 7
    }.freeze

    def initialize(donation)
      @donation = donation
    end

    def view_template
      nav(class: 'stepper', aria_label: 'Donation progress') do
        current = @donation ? STATUS_INDEX.fetch(@donation.status, 0) : -1
        STEPS.each_with_index do |(_, label, source), index|
          classes = ['step', "step--#{source}"]
          classes << 'step--complete' if index < current
          classes << 'step--current' if index == current
          div(class: classes.join(' '), title: step_title(source)) do
            span(class: 'step__dot') { (index + 1).to_s }
            span(class: 'step__label') { label }
          end
        end
      end
    end

    private def step_title(source)
      source == :background ? 'Background automation' : 'User request'
    end
  end

  class CurrentStep < Sidereal::Components::BaseComponent
    def initialize(donation)
      @donation = donation
    end

    def view_template
      section(id: 'current-step', class: 'panel') do
        case @donation&.status
        when nil
          render NotFound.new
        when 'closed'
          render CampaignClosed.new
        when 'started'
          render AmountPicker.new(@donation)
        when 'amount_selected'
          render DonorDetailsForm.new(@donation)
        when 'details_entered'
          render PreparingEmail.new(@donation)
        when 'email_sent'
          render SendingEmail.new(@donation)
        when 'verification_email_sent'
          render WaitingForEmail.new(@donation)
        when 'email_verified'
          render PaymentPreparing.new(@donation)
        when 'payment_ready'
          render PaymentPad.new(@donation)
        when 'payment_started'
          render PaymentProcessing.new(@donation)
        when 'payment_confirmed'
          render ThankYou.new(@donation)
        end
      end
    end
  end

  class NotFound < Sidereal::Components::BaseComponent
    def view_template
      div(class: 'step-screen') do
        h2 { 'Donation not found' }
        p(class: 'lede') { 'Donations begin from a campaign page.' }
        a(href: '/', class: 'primary-button') { 'Browse campaigns' }
      end
    end
  end

  class CampaignClosed < Sidereal::Components::BaseComponent
    def view_template
      div(class: 'step-screen') do
        h2 { 'Campaign closed' }
        p(class: 'lede') { 'This campaign is no longer accepting donations.' }
        a(href: '/', class: 'primary-button') { 'Browse campaigns' }
      end
    end
  end

  class AmountPicker < Sidereal::Components::BaseComponent
    AMOUNTS = [5, 10, 30, 50].freeze

    def initialize(donation)
      @donation = donation
    end

    def view_template
      div(class: 'step-screen') do
        h2 { 'Choose an amount' }
        p(class: 'lede') { 'Select a preset amount to begin a donation.' }

        div(class: 'amount-grid') do
          AMOUNTS.each do |amount|
            command Donation::SelectAmount, class: 'amount-form' do |f|
              f.payload_fields(donation_id: @donation.donation_id, campaign_id: @donation.campaign_id, amount:)
              button(type: :submit, class: 'amount-button') do
                span(class: 'amount-button__currency') { '€' }
                span(class: 'amount-button__value') { amount.to_s }
              end
            end
          end
        end
      end
    end
  end

  class DonorDetailsForm < Sidereal::Components::BaseComponent
    def initialize(donation)
      @donation = donation
    end

    def view_template
      div(class: 'step-screen') do
        h2 { 'Your details' }
        p(class: 'lede') { "We will send a verification link before taking €#{@donation.amount}." }

        command Donation::EnterDonorDetails, class: 'details-form', autocomplete: 'off' do |f|
          f.payload_fields(donation_id: @donation.donation_id, campaign_id: @donation.campaign_id)
          label do
            span { 'Name' }
            f.text_field :name, autocomplete: 'name', placeholder: 'Ada Lovelace'
          end
          label do
            span { 'Email' }
            f.text_field :email,
              autocomplete: 'off',
              autocapitalize: 'none',
              spellcheck: 'false',
              inputmode: 'email',
              placeholder: 'ada@example.com'
          end
          button(type: :submit, class: 'primary-button') { 'Send verification email' }
        end
      end
    end
  end

  class WaitingForEmail < Sidereal::Components::BaseComponent
    def initialize(donation)
      @donation = donation
    end

    def view_template
      div(class: 'step-screen') do
        h2 { 'Check your email' }
        p(class: 'lede') { "We sent a verification link to #{@donation.email}." }

        div(class: 'email-preview') do
          p(class: 'email-preview__label') { 'Email preview' }
          p { "Hello #{@donation.name}, confirm your €#{@donation.amount} donation with this link:" }
          a(href: @donation.verification_link) { @donation.verification_link }
        end
      end
    end
  end

  class PreparingEmail < Sidereal::Components::BaseComponent
    def initialize(donation)
      @donation = donation
    end

    def view_template
      div(class: 'step-screen') do
        h2 { 'Preparing email' }
        p(class: 'lede') { "We are preparing a verification email for #{@donation.email}." }
        div(class: 'loading-bar') do
          span
        end
      end
    end
  end

  class SendingEmail < Sidereal::Components::BaseComponent
    def initialize(donation)
      @donation = donation
    end

    def view_template
      div(class: 'step-screen') do
        h2 { 'Sending email' }
        p(class: 'lede') { "The email service is sending your verification link to #{@donation.email}." }
        div(class: 'notice') do
          p { 'This can take a few seconds in the demo.' }
        end
        div(class: 'loading-bar') do
          span
        end
      end
    end
  end

  class PaymentPreparing < Sidereal::Components::BaseComponent
    def initialize(donation)
      @donation = donation
    end

    def view_template
      div(class: 'step-screen') do
        h2 { 'Email verified' }
        p(class: 'lede') { "Preparing the payment screen for your €#{@donation.amount} donation." }
        div(class: 'loading-bar') do
          span
        end
      end
    end
  end

  class PaymentPad < Sidereal::Components::BaseComponent
    def initialize(donation)
      @donation = donation
    end

    def view_template
      div(class: 'step-screen payment-screen') do
        h2 { "Pay €#{@donation.amount}" }
        p(class: 'lede') { 'Use the simulated contactless pad to complete the donation.' }

        div(class: 'card-pad') do
          div(class: 'card-pad__screen') do
            span { 'READY' }
            strong { "€#{@donation.amount}" }
          end
          command Donation::StartPayment, class: 'tap-form' do |f|
            f.payload_fields(donation_id: @donation.donation_id, campaign_id: @donation.campaign_id)
            button(type: :submit, class: 'tap-button') { 'Tap card' }
          end
        end
      end
    end
  end

  class PaymentProcessing < Sidereal::Components::BaseComponent
    def initialize(donation)
      @donation = donation
    end

    def view_template
      div(class: 'step-screen') do
        h2 { 'Processing payment' }
        p(class: 'lede') { 'The mock payment service is calling Stripe.' }
        div(class: 'loading-bar') do
          span
        end
      end
    end
  end

  class ThankYou < Sidereal::Components::BaseComponent
    def initialize(donation)
      @donation = donation
    end

    def view_template
      div(class: 'step-screen thank-you') do
        p(class: 'success-mark') { '✓' }
        h2 { 'Thank you' }
        p(class: 'lede') { "Your €#{@donation.amount} donation has been confirmed." }
        dl(class: 'receipt') do
          div do
            dt { 'Donor' }
            dd { @donation.name }
          end
          div do
            dt { 'Email' }
            dd { @donation.email }
          end
          div do
            dt { 'Payment reference' }
            dd { @donation.payment_reference }
          end
        end
        a(href: '/', class: 'primary-button') { 'Browse campaigns' }
      end
    end
  end
end
