# frozen_string_literal: true

require 'securerandom'

module MockPaymentService
  module_function

  def charge(donation)
    StripeGateway.authorize(amount: donation.amount, email: donation.email)
  end
end

module StripeGateway
  module_function

  def authorize(amount:, email:)
    digest = [amount, email, Time.now.to_f, SecureRandom.hex(2)].join(':')
    "stripe_mock_#{digest.hash.abs.to_s(36)}"
  end
end
