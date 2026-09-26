# frozen_string_literal: true

module UI
  module Components
    # One hello in the sky log: in flight (Transmitting) or arrived (HelloSaid).
    # Patches find it by id and update it in place.
    class Hello < Sidereal::Components::BaseComponent
      def initialize(message)
        @message = message
      end

      def view_template
        payload = @message.payload
        id = "hello-#{payload.hello_id}"

        if @message.is_a?(Greetings::HelloSaid)
          li(id:, class: 'hello hello--arrived') do
            span(class: 'shooting-star', style: "--y: #{rand(6..30)}vh", aria: { hidden: 'true' })
            span(class: 'hello__star', aria: { hidden: 'true' }) { '✦' }
            div do
              p(class: 'hello__title') { "Hello, #{payload.name}!" }
              p(class: 'hello__status') do
                "Relayed by #{payload.star} at #{@message.created_at.localtime.strftime('%H:%M:%S')}"
              end
            end
          end
        else
          li(id:, class: 'hello', style: "--progress: #{payload.step.fdiv(payload.steps)}") do
            span(class: 'hello__star', aria: { hidden: 'true' }) { '✦' }
            div do
              p(class: 'hello__title') { "A hello for #{payload.name}" }
              p(class: 'hello__status') { payload.status }
              div(class: 'hello__trail', aria: { hidden: 'true' })
            end
          end
        end
      end
    end
  end
end
